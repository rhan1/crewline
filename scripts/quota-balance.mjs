#!/usr/bin/env node
/**
 * quota-balance — one view of every provider's budget, and who should take the next job.
 *
 * The idea in one line: a budget is only "healthy" if what's LEFT is at least as big as
 * the share of the window still to come. Compare those two numbers and you get a single
 * signed score:
 *
 *     surplus = (% budget left) − (% of window still remaining)
 *
 *   surplus > 0  → underspending; this budget expires unused unless you lean on it.
 *   surplus < 0  → overspending; you run dry before the reset.
 *   IDLE         → an untouched rolling window (agy/Codex, anchored on first use): surplus = left − floor.
 *
 * Capability still decides WHO CAN do a job. Among providers that can, surplus decides
 * who SHOULD. Usage: node ~/.claude/scripts/quota-balance.mjs [--json]
 */
import { readFile } from "node:fs/promises";
import path from "node:path";

const HOME = process.env.HOME;
const now = Math.floor(Date.now() / 1000);
const MIN = 60, HOUR = 3600, DAY = 86400;

// Tunables. FLOOR_PCT/FLOOR_WINDOW encode "don't drain a provider dry when its refill
// is still days out" — the exact failure that stranded Codex at 100% with 4.6 days left.
const SPEND_AT = 15;      // surplus >= this → actively route work here
const CONSERVE_AT = -15;  // surplus <= this → back off
const FLOOR_PCT = 15;     // below this much left...
const FLOOR_WINDOW = 0.40; // ...with more than this share of the window still to run = breach
// Staleness guard (2026-10-08 dispatch review): a cache older than MAX_CACHE_AGE, or a row whose
// reset time has already passed, describes a window that is over — reading it as live made a 48h-old
// agy cache show "10% left, ON PACE, resets now". Such rows are DROPPED (consumers already treat a
// missing row as unknown) and listed under `stale`. 6h matches dispatch-common.sh's dc_quota_gate.
const MAX_CACHE_AGE = 6 * 3600;
const stale = [];
function cacheAge(fetched) {
  if (typeof fetched === "number") return now - (fetched > 1e12 ? Math.floor(fetched / 1000) : fetched);
  if (typeof fetched === "string") { const t = Date.parse(fetched); if (!Number.isNaN(t)) return now - Math.floor(t / 1000); }
  return null; // unknown age: keep the row (no evidence it is stale)
}
function fresh(source, fetched) {
  const age = cacheAge(fetched);
  if (age != null && age > MAX_CACHE_AGE) { stale.push(`${source} cache ${fmtDuration(age)} old`); return false; }
  return true;
}

async function readJson(p) {
  try { return JSON.parse(await readFile(p, "utf8")); } catch { return null; }
}

