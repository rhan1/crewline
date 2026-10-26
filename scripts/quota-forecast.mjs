#!/usr/bin/env node
// quota-forecast.mjs — will this job fit in its provider window, given what every session already has running
// and waiting? No automatic vendor switch, no silent model downgrade: it only decides when a job starts.
//
//   node quota-forecast.mjs                 table + plain-English call (/forecast)
//   node quota-forecast.mjs --json          the same as JSON
//   node quota-forecast.mjs --admit --provider codex|agy --tier T [--login any|personal|work] [--task N]
//        [--spec F] [--size S|M|L|XL] [--admit-size S|M|L|XL] [--project P] [--parent-pid N] [--priority pin]
//        [--ceiling PCT] [--pid N] [--wait] [--dry-run]
//      prints "VERDICT WINDOW EST PROJ CEILING FITS_AT PROJECT SIZE | reason"; exit 0 ADMIT, 5 REROUTE (other
//      Codex login), 4 QUEUE (wait until FITS_AT), 0 + "FAILOPEN" when the forecast cannot be computed.
//   node quota-forecast.mjs --check-budget <fixture.json> [--weight W]   cost-model gate
//   node quota-forecast.mjs --refresh-classes                          re-measure per-job sizes from the ledgers
//   node quota-forecast.mjs --refit-budgets [--apply]                  re-measure each 5h window's size from history (daily)
//
// Rule: the caller picks the model from the task's needs
// (complexity -> tier); this file only decides WHEN and on WHICH LOGIN/BUCKET a lane runs. First come, first
// served, with a fair share per project while another project is waiting; a pinned lane (DISPATCH_PRIORITY=pin) goes first; a running
// lane is never stopped. Ceiling 85 % of a 5h window (the 15 % floor stays for interactive work), 100 % in the
// window's last hour; the work Codex login uses codex-work-policy.py's verdict and cap.
// Seams: HOME, FORECAST_NOW, FORECAST_MODEL, CODEX_LIMITS_CACHE, AGY_QUOTA_CACHE, CODEX_PERSONAL_HOME,
// CODEX_WORK_HOME, FORECAST_WORK_POLICY ("ALLOW 100 why" | "DENY why"), FORECAST_NO_SNAPSHOT=1.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawn } from 'node:child_process';

const HOME = process.env.HOME;
const CL = path.join(HOME, '.claude');
const RS = path.join(CL, 'run-status');
const NOW = process.env.FORECAST_NOW ? Number(process.env.FORECAST_NOW) : Date.now() / 1000;
const P = {
  model: process.env.FORECAST_MODEL || path.join(CL, 'quota-cost-model.json'),
  codex: process.env.CODEX_LIMITS_CACHE || path.join(CL, 'codex-rate-limits.json'),
  agy: process.env.AGY_QUOTA_CACHE || path.join(CL, 'agy-quota.json'),
  claude: path.join(CL, '.session-state.json'),
  running: path.join(RS, 'dispatch-running'),
  queue: path.join(RS, 'dispatch-queue'),
  snaps: path.join(RS, 'quota-snapshots.jsonl'),
  sessions: path.join(RS, 'warp-sessions.json'),
  codexLedger: path.join(RS, 'codex-token-ledger.jsonl'),
  agyLedger: path.join(RS, 'agy-token-ledger.jsonl'),
  logs: process.env.CODEX_LOG_DIR || path.join(CL, 'logs'),
  policy: path.join(CL, 'scripts', 'codex-work-policy.py'),
  projects: process.env.FORECAST_CLAUDE_PROJECTS || path.join(CL, 'projects'),
  pairs: process.env.FORECAST_BUDGET_PAIRS || path.join(CL, 'bench', 'forecast', 'budget-pairs.json'),
};
const PROFILES = {
  personal: process.env.CODEX_PERSONAL_HOME || path.join(HOME, '.codex'),
  work: process.env.CODEX_WORK_HOME || path.join(HOME, '.codex-work'),
};
const STALE = 6 * 3600, FIVE_H = 18000, WEEK = 7 * 86400;
const LABEL = {
  codex_personal_5h: 'Codex personal 5h', codex_work_5h: 'Codex work 5h', agy_5h: 'Gemini (agy) 5h',
  agy_argon_wk: 'Gemini Argon weekly', claude_5h: 'Claude 5h',
};
const ADMITTABLE = new Set(['codex_personal_5h', 'codex_work_5h', 'agy_5h', 'agy_argon_wk']);

// ── small helpers ─────────────────────────────────────────────────────────────
const readJSON = (p) => { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; } };
const pidAlive = (pid) => { if (!Number.isInteger(pid) || pid <= 1) return false; try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; } };
const r1 = (x) => Math.round(x * 10) / 10;
const hhmm = (t) => { const d = new Date(t * 1000), s = d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
  return t - NOW > 20 * 3600 ? `${d.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' })} ${s}` : s; };
const inMins = (t) => { const m = Math.max(0, Math.round((t - NOW) / 60)); return m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m`; };
function tail(file, bytes) {
  try {
    const st = fs.statSync(file), n = Math.min(bytes, st.size), b = Buffer.alloc(n), fd = fs.openSync(file, 'r');
    fs.readSync(fd, b, 0, n, st.size - n); fs.closeSync(fd); return b.toString('utf8');
  } catch { return ''; }
}
function head(file, bytes) {
  try { const b = Buffer.alloc(bytes), fd = fs.openSync(file, 'r'), n = fs.readSync(fd, b, 0, bytes, 0); fs.closeSync(fd); return b.toString('utf8', 0, n); } catch { return ''; }
}
function writeAtomic(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp.${process.pid}`; fs.writeFileSync(tmp, text); fs.renameSync(tmp, file);
}
const loginOf = (profile) => {
  const b = path.basename(profile || PROFILES.personal);
  return b === '.codex' || !b.startsWith('.codex') ? 'personal' : b.replace(/^\.codex-/, '');
};

function loadModel() {
  // first run on a new machine: start from the seed shipped beside this script (re-measured from local history daily)
  if (!fs.existsSync(P.model)) { const seed = path.join(path.dirname(new URL(import.meta.url).pathname), 'quota-cost-model.seed.json'); if (fs.existsSync(seed)) try { writeAtomic(P.model, fs.readFileSync(seed, 'utf8')); } catch {} }
  const m = readJSON(P.model);
  if (!m || !m.classes || !m.window_100) throw new Error(`cost model unreadable: ${P.model}`);
  return m;
}