function fmtDuration(secs) {
  if (secs <= 0) return "now";
  const d = Math.floor(secs / DAY);
  const h = Math.floor((secs % DAY) / HOUR);
  const m = Math.floor((secs % HOUR) / MIN);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

// IDLE windows (Raza decision D4, 2026-10-08). agy (both windows) and Codex (both windows) use
// ROLLING windows that are anchored on FIRST USE: while untouched, the provider reports
// resets_at = fetch time + full window, so the pace math reads "100% left / 99.9% window left /
// surplus +0.1, ON PACE" forever — and an idle agy always lost the tie to Claude 7d SPEND, never got
// used, never anchored. A window that is UNSTARTED is now state IDLE with surplus = left% − FLOOR_PCT
// (≈ +85): the whole budget is free and nothing is ticking. Once usage starts and the window anchors,
// the normal pace math resumes. Claude windows are hour-aligned (not anchored on first use) and
// Ollama's are synthesized from day-of-week inference — neither is ever IDLE.
// "Unstarted" = left >= IDLE_LEFT_PCT AND, measured at the cache's fetch time (the only "unstarted"
// signal the caches carry: no explicit flag exists), the window had elapsed <= IDLE_ELAPSED_FRAC of
// its length. Fetch time, not now, so a 10-minute-old idle 5h cache (2% of 5h = 6 min) still counts.
const IDLE_LEFT_PCT = 99.5;
const IDLE_ELAPSED_FRAC = 0.02;
function fetchedEpoch(fetched) { const a = cacheAge(fetched); return a == null ? null : now - a; }

/** Build one comparable row regardless of which provider's JSON shape it came from.
 *  opts.anchoredOnFirstUse + opts.fetchedAt enable the IDLE state (see above). */
function makeRow(label, usedPct, resetsAt, windowSecs, capabilities, opts = {}) {
  if (usedPct == null || !resetsAt || !windowSecs) return null;
  if (resetsAt <= now) { stale.push(`${label} window already reset`); return null; }
  const leftPct = Math.max(0, 100 - usedPct);
  const secsLeft = Math.max(0, resetsAt - now);
  const timeLeftPct = Math.min(100, (secsLeft / windowSecs) * 100);
  let surplus = leftPct - timeLeftPct;

  let idle = false;
  if (opts.anchoredOnFirstUse && leftPct >= IDLE_LEFT_PCT) {
    const ref = opts.fetchedAt != null ? opts.fetchedAt : now;
    idle = windowSecs - (resetsAt - ref) <= windowSecs * IDLE_ELAPSED_FRAC;
  }

  let state;
  if (idle) { state = "IDLE"; surplus = leftPct - FLOOR_PCT; }
  else if (leftPct <= 2) state = "EXHAUSTED";
  else if (surplus >= SPEND_AT) state = "SPEND";
  else if (surplus <= CONSERVE_AT) state = "CONSERVE";
  else state = "ON PACE";

  const floorBreach = leftPct < FLOOR_PCT && secsLeft > windowSecs * FLOOR_WINDOW;

  return {
    label, leftPct: +leftPct.toFixed(1), usedPct: +usedPct.toFixed(1),
    timeLeftPct: +timeLeftPct.toFixed(1), surplus: +surplus.toFixed(1),
    secsLeft, resetsIn: fmtDuration(secsLeft), state, floorBreach, capabilities,
  };
}

const rows = [];

// --- Claude (Anthropic) -----------------------------------------------------
const cc = await readJson(path.join(HOME, ".claude", ".session-state.json"));
if (cc?.rate_limits && fresh("Claude", cc.timestamp)) {
  const caps = "everything: judgment, research, code, interactive";
  const f = cc.rate_limits.five_hour, w = cc.rate_limits.seven_day;
  if (f) rows.push(makeRow("Claude 5h", f.used_percentage, f.resets_at, 5 * HOUR, caps));
  if (w) rows.push(makeRow("Claude 7d", w.used_percentage, w.resets_at, 7 * DAY, caps));
}

// --- Codex (OpenAI) ---------------------------------------------------------
const cx = await readJson(path.join(HOME, ".claude", "codex-rate-limits.json"));
// Codex reports TWO windows: primary (5h since ~10-2026) and secondary (weekly). Reading only
// `primary` left the weekly — the binding one that hit 100% on 07-29 and 08-16 — invisible to the
// floor gate (2026-10-08 dispatch review: gate passed at weekly 95% used with 6d to go). Short
// window keeps the historical label "Codex"; a window of a day or more is "Codex weekly".
if (cx?.rate_limits && fresh("Codex", cx.fetched_at)) {
  for (const w of [cx.rate_limits.primary, cx.rate_limits.secondary]) {
    if (!w) continue;
    const mins = w.window_duration_mins || 10080;
    rows.push(makeRow(mins >= 1440 ? "Codex weekly" : "Codex", w.used_percent, w.resets_at, mins * MIN,
      "mechanical code, build/deploy chains, no browser/DB",
      { anchoredOnFirstUse: true, fetchedAt: fetchedEpoch(cx.fetched_at) }));
  }
}

// --- agy / Antigravity (Gemini) --------------------------------------------
const ag = await readJson(path.join(HOME, ".claude", "agy-quota.json"));
const agOk = ag ? fresh("agy", ag.fetched_at) : false;
const agw = agOk && ag?.groups?.gemini?.weekly, agf = agOk && ag?.groups?.gemini?.five_hour;
const agCaps = "multimodal, long-context, batch — NOT browser-driving";
const agOpts = { anchoredOnFirstUse: true, fetchedAt: ag ? fetchedEpoch(ag.fetched_at) : null };
if (agf) rows.push(makeRow("agy 5h", agf.used_percent, agf.resets_at, 5 * HOUR, agCaps, agOpts));
if (agw) rows.push(makeRow("agy weekly", agw.used_percent, agw.resets_at, 7 * DAY, agCaps, agOpts));

// --- Ollama Cloud (OPTIONAL — only rendered when ~/.claude/ollama-quota.json exists) ----------
// crewline ships no writer for this cache; bring your own refresher off the undocumented
// ollama.com/api/usage. Expected shape: {fetched_at, weekly:{used_percent}, session:{used_percent},
// window:{elapsed_fraction, ceiling_pct}}. That API exposes NO reset clocks, so the refresher
// infers window position and may set a DYNAMIC ceiling (ceiling_pct) to protect other consumers
// of a shared key. Reset times below are synthesized from that inference — the surplus is an
// estimate, hence the ~est labels. The breach trigger is the ceiling, not just the generic floor.
const ol = await readJson(path.join(HOME, ".claude", "ollama-quota.json"));
if (ol?.weekly && now - (ol.fetched_at || 0) < 2 * HOUR) {
  const olCaps = "OpenAI-compat single-shot chat — drafts, transforms, batch text; no tools/browser";
  const elapsed = Math.min(1, Math.max(0, ol.window?.elapsed_fraction ?? 0.5));
  const ceiling = ol.window?.ceiling_pct ?? 95;
  const wRow = makeRow("Ollama wk ~est", ol.weekly.used_percent ?? 0,
    now + Math.max(60, Math.round((1 - elapsed) * 7 * DAY)), 7 * DAY, olCaps);
  if (wRow) {
    wRow.floorBreach = wRow.floorBreach || (ol.weekly.used_percent ?? 0) >= ceiling;
    wRow.sharedCeiling = ceiling;
    rows.push(wRow);
  }
  const sRow = makeRow("Ollama 5h ~est", ol.session?.used_percent ?? 0,
    now + Math.round(2.5 * HOUR), 5 * HOUR, olCaps);
  // The 5h window position is pure convention (no reset clock exists), so this
  // row must never drive the use-it-or-lose-it banner — it would fire forever.
  if (sRow) { sRow.synthetic = true; rows.push(sRow); }
}

const live = rows.filter(Boolean);

// --- Verdict ----------------------------------------------------------------
// Long-window rows are what routing decisions actually hinge on; a 5h window refills
// too often to be worth steering by.
const longWindows = live.filter(r => r.secsLeft > 6 * HOUR || /7d|weekly/.test(r.label));
const usable = longWindows.filter(r => r.state !== "EXHAUSTED");
const best = usable.slice().sort((a, b) => b.surplus - a.surplus)[0];
const worst = longWindows.slice().sort((a, b) => a.surplus - b.surplus)[0];
const expiring = live.filter(r => r.state === "SPEND" && r.secsLeft < 24 * HOUR && !r.synthetic)
  .sort((a, b) => a.secsLeft - b.secsLeft)[0];
const breaches = live.filter(r => r.floorBreach);

if (process.argv.includes("--json")) {
  console.log(JSON.stringify({ rows: live, best: best?.label, worst: worst?.label, breaches: breaches.map(b => b.label), stale }, null, 2));
} else {
  const pad = (s, n) => String(s).padEnd(n);
  console.log("provider      left    window-left   surplus   state       resets in");
  console.log("─".repeat(72));
  for (const r of live) {
    const flag = r.floorBreach ? "  ⚠ FLOOR" : "";
    console.log(
      `${pad(r.label, 13)} ${pad(r.leftPct + "%", 7)} ${pad(r.timeLeftPct + "%", 13)} ` +
      `${pad((r.surplus > 0 ? "+" : "") + r.surplus, 9)} ${pad(r.state, 11)} ${r.resetsIn}${flag}`
    );
  }
  console.log("");
  for (const st of stale) console.log(`STALE: ${st} — row ignored (not live data).`);
  const olRow = live.find(r => r.sharedCeiling != null);
  if (olRow) {
    console.log(`OLLAMA CEILING: our lane may burn up to ${olRow.sharedCeiling}% weekly right now (dynamic, protects other users of the shared key); currently at ${olRow.usedPct}%.`);
  }
  if (expiring) {
    console.log(`USE IT OR LOSE IT: ${expiring.label} has ${expiring.leftPct}% left and resets in ${expiring.resetsIn}.`);
    console.log(`  That budget is forfeited if unspent — lean on it hard until then.`);
  }
  if (breaches.length) {
    for (const b of breaches) {
      console.log(`FLOOR BREACH: ${b.label} is down to ${b.leftPct}% with ${b.resetsIn} still to go — stop routing new work here.`);
    }
  }
  if (best) console.log(`ROUTE TO: ${best.label} (surplus ${best.surplus > 0 ? "+" : ""}${best.surplus}${best.state === "IDLE" ? ", IDLE — untouched window, whole budget free" : ""}) — most headroom among providers that can take work.`);
  if (worst && worst.surplus < CONSERVE_AT) console.log(`AVOID: ${worst.label} (surplus ${worst.surplus}) — running ahead of its refill.`);
}