// ── window readings ───────────────────────────────────────────────────────────
function normalize(used, resets, span) {
  if (!Number.isFinite(used) || used < 0 || used > 1000 || !Number.isFinite(resets)) return null;   // corrupt → unavailable → fail open
  // An untouched window keeps sliding until first use (resets ~ now + span); an expired reading means a new window.
  if (!(resets > NOW)) return { used: 0, resets_at: NOW + span, anchored: false };
  if (used <= 0 && resets - NOW > span - 600) return { used: 0, resets_at: NOW + span, anchored: false };
  return { used, resets_at: resets, anchored: true };
}
function rolloutFiles(profileDir, since) {
  const out = [], seen = new Set();
  for (let t = since - 86400; t <= NOW + 86400; t += 43200) {
    const d = new Date(t * 1000);
    for (const parts of [[d.getFullYear(), d.getMonth() + 1, d.getDate()], [d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate()]]) {
      const dir = path.join(profileDir, 'sessions', String(parts[0]), String(parts[1]).padStart(2, '0'), String(parts[2]).padStart(2, '0'));
      if (seen.has(dir)) continue; seen.add(dir);
      let names = []; try { names = fs.readdirSync(dir); } catch { continue; }
      for (const n of names) if (n.startsWith('rollout-') && n.endsWith('.jsonl')) {
        const f = path.join(dir, n); try { const mt = fs.statSync(f).mtimeMs / 1000; if (mt >= since - 60) out.push({ file: f, mtime: mt }); } catch {}
      }
    }
  }
  return out;
}
function lastJsonLine(text, needle) {
  const lines = text.split('\n');
  for (let i = lines.length - 1; i >= 0; i--) if (lines[i].includes(needle)) { try { return JSON.parse(lines[i]); } catch {} }
  return null;
}
function rolloutLimits(profileDir, since) {
  // Codex writes the live rate-limit reading into every token_count event: fresher than the 45 s cache.
  // Pick the newest quota EVENT across the recent files (a file's mtime moves with tool output, not with quota events).
  let best = null;
  for (const { file } of rolloutFiles(profileDir, since).sort((a, b) => b.mtime - a.mtime).slice(0, 6)) {
    const o = lastJsonLine(tail(file, 262144), '"rate_limits"');
    const pr = o?.payload?.rate_limits?.primary, ts = Date.parse(o?.timestamp) / 1000;
    if (pr && Number.isFinite(pr.used_percent) && Number.isFinite(ts) && (!best || ts > best.ts)) best = { ts, used: pr.used_percent, resets: Number(pr.resets_at) };
  }
  return best;
}
function readWindows() {
  const W = {};
  const cx = readJSON(P.codex);
  if (cx) {
    const fetched = Date.parse(cx.fetched_at) / 1000 || 0;
    // two-login cache ({profiles:[…]}) or the single-login shape ({rate_limits:{primary,…}})
    for (const prof of cx.profiles || (cx.rate_limits ? [{ name: 'personal', rate_limits: cx.rate_limits }] : [])) {
      const key = `codex_${prof.name}_5h`, rl = prof.rate_limits || {}, pr = rl.primary || {};
      let used = rl.reached_type ? 100 : Number(pr.used_percent ?? 100), resets = Number(pr.resets_at || 0), ts = fetched, src = 'cache';
      const live = PROFILES[prof.name] ? rolloutLimits(PROFILES[prof.name], fetched) : null;
      if (live && live.ts > fetched + 5 && live.ts <= NOW + 5) { used = Math.max(used === 100 && rl.reached_type ? 100 : 0, live.used); resets = live.resets || resets; ts = live.ts; src = 'rollout'; }
      const n = normalize(used, resets, FIVE_H);
      if (n && Number.isFinite(ts)) W[key] = { ...n, ts, source: src, stale: NOW - ts > STALE };
    }
  }
  const ag = readJSON(P.agy);
  if (ag?.groups) {
    const ts = Number(ag.fetched_at) || 0, g = ag.groups;
    const a5 = g.gemini?.five_hour && normalize(Number(g.gemini.five_hour.used_percent), Number(g.gemini.five_hour.resets_at), FIVE_H);
    const aw = g.gemini_argon?.weekly && normalize(Number(g.gemini_argon.weekly.used_percent), Number(g.gemini_argon.weekly.resets_at), WEEK);
    if (a5) W.agy_5h = { ...a5, ts, source: 'cache', stale: NOW - ts > STALE };
    if (aw) W.agy_argon_wk = { ...aw, ts, source: 'cache', stale: NOW - ts > STALE };
  }
  const cs = readJSON(P.claude);
  if (cs?.rate_limits?.five_hour) {
    let ts = 0; try { ts = fs.statSync(P.claude).mtimeMs / 1000; } catch {}
    const f = cs.rate_limits.five_hour;
    const c5 = normalize(Number(f.used_percentage), Number(f.resets_at), FIVE_H);
    if (c5) W.claude_5h = { ...c5, ts, source: 'cache', stale: NOW - ts > STALE };
  }
  return W;
}

// ── lanes (running) and queue (waiting) ──────────────────────────────────────
function sessionsByPid() {
  const m = new Map();
  for (const s of readJSON(P.sessions)?.sessions || []) m.set(Number(s.pid), s);
  return m;
}
const slug = (x) => String(x).toLowerCase().replace(/[^a-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || 'adhoc';
function projectOf(parentPid, task, sessions) {
  return slug(projectRaw(parentPid, task, sessions));
}
function projectRaw(parentPid, task, sessions) {
  const s = sessions.get(Number(parentPid));
  if (s?.project && s.project !== 'other') return String(s.project).toLowerCase();
  if (s) return `session-${Number(parentPid)}`;   // a session without a project: its pid (titles change over time)
  return String(task || 'adhoc').toLowerCase().split(/[-_.\s]/)[0] || 'adhoc';
}
function sizeOf(spec, explicit, model) {
  if (/^(S|M|L|XL)$/.test(explicit || '')) return explicit;
  let text = '';
  try { text = fs.readFileSync(spec, 'utf8').slice(0, 400000); } catch { return 'M'; }
  const ids = new Set();
  for (const m of text.matchAll(/^#{2,3}\s+([A-Z]{1,3}\d+[a-z]?)\b/gm)) ids.add(m[1]);
  const r = model.size_rule || {};
  if (ids.size >= (r.XL_deliverables || 6) || /run all night|continue until|until FINAL|keep going until/i.test(text)) return 'XL';
  if (text.length >= (r.L_chars || 4000) || ids.size >= (r.L_deliverables || 3)) return 'L';
  return 'M';
}
const classKey = (provider, tier) => provider === 'codex' ? `codex:${['high', 'std', 'max', 'algo', 'lite'].includes(tier) ? tier : 'high'}` : (/argon|hard/i.test(tier || '') ? 'agy:argon' : 'agy:flash');
const windowFamily = (w) => w;
function estPct(model, ck, size, w) {
  const cls = model.classes[ck] || model.classes['codex:high'];
  const tok = cls[size] ?? cls.M;
  const budget = model.window_100[windowFamily(w)];
  return budget ? (tok / budget) * 100 : 0;
}
function laneWindow(m) {
  if (m.window) return m.window;
  if (m.executor === 'codex') return `codex_${loginOf(m.profile)}_5h`;
  if (m.executor === 'agy') return /argon/i.test(m.model || '') ? 'agy_argon_wk' : 'agy_5h';
  return 'claude_5h';
}
function agyLogUsage(log, model) {
  if (!log) return null;
  const text = tail(log, 8 * 1048576);
  if (!text) return null;
  let fresh = 0, cache = 0, n = 0;
  for (const line of text.split('\n')) {
    if (!line.includes('"usage":{') || line.includes('"event":"result"')) continue;
    const mm = line.match(/"usage":(\{[^}]*\})/); if (!mm) continue;
    try { const u = JSON.parse(mm[1]); fresh += Number(u.total_tokens ?? (Number(u.input_tokens || 0) + Number(u.output_tokens || 0))); cache += Number(u.cache_read_tokens || 0); n++; } catch {}
  }
  return n ? fresh + (model.cache_weight?.agy ?? 0.127) * cache : 0;
}
function rolloutStart(file) {
  // the session_meta line carries the whole base prompt (often > 8 KB): read only its leading timestamp
  const h = head(file, 4096), m = h.match(/^\{"timestamp":"([^"]+)"/), orig = h.match(/"originator":"([^"]+)"/);
  return m ? { start: Date.parse(m[1]) / 1000, exec: !orig || orig[1] === 'codex_exec' } : null;
}
function codexLaneUsage(lanes) {
  // Match each running Codex lane to its rollout (closest session start at/after the lane's start, one rollout per lane).
  const byProfile = new Map();
  for (const l of lanes) if (l.executor === 'codex') { const k = l.profile || PROFILES.personal; if (!byProfile.has(k)) byProfile.set(k, []); byProfile.get(k).push(l); }
  for (const [prof, ls] of byProfile) {
    const since = Math.min(...ls.map((l) => l.started || NOW));
    // only `codex exec` sessions (dispatches), never your interactive Codex; a lane takes the rollout that started
    // nearest after it (the wrapper starts codex a few seconds after writing its marker)
    const rs = rolloutFiles(prof, since).map((r) => ({ ...r, ...(rolloutStart(r.file) || {}) })).filter((r) => r.start && r.exec);
    const used = new Set();
    for (const l of ls.sort((a, b) => a.started - b.started)) {
      let best = null;
      for (const r of rs) if (!used.has(r.file) && r.start >= l.started - 5 && r.start <= l.started + 900 && (!best || r.start < best.start)) best = r;
      if (!best) continue;
      used.add(best.file);
      const o = lastJsonLine(tail(best.file, 262144), '"total_token_usage"');
      const u = o?.payload?.info?.total_token_usage;
      if (u) l.fresh = Number(u.input_tokens || 0) - Number(u.cached_input_tokens || 0) + Number(u.output_tokens || 0);
    }
  }
}
// Claude subagents: an agent transcript written to in the last 2 min is a running agent. They are never
// queued (an Agent call cannot wait) — they are counted so the Claude 5h projection and route-resolver see them.
const familyOf = (m) => (String(m || '').match(/haiku|sonnet|opus|fable|mythos/) || ['sonnet'])[0];
function claudeUsage(file, cw) {
  let text = ''; try { text = fs.readFileSync(file, 'utf8'); } catch { return null; }
  const seen = new Map(); let model = null, t0 = null;
  for (const line of text.split('\n')) {
    if (!t0) { const m = line.match(/"timestamp":"([^"]+)"/); if (m) t0 = Date.parse(m[1]) / 1000; }
    if (!line.includes('"usage"')) continue;
    let e; try { e = JSON.parse(line); } catch { continue; }
    const msg = e.message; if (!msg?.id || !msg.usage) continue;
    model ||= msg.model; seen.set(msg.id, msg.usage);   // streamed blocks repeat one message's usage: count it once
  }
  let fresh = 0;
  for (const u of seen.values()) fresh += Number(u.input_tokens || 0) + Number(u.cache_creation_input_tokens || 0) + Number(u.output_tokens || 0) + cw * Number(u.cache_read_input_tokens || 0);
  return { fresh, model, started: t0 };
}
function claudeAgentFiles(maxAgeSecs, minAgeSecs = 0) {
  const out = [];
  let projs = []; try { projs = fs.readdirSync(P.projects); } catch { return out; }
  for (const pj of projs) {
    let sess = []; try { sess = fs.readdirSync(path.join(P.projects, pj)); } catch { continue; }
    for (const sid of sess) {
      const dir = path.join(P.projects, pj, sid, 'subagents');
      let names = []; try { names = fs.readdirSync(dir); } catch { continue; }
      for (const n of names) {
        if (!/^agent-.*\.jsonl$/.test(n)) continue;
        const f = path.join(dir, n); let mt = 0; try { mt = fs.statSync(f).mtimeMs / 1000; } catch { continue; }
        if (NOW - mt <= maxAgeSecs && NOW - mt >= minAgeSecs) out.push({ file: f, sid, mtime: mt });
      }
    }
  }
  return out;
}
function readClaudeAgents(model, sessions) {
  const bySid = new Map(); for (const s of sessions.values()) if (s.sessionId) bySid.set(s.sessionId, s);
  const cw = model.cache_weight?.claude ?? 0.1, lanes = [];
  for (const a of claudeAgentFiles(120)) {
    const u = claudeUsage(a.file, cw); if (!u) continue;
    const meta = readJSON(a.file.replace(/\.jsonl$/, '.meta.json')) || {};
    const fam = familyOf(u.model || meta.model), ck = `claude:${fam}`, parent = bySid.get(a.sid);
    const est = model.classes[ck] ? estPct(model, ck, 'M', 'claude_5h') : 1;
    lanes.push({ file: path.basename(a.file), executor: 'claude', provider: 'claude', task: slug(meta.description || path.basename(a.file, '.jsonl')), tier: fam,
      model: u.model || meta.model || '', profile: '', started: u.started || a.mtime, pid: 0, parent_pid: parent?.pid ?? null,
      project: parent ? projectOf(parent.pid, meta.description, sessions) : 'claude', window: 'claude_5h', size: 'M', est, log: null, fresh: u.fresh });
  }
  return lanes;
}
function readLanes(model, sessions, windows) {
  const lanes = [];
  let names = []; try { names = fs.readdirSync(P.running); } catch {}
  for (const n of names) {
    if (!n.endsWith('.json') || n.startsWith('.')) continue;
    const m = readJSON(path.join(P.running, n));
    if (!m || !pidAlive(Number(m.pid))) continue;
    const window = laneWindow(m);
    const provider = m.executor === 'codex' ? 'codex' : m.executor === 'agy' ? 'agy' : 'claude';
    const size = sizeOf(m.spec, m.size, model);
    const ck = provider === 'claude' ? null : classKey(provider, provider === 'agy' ? m.model : m.tier);
    const est = Number.isFinite(Number(m.est_pct)) && m.est_pct !== null && m.est_pct !== '' ? Number(m.est_pct) : (ck ? estPct(model, ck, size, window) : 1.1);
    lanes.push({ file: n, executor: m.executor, provider, task: m.task, tier: m.tier, model: m.model, profile: m.profile, started: Number(m.started) || NOW,
      pid: Number(m.pid), parent_pid: m.parent_pid, project: m.project || projectOf(m.parent_pid, m.task, sessions), window, size, est, log: m.log, fresh: null });
  }
  codexLaneUsage(lanes);
  if (!process.env.FORECAST_NO_CLAUDE) lanes.push(...readClaudeAgents(model, sessions));
  const exp = model.expected_secs || {};
  for (const l of lanes) {
    if (l.provider === 'agy') l.fresh = agyLogUsage(l.log, model);
    const budget = model.window_100[l.window];
    l.consumed = l.fresh != null && budget ? (l.fresh / budget) * 100 : null;
    const elapsed = Math.max(0, NOW - l.started), expect = exp[l.provider] || 1500;
    // Not measured: assume a straight line over the class's expected duration (never below 20 % of the estimate).
    // Measured: what is left of the estimate, or — for a lane already past it — 30 % more of what it has used.
    l.remaining = l.consumed == null ? l.est * Math.max(0.2, 1 - elapsed / expect) : Math.max(l.est - l.consumed, 0.3 * l.consumed);
    const spentAll = l.consumed ?? Math.max(0, l.est - l.remaining);
    const win = windows[l.window], rate = (since) => (l.started >= since ? 1 : Math.min(1, Math.max(0, (NOW - since) / Math.max(1, NOW - l.started))));
    // spending after the window reading was taken is not in `used` yet (straight-line share of what it has used)
    l.unreflected = win && l.consumed != null ? l.consumed * rate(win.ts) : 0;
    // fair share counts only what the lane spent in the CURRENT window (a job that spans a reset keeps its old spend out)
    l.spent = win ? spentAll * rate(win.anchored ? win.resets_at - (l.window.endsWith('_wk') ? WEEK : FIVE_H) : NOW) : spentAll;
    l.load = l.remaining + l.unreflected;
  }
  return lanes;
}
function readQueue(cleanup) {
  const q = [];
  let names = []; try { names = fs.readdirSync(P.queue); } catch {}
  for (const n of names) {
    if (!n.endsWith('.json')) continue;
    const f = path.join(P.queue, n), e = readJSON(f);
    // an entry with an owner pid lives exactly as long as that process (and its lease); without one, until it expires
    const valid = e && Number.isFinite(Number(e.est)) && typeof e.window === 'string'
      && (e.pid ? pidAlive(Number(e.pid)) && Number(e.expires || 0) > NOW - 3600 : Number(e.expires || 0) > NOW);
    if (!valid) { if (cleanup) try { fs.unlinkSync(f); } catch {} continue; }
    q.push({ ...e, est: Number(e.est), state: e.state || 'waiting', file: f });
  }
  return q;
}
function ceilingFor(w, win, model) {
  const c = model.ceiling || {};
  if (w === 'codex_work_5h') return 100;   // shown; admission uses codex-work-policy.py's cap
  if (w.endsWith('_5h') && win?.anchored && win.resets_at - NOW <= (c.last_hour_secs || 3600)) return c.last_hour ?? 100;
  return c.default ?? 85;
}
function forecast(model, { cleanup = true } = {}) {
  const sessions = sessionsByPid();
  const windows = readWindows(), lanes = readLanes(model, sessions, windows), all = readQueue(cleanup);
  // "admitted" claims bridge the gap between an ADMIT verdict and the job's running marker (same pid); once the
  // marker exists the claim is dropped, so nothing is counted twice
  const markerPids = new Set(lanes.map((l) => l.pid));
  const claims = all.filter((q) => q.state === 'admitted' && !markerPids.has(Number(q.pid)));
  const queue = all.filter((q) => q.state !== 'admitted');
  for (const [w, win] of Object.entries(windows)) {
    const ls = lanes.filter((l) => l.window === w), qs = queue.filter((q) => q.window === w);
    win.claimed = r1(claims.filter((c) => c.window === w).reduce((a, c) => a + c.est, 0));
    win.label = LABEL[w] || w;
    win.running = { n: ls.length, pct: r1(ls.reduce((a, l) => a + l.load, 0) + win.claimed) };
    win.queued = { n: qs.length, pct: r1(qs.reduce((a, q) => a + Number(q.est || 0), 0)) };
    win.projected = r1(win.used + ls.reduce((a, l) => a + l.load, 0) + win.claimed);
    win.ceiling = ceilingFor(w, win, model);
    win.verdict = win.stale ? 'STALE' : win.projected >= 100 ? 'OVER' : win.projected > win.ceiling ? 'FULL' : win.projected + win.queued.pct > win.ceiling ? 'TIGHT' : 'OK';
    const bp = {};
    for (const l of ls) (bp[l.project] ||= { running: 0, queued: 0 }).running++;
    for (const q of qs) (bp[q.project] ||= { running: 0, queued: 0 }).queued++;
    win.by_project = bp;
  }
  return { ts: NOW, windows, lanes, queue, claims, sessions };
}

// ── snapshots (time series for later calibration) ─────────────────────────────
function snapshot(windows) {
  if (process.env.FORECAST_NO_SNAPSHOT === '1') return;
  try {
    const st = fs.existsSync(P.snaps) ? fs.statSync(P.snaps) : null;
    if (st && Date.now() / 1000 - st.mtimeMs / 1000 < 60) return;
    const rows = Object.entries(windows).filter(([, w]) => !w.stale).map(([k, w]) => JSON.stringify({ ts: Math.round(NOW), window: k, used: w.used, resets_at: Math.round(w.resets_at), source: w.source }));
    if (!rows.length) return;
    fs.mkdirSync(path.dirname(P.snaps), { recursive: true });
    fs.appendFileSync(P.snaps, rows.join('\n') + '\n');
    if (st && st.size > 8 * 1048576) { const t = fs.readFileSync(P.snaps, 'utf8'); writeAtomic(P.snaps, t.slice(t.indexOf('\n', t.length / 2) + 1)); }
  } catch {}
}

// ── admission ─────────────────────────────────────────────────────────────────
function workPolicy() {
  const seam = process.env.FORECAST_WORK_POLICY;
  let out = '';
  if (seam) out = seam;
  else if (!fs.existsSync(P.policy)) out = 'DENY no second Codex login configured';
  else {
    const args = ['-I', P.policy, '--cache', P.codex];
    if (process.env.FORECAST_NOW) args.push('--now', String(NOW));
    try { out = execFileSync('python3', args, { encoding: 'utf8', timeout: 15000 }); } catch (e) { out = String(e.stdout || 'DENY policy unavailable'); }
  }
  const line = out.trim().split('\n').pop() || 'DENY policy empty';
  const [v, cap, ...why] = line.split(' ');
  return v === 'ALLOW' ? { ok: true, cap: Number(cap) || 100, why: why.join(' ') } : { ok: false, cap: 0, why: line.replace(/^DENY\s*/, '') };
}
function withLock(fn) {
  // One admission at a time across sessions: read capacity, decide, publish the claim — no gap for a second wrapper.
  // Bounded: after 8 s (or a lock older than 60 s) proceed anyway, which is the fail-open direction.
  const lock = path.join(P.queue, '.admit.lock');
  fs.mkdirSync(P.queue, { recursive: true });
  let held = false;
  for (let i = 0; i < 160 && !held; i++) {
    try { fs.mkdirSync(lock); held = true; } catch {
      try { if (Date.now() - fs.statSync(lock).mtimeMs > 60000) fs.rmSync(lock, { recursive: true, force: true }); } catch {}
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
    }
  }
  try { return fn(held); } finally { if (held) try { fs.rmdirSync(lock); } catch {} }
}
function admit(o) {
  const model = loadModel();
  return withLock((held) => admitLocked(o, model, held));
}
function admitLocked(o, model, held) {
  const F = forecast(model, { cleanup: held });
  snapshot(F.windows);
  const project = o.project ? slug(o.project) : projectOf(o.parentPid, o.task, F.sessions);
  const ck = classKey(o.provider, o.tier);
  const size = sizeOf(o.spec, o.size, model), aSize = /^(S|M|L|XL)$/.test(o.admitSize || '') ? o.admitSize : size;
  // A waiting wrapper keeps one entry for its whole wait (keyed by its pid); a no-wait caller that retries later
  // (codex-manager-run attempts -m1, -m2 …) keeps its place under a stable key.
  const stem = String(o.task || 'adhoc').replace(/-m\d+$/, '');
  const qkey = slug(o.wait && o.pid ? `${project}.${o.provider}.${o.task}.${o.pid}` : `${project}.${o.provider}.${stem}`);
  const mine = F.queue.find((q) => q.key === qkey);
  const myCreated = mine ? Number(mine.created) : NOW;
  const pin = o.priority === 'pin';
  let cands;
  if (o.provider === 'codex') {
    const login = o.login && o.login !== 'any' ? o.login : null;
    cands = login ? [`codex_${login}_5h`] : ['codex_personal_5h', 'codex_work_5h'];
  } else cands = ck === 'agy:argon' ? ['agy_argon_wk'] : ['agy_5h'];

  const finish = (verdict, w, est, proj, ceiling, reason, code) => {
    // every admission path (including fail-open) drops this dispatch's waiting entry and publishes an admitted claim
    if (!o.dryRun) {
      if (mine) try { fs.unlinkSync(mine.file); } catch {}
      if (o.pid && est > 0) writeAtomic(path.join(P.queue, `admitted.${o.pid}.json`), JSON.stringify({ key: `admitted.${o.pid}`, state: 'admitted',
        project, task: o.task, window: w, est: r1(est), created: NOW, updated: NOW, expires: NOW + 900, pid: o.pid, priority: pin ? 'pin' : 'normal' }) + '\n');
    }
    return out(verdict, w, est, proj, ceiling, 0, project, aSize, reason, code);
  };
  const tried = [];
  for (const w of cands) {
    const win = F.windows[w];
    if (!win || win.stale) {
      // the login/bucket this dispatch would use by default has no usable reading: never refuse on missing data
      if (w === cands[0]) return finish('ADMIT', w, estPct(model, ck, aSize, w), win?.used ?? 0, 0, `FAILOPEN ${win ? `${w} reading is ${Math.round((NOW - win.ts) / 3600)}h old` : `no reading for ${w}`}`, 0);
      tried.push({ w, skip: `no usable reading for ${w}` }); continue;
    }
    let ceiling = Number.isFinite(o.ceiling) ? o.ceiling : ceilingFor(w, win, model);
    if (w === 'codex_work_5h') {
      if (o.login !== 'work' && !fs.existsSync(path.join(PROFILES.work, 'auth.json')) && !process.env.FORECAST_WORK_POLICY) { tried.push({ w, skip: 'no work login' }); continue; }
      // --managed: codex-manager-run.sh already applied the run's own work-login policy (the run's own orders) and
      // passes its cap as --ceiling; only the capacity/collision check is left to do here. Otherwise the work login's
      // ceiling is the policy cap.
      const pol = o.managed && o.login === 'work' ? { ok: true, cap: 100, why: 'managed run policy' } : workPolicy();
      if (!pol.ok) { tried.push({ w, skip: `work login not allowed: ${pol.why}` }); continue; }
      ceiling = Math.min(Number.isFinite(o.ceiling) ? o.ceiling : 100, pol.cap);
    }
    const est = estPct(model, ck, aSize, w);
    const ls = F.lanes.filter((l) => l.window === w);
    const proj = win.projected;
    const others = F.queue.filter((q) => q.window === w && q.project !== project);
    const ahead = others.filter((q) => pin ? (q.priority === 'pin' && Number(q.created) < myCreated) : (q.priority === 'pin' || Number(q.created) < myCreated));
    const claims = ahead.reduce((a, q) => a + q.est, 0);
    let fit = proj + claims + est <= ceiling + 1e-9, why = '';
    if (!fit) why = `projected ${r1(proj)}%${claims ? ` + ${r1(claims)}% for ${[...new Set(ahead.map((q) => q.project))].join(',')} waiting first` : ''} + this ${r1(est)}% > ceiling ${ceiling}%`;
    // Fair share limits a project that ALREADY holds this window while another project waits; a project's first
    // lane is never refused by it (otherwise two waiting projects could block each other on an idle window).
    const myLanes = ls.filter((l) => l.project === project), myClaims = F.claims.filter((c) => c.window === w && c.project === project);
    if (fit && !pin && others.length && (myLanes.length || myClaims.length)) {
      const projs = new Set([...ls.map((l) => l.project), ...others.map((q) => q.project), project]);
      const base = Math.max(0, win.used - ls.reduce((a, l) => a + l.spent, 0));
      const share = (ceiling - base) / projs.size;
      const minePct = myLanes.reduce((a, l) => a + l.spent + l.load, 0) + myClaims.reduce((a, c) => a + c.est, 0) + est;
      if (minePct > share + 1e-9) { fit = false; why = `fair share: ${project} would hold ${r1(minePct)}% of ${w}, share is ${r1(share)}% while ${[...new Set(others.map((q) => q.project))].join(',')} waits`; }
    }
    if (fit) return finish(w === cands[0] ? 'ADMIT' : 'REROUTE', w, est, proj, ceiling,
      `fits: projected ${r1(proj)}%${claims ? ` + ${r1(claims)}% queued ahead` : ''} + this ${r1(est)}% <= ceiling ${ceiling}%${w !== cands[0] ? ` (${tried.map((t) => t.why || t.skip).join('; ')})` : ''}`, w === cands[0] ? 0 : 5);
    tried.push({ w, why, est, proj, ceiling, resets: win.resets_at });
  }
  const options = tried.filter((t) => t.est != null);
  if (!options.length) return finish('ADMIT', cands[0], estPct(model, ck, aSize, cands[0]), 0, 0, `FAILOPEN ${tried.map((t) => t.skip).join('; ')}`, 0);
  const best = options.sort((a, b) => a.resets - b.resets)[0];
  if (!o.dryRun) {
    writeAtomic(path.join(P.queue, `${qkey}.json`), JSON.stringify({ key: qkey, state: 'waiting', project, task: o.task, provider: o.provider, window: best.w, est: r1(best.est), size: aSize,
      created: myCreated, updated: NOW, expires: NOW + (o.wait ? 300 : 1200), pid: o.wait && o.pid ? o.pid : null, parent_pid: Number(o.parentPid) || null, priority: pin ? 'pin' : 'normal', fits_at: Math.round(best.resets) }) + '\n');
  }
  return out('QUEUE', best.w, best.est, best.proj, best.ceiling, Math.round(best.resets), project, aSize, tried.map((t) => t.why || t.skip).join('; '), 4);
}
function out(verdict, w, est, proj, ceiling, fitsAt, project, size, reason, code) {
  return { code, line: `${verdict} ${w} ${r1(est)} ${r1(proj)} ${ceiling} ${fitsAt} ${project} ${size} | ${reason}` };
}

// ── cost-model gate and class refresh ─────────────────────────────────────────
function checkBudget(fixture, weightOverride) {
  // fixture: {cases:[{name, window, provider, fresh, cache, before, after, tol}]}
  const model = loadModel(), fx = readJSON(fixture);
  if (!fx?.cases) throw new Error(`bad fixture ${fixture}`);
  let fails = 0;
  for (const c of fx.cases) {
    const w = weightOverride ?? (c.provider === 'agy' ? model.cache_weight.agy : 0);
    const pred = c.before + ((c.fresh + w * (c.cache || 0)) / model.window_100[c.window]) * 100;
    const ok = Math.abs(pred - c.after) <= (c.tol ?? 3);
    if (!ok) fails++;
    console.log(`${c.name}: ${c.window} predicted ${r1(pred)} observed ${c.after} ${ok ? 'PASS' : 'FAIL'} (tol ${c.tol ?? 3})`);
  }
  return fails ? 1 : 0;
}
function quantiles(xs) {
  const s = [...xs].sort((a, b) => a - b), q = (p) => s[Math.min(s.length - 1, Math.floor(p * (s.length - 1)))];
  return { S: Math.round(q(0.25)), M: Math.round(q(0.5)), L: Math.round(q(0.9)), XL: Math.round(2 * q(0.9)) };
}
function refreshClasses() {
  const model = loadModel(), since = NOW - 30 * 86400, groups = {};
  let names = []; try { names = fs.readdirSync(P.logs); } catch {}
  for (const n of names) {
    const m = n.match(/^codex-(\d{8})T\d{6}Z\.log$/); if (!m) continue;
    const f = path.join(P.logs, n);
    try { if (fs.statSync(f).mtimeMs / 1000 < since) continue; } catch { continue; }
    const tier = head(f, 2000).match(/\[CodexRoute\] tier=(\w+)/)?.[1];
    const foot = tail(f, 1500).match(/codex-dispatch done: status=(\w+) tokens=(\d+)/);
    if (!tier || !foot || foot[1] !== 'success') continue;
    const tok = Number(foot[2]); if (tok === 1234 || tok < 1000) continue;
    (groups[`codex:${tier}`] ||= []).push(tok);
  }
  for (const line of (fs.existsSync(P.agyLedger) ? fs.readFileSync(P.agyLedger, 'utf8') : '').split('\n')) {
    let r; try { r = JSON.parse(line); } catch { continue; }
    if (r.dispatch_status !== 'success' || !(Date.parse(r.timestamp) / 1000 >= since)) continue;
    const k = /argon/i.test(r.model || '') ? 'agy:argon' : 'agy:flash';
    (groups[k] ||= []).push(Number(r.total_tokens || 0) + model.cache_weight.agy * Number(r.cache_read_tokens || 0));
  }
  // finished Claude subagents (last write 10 min – 30 days ago)
  for (const a of claudeAgentFiles(30 * 86400, 600)) {
    const u = claudeUsage(a.file, model.cache_weight?.claude ?? 0.1);
    if (u?.model && u.fresh > 0) (groups[`claude:${familyOf(u.model)}`] ||= []).push(u.fresh);
  }
  const changed = [];
  for (const [k, xs] of Object.entries(groups)) if (xs.length >= 10) { model.classes[k] = quantiles(xs); changed.push(`${k} n=${xs.length} M=${model.classes[k].M}`); }
  model.classes_updated = new Date(NOW * 1000).toISOString();
  if (changed.length) model.source = `ledgers ${model.classes_updated.slice(0, 10)} (window budgets: design-20261025)`;
  writeAtomic(P.model, JSON.stringify(model, null, 2) + '\n');
  return changed;
}

// ── window-budget refit ───────────────────────────────────────────────────────
// For each 5h window period in the last 14 days: tokens burned between its first and last reading ÷ the % it moved.
// Usage we cannot see (Codex on the VM or the web, the Antigravity app, claude.ai) only makes a window look SMALLER, so
// the candidate is the 75th percentile of the per-period values, not the median. It replaces the current size only when
// ≥ 8 periods agree, it moves ≥ 10 %, and the hand-measured before/after windows (budget-pairs.json) still pass with it.
const REFIT_MIN_MOVE = { codex_personal_5h: 30, codex_work_5h: 30, agy_5h: 10, claude_5h: 10 };
function periodRatios(events, minMove) {
  // events: [{ts, used, win, tok}] sorted by ts; tok = tokens burned since the previous event
  const per = new Map();
  for (const e of events) {
    const p = per.get(e.win);
    if (!p) { per.set(e.win, { u0: e.used, u1: e.used, tok: 0 }); continue; }
    p.u1 = e.used; p.tok += e.tok;
  }
  return [...per.values()].filter((p) => p.u1 - p.u0 >= minMove && p.tok > 0).map((p) => (p.tok / (p.u1 - p.u0)) * 100);
}
function codexEvents(login, since) {
  const ev = [];
  for (const r of rolloutFiles(PROFILES[login], since)) {
    let text = ''; try { text = fs.readFileSync(r.file, 'utf8'); } catch { continue; }
    for (const line of text.split('\n')) {
      if (!line.includes('"token_count"') || !line.includes('"primary"')) continue;
      let e; try { e = JSON.parse(line); } catch { continue; }
      const u = e.payload?.info?.total_token_usage, pr = e.payload?.rate_limits?.primary, ts = Date.parse(e.timestamp) / 1000;
      if (!u || !pr || !(ts >= since) || !Number.isFinite(Number(pr.used_percent))) continue;
      ev.push({ ts, f: r.file, fresh: Number(u.input_tokens || 0) - Number(u.cached_input_tokens || 0) + Number(u.output_tokens || 0),
        used: Number(pr.used_percent), win: Math.round(Number(pr.resets_at) / 300) });
    }
  }
  ev.sort((a, b) => a.ts - b.ts);
  const last = new Map();
  for (const e of ev) { e.tok = Math.max(0, e.fresh - (last.get(e.f) ?? 0)); last.set(e.f, e.fresh); }
  return ev;
}
function snapshotPeriods(window, since) {
  // first and last reading of each window period, from quota-snapshots.jsonl
  const per = new Map();
  for (const line of (fs.existsSync(P.snaps) ? fs.readFileSync(P.snaps, 'utf8') : '').split('\n')) {
    let r; try { r = JSON.parse(line); } catch { continue; }
    if (r.window !== window || !(r.ts >= since) || !Number.isFinite(Number(r.used))) continue;
    const k = Math.round(Number(r.resets_at) / 300), p = per.get(k);
    if (!p) per.set(k, { t0: r.ts, u0: Number(r.used), t1: r.ts, u1: Number(r.used), tok: 0 });
    else if (r.ts >= p.t1) { p.t1 = r.ts; p.u1 = Number(r.used); }
  }
  return [...per.values()];
}
function agyTokensInto(periods, model) {
  for (const line of (fs.existsSync(P.agyLedger) ? fs.readFileSync(P.agyLedger, 'utf8') : '').split('\n')) {
    let r; try { r = JSON.parse(line); } catch { continue; }
    if (/argon/i.test(r.model || '')) continue;
    const end = Date.parse(r.timestamp) / 1000, el = Math.max(1, Number(r.elapsed_s) || 600), start = end - el;
    const fe = Number(r.total_tokens || 0) + (model.cache_weight?.agy ?? 0.127) * Number(r.cache_read_tokens || 0);
    for (const p of periods) { const ov = Math.min(end, p.t1) - Math.max(start, p.t0); if (ov > 0) p.tok += fe * (ov / el); }
  }
}
function claudeTokensInto(periods, model) {
  if (!periods.length) return;
  const t0 = Math.min(...periods.map((p) => p.t0)), cw = model.cache_weight?.claude ?? 0.1, seen = new Set();
  const files = [];
  let projs = []; try { projs = fs.readdirSync(P.projects); } catch {}
  for (const pj of projs) {
    const d = path.join(P.projects, pj); let names = []; try { names = fs.readdirSync(d); } catch { continue; }
    for (const n of names) {
      const f = path.join(d, n);
      if (n.endsWith('.jsonl')) files.push(f);
      else { let subs = []; try { subs = fs.readdirSync(path.join(f, 'subagents')); } catch {} for (const s2 of subs) if (s2.endsWith('.jsonl')) files.push(path.join(f, 'subagents', s2)); }
    }
  }
  for (const f of files) {
    try { if (fs.statSync(f).mtimeMs / 1000 < t0) continue; } catch { continue; }
    let text = ''; try { text = fs.readFileSync(f, 'utf8'); } catch { continue; }
    for (const line of text.split('\n')) {
      if (!line.includes('"usage"') || !line.includes('"timestamp"')) continue;
      let e; try { e = JSON.parse(line); } catch { continue; }
      const m = e.message, ts = Date.parse(e.timestamp) / 1000;
      if (!m?.id || !m.usage || !(ts >= t0) || seen.has(m.id)) continue;
      seen.add(m.id);
      const u = m.usage, fe = Number(u.input_tokens || 0) + Number(u.cache_creation_input_tokens || 0) + Number(u.output_tokens || 0) + cw * Number(u.cache_read_input_tokens || 0);
      for (const p of periods) if (ts > p.t0 && ts <= p.t1) p.tok += fe;
    }
  }
}
function pairsPass(model, window, value) {
  const cases = (readJSON(P.pairs)?.cases || []).filter((c) => c.window === window);
  if (!cases.length) return null;
  return cases.every((c) => {
    const w = c.provider === 'agy' ? model.cache_weight.agy : 0;
    return Math.abs(c.before + ((c.fresh + w * (c.cache || 0)) / value) * 100 - c.after) <= (c.tol ?? 3);
  });
}
function refitBudgets(apply) {
  const model = loadModel(), since = NOW - 14 * 86400, out = {};
  const ratios = {
    codex_personal_5h: periodRatios(codexEvents('personal', since), REFIT_MIN_MOVE.codex_personal_5h),
    codex_work_5h: periodRatios(codexEvents('work', since), REFIT_MIN_MOVE.codex_work_5h),
  };
  const ap = snapshotPeriods('agy_5h', since); agyTokensInto(ap, model);
  ratios.agy_5h = ap.filter((p) => p.u1 - p.u0 >= REFIT_MIN_MOVE.agy_5h && p.tok > 0).map((p) => (p.tok / (p.u1 - p.u0)) * 100);
  const cp = snapshotPeriods('claude_5h', since).filter((p) => p.u1 - p.u0 >= REFIT_MIN_MOVE.claude_5h); claudeTokensInto(cp, model);
  ratios.claude_5h = cp.filter((p) => p.tok > 0).map((p) => (p.tok / (p.u1 - p.u0)) * 100);
  let changed = false;
  for (const [w, xs] of Object.entries(ratios)) {
    const cur = model.window_100[w], s = [...xs].sort((a, b) => a - b), q = (p) => Math.round(s[Math.min(s.length - 1, Math.floor(p * (s.length - 1)))]);
    const r = { n: s.length, current: cur };
    if (s.length < 8) { r.result = 'kept'; r.why = `${s.length} usable windows, need 8`; out[w] = r; continue; }
    Object.assign(r, { p25: q(0.25), p50: q(0.5), p75: q(0.75) });
    const cand = r.p75, move = cand / cur - 1, gate = pairsPass(model, w, cand);
    if (Math.abs(move) < 0.1) { r.result = 'kept'; r.why = `fit ${cand} is within 10 %`; }
    else if (gate === false) { r.result = 'kept'; r.why = `fit ${cand} contradicts the measured before/after windows`; }
    else if (gate === null && (cand / cur > (model.refit_unconfirmed_max ?? 2) || cur / cand > (model.refit_unconfirmed_max ?? 2))) { r.result = 'kept'; r.why = `fit ${cand} is more than ${model.refit_unconfirmed_max ?? 2}x off and nothing measured confirms it`; }
    else { r.result = apply ? 'applied' : 'would apply'; r.why = `fit ${cand} (${move > 0 ? '+' : ''}${Math.round(move * 100)} %)`; if (apply) { model.window_100[w] = cand; changed = true; } }
    out[w] = r;
  }
  if (apply) {
    model.budget_fit = { at: new Date(NOW * 1000).toISOString(), results: out };
    if (changed) model.source = String(model.source || '').replace(/\(window budgets: [^)]*\)/, '') + ` (window budgets: refit ${model.budget_fit.at.slice(0, 10)})`;
    writeAtomic(P.model, JSON.stringify(model, null, 2) + '\n');
  }
  return out;
}

// ── report ────────────────────────────────────────────────────────────────────
function report(asJson) {
  const model = loadModel();
  if (!asJson && !process.env.FORECAST_NOW && !(Date.parse(model.classes_updated || 0) / 1000 > NOW - 86400)) { try { refreshClasses(); } catch {} }
  // window refit reads a week of transcripts (seconds): once a day, detached, never in the caller's way
  if (!asJson && !process.env.FORECAST_NOW && !(Date.parse(model.budget_fit?.at || 0) / 1000 > NOW - 86400)) {
    try { spawn(process.execPath, [new URL(import.meta.url).pathname, '--refit-budgets', '--apply'], { detached: true, stdio: 'ignore' }).unref(); } catch {}
  }
  const F = forecast(model, { cleanup: false });
  snapshot(F.windows);
  if (asJson) {
    const { sessions, ...rest } = F;
    console.log(JSON.stringify(rest, null, 2)); return;
  }
  const order = ['codex_personal_5h', 'codex_work_5h', 'agy_5h', 'agy_argon_wk', 'claude_5h'];
  const pad = (s, n) => String(s).padEnd(n);
  console.log(pad('window', 21) + pad('used', 7) + pad('running', 13) + pad('waiting', 13) + pad('projected', 11) + pad('ceiling', 9) + pad('state', 7) + 'resets in');
  console.log('─'.repeat(92));
  for (const k of order) {
    const w = F.windows[k]; if (!w) continue;
    console.log(pad(w.label, 21) + pad(`${r1(w.used)}%`, 7) + pad(w.running.n ? `${w.running.n} +${w.running.pct}%` : '—', 13) + pad(w.queued.n ? `${w.queued.n} +${w.queued.pct}%` : '—', 13)
      + pad(`${w.projected}%`, 11) + pad(k === 'codex_work_5h' ? 'policy' : `${w.ceiling}%`, 9) + pad(w.verdict, 7) + (w.anchored ? inMins(w.resets_at) : 'not started'));
  }
  if (F.lanes.length) {
    console.log('\nrunning:');
    for (const l of F.lanes.sort((a, b) => a.started - b.started)) console.log(`  ${pad(l.task, 30)} ${pad(l.project, 12)} ${pad(LABEL[l.window] || l.window, 20)} est ${pad(r1(l.est) + '%', 6)} ${l.consumed != null ? `used so far ${r1(l.consumed)}%` : 'not measured'}  (${l.size}, ${inMins(NOW + (NOW - l.started))} in)`);
  }
  if (F.queue.length) {
    console.log('\nwaiting:');
    for (const q of F.queue.sort((a, b) => a.created - b.created)) console.log(`  ${pad(q.task, 30)} ${pad(q.project, 12)} ${pad(LABEL[q.window] || q.window, 20)} est ${pad(q.est + '%', 6)} fits at ${hhmm(q.fits_at)}${q.priority === 'pin' ? '  PIN' : ''}`);
  }
  console.log('');
  const tight = order.filter((k) => F.windows[k] && ADMITTABLE.has(k) && ['OVER', 'FULL', 'TIGHT'].includes(F.windows[k].verdict));
  if (!tight.length) console.log('Every Codex and Gemini window has room for its running and waiting jobs.');
  for (const k of tight) {
    const w = F.windows[k], who = Object.entries(w.by_project).map(([p, v]) => `${p} ${v.running} running${v.queued ? `/${v.queued} waiting` : ''}`).join(', ');
    console.log(`${w.label} is ${w.verdict === 'TIGHT' ? 'nearly full' : 'full'}: projected ${w.projected}% vs ceiling ${w.ceiling}% (${who || 'nothing of ours running now'}). New jobs on it wait until ${hhmm(w.resets_at)} unless another login has room.`);
  }
  const stale = order.filter((k) => F.windows[k]?.stale);
  if (stale.length) console.log(`Stale readings (admission fails open on these): ${stale.join(', ')}.`);
  // drift: last 24 h of ledger rows that carry an estimate
  const drift = [];
  for (const [f, prov] of [[P.codexLedger, 'codex'], [P.agyLedger, 'agy']]) {
    if (!fs.existsSync(f)) continue;
    for (const line of fs.readFileSync(f, 'utf8').split('\n').slice(-500)) {
      let r; try { r = JSON.parse(line); } catch { continue; }
      if (!r.est_pct || !r.window || !(Date.parse(r.timestamp) / 1000 > NOW - 86400)) continue;
      const fresh = prov === 'codex' ? Number(r.tokens || 0) : Number(r.total_tokens || 0) + model.cache_weight.agy * Number(r.cache_read_tokens || 0);
      const act = (fresh / (model.window_100[r.window] || 1)) * 100;
      drift.push(act / r.est_pct);
    }
  }
  if (drift.length) {
    const s = drift.sort((a, b) => a - b), med = s[Math.floor(s.length / 2)];
    console.log(`Estimates vs actual (last 24 h, ${s.length} jobs): jobs used ${r1(med)}× their estimate (median)${s.length >= 5 && (med > 2 || med < 0.5) ? ' — RECALIBRATE: run --refresh-classes or declare DISPATCH_SIZE' : ''}.`);
  }
  const fit = model.budget_fit?.results;
  if (fit) {
    const k = (n) => `${r1(n / 1e6)}M`;
    console.log(`Window sizes (checked ${String(model.budget_fit.at).slice(0, 10)}): ` + Object.entries(fit).map(([w, r]) => `${LABEL[w] || w} ${r.result === 'applied' ? `now ${k(model.window_100[w])}` : `kept ${k(r.current)}`} (${r.why})`).join('; ') + '.');
  }
  console.log(`Cost model: ${model.source}${model.classes_updated ? `, job sizes measured ${String(model.classes_updated).slice(0, 10)}` : ''}.`);
}

// ── CLI ───────────────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
const opt = (k) => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : undefined; };
try {
  if (argv.includes('--admit')) {
    const r = admit({
      provider: opt('--provider') || 'codex', tier: opt('--tier') || 'high', login: opt('--login') || 'any', task: opt('--task') || 'adhoc',
      spec: opt('--spec'), size: opt('--size'), admitSize: opt('--admit-size'), project: opt('--project'), parentPid: opt('--parent-pid'),
      priority: opt('--priority'), ceiling: opt('--ceiling') != null && opt('--ceiling') !== '' ? Number(opt('--ceiling')) : NaN,
      pid: Number(opt('--pid')) || null, wait: argv.includes('--wait'), dryRun: argv.includes('--dry-run'), managed: argv.includes('--managed'),
    });
    console.log(r.line); process.exit(r.code);
  } else if (argv.includes('--check-budget')) {
    const w = opt('--weight'); process.exit(checkBudget(opt('--check-budget'), w != null ? Number(w) : undefined));
  } else if (argv.includes('--refit-budgets')) {
    const r = refitBudgets(argv.includes('--apply'));
    for (const [w, x] of Object.entries(r)) console.log(`${w}: ${x.result} — ${x.why}${x.p50 ? ` [n=${x.n} p25 ${x.p25} p50 ${x.p50} p75 ${x.p75}, current ${x.current}]` : ''}`);
  } else if (argv.includes('--refresh-classes')) {
    const c = refreshClasses(); console.log(c.length ? `updated: ${c.join('; ')}` : 'no class had >= 10 jobs; model unchanged except classes_updated');
  } else report(argv.includes('--json'));
} catch (e) {
  if (argv.includes('--admit')) { console.log(`ADMIT - 0 0 0 0 - - | FAILOPEN forecast error: ${e.message}`); process.exit(0); }
  console.error(`quota-forecast: ${e.message}`); process.exit(1);
}
