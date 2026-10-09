#!/usr/bin/env node
/**
 * route-resolver — PreToolUse:Agent|Workflow. MERGES and REPLACES agy-router.js and
 * dispatch-router-reminder.js: one hook decides claude-vs-agy instead of two hooks
 * emitting two (sometimes contradictory) opinions on the same tool call.
 *
 * Capability gates who CAN (blockers below); live capacity from quota-balance.mjs
 * decides who SHOULD when both CAN. See README § Cross-provider balancing — "one routing
 * resolver."
 *
 * Shadow by default: computes+logs the decision but never rewrites tool_input unless
 * ROUTE_ENFORCE=1. That lets the routing log build up evidence before it's allowed to
 * actually change behavior — the failure mode we're avoiding is a bad rule silently
 * misrouting every Agent call.
 *
 * Test override: set ROUTE_CAPACITY_JSON=<path> to a file shaped like
 * quota-balance.mjs --json output ({"rows":[{label,leftPct,surplus,state,
 * floorBreach,secsLeft,resetsIn}, ...]}) to feed fixed capacity data instead of
 * shelling out — lets a test pin "EXHAUSTED" / "SPEND" / floorBreach states
 * deterministically instead of racing the real quota cache.
 *
 * Disable with ROUTE_RESOLVER_OFF=1.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

function out(str) {
  try { process.stdout.write(str); } catch {}
  process.exit(0);
}

// ── Capability blockers, copied VERBATIM from agy-router.js's BLOCKERS ──────────
const BLOCKERS = [
  // 2026-10-08 (D6): 'browser' is tested by browserIntent() below, not by this table — the old
  // /\bbrowser\b|…|click |navigate / matched "no browser needed" and "Navigate the directory tree".
  { name: 'db-credential', re: /\bmysql\b|\bpsql\b|postgres|\bdb99\b|\bdb01\b|limpar|keychain|\bvpn\b|credential|\bsecret\b/ },
  { name: 'mcp', re: /\bmcp\b|codebase-memory|context7|scrapling|roseland/ },
  { name: 'security', re: /security review|threat model|vulnerabilit|audit the security|is this safe/ },
  { name: 'interactive', re: /ask the user|confirm with|decide whether we should|recommend to raza/ },
];

// Copied VERBATIM from dispatch-router-reminder.js's BROWSER_SIGNALS.
const BROWSER_SIGNALS = [
  'playwright', 'browser test', 'e2e', 'end-to-end', 'qa the page',
  'click through', 'fill the form', 'browser automation', 'drive the browser',
  'take a screenshot of the page', 'screenshot the site', 'screenshot of the live page',
  'lighthouse',
  // 'click' and 'navigate' REMOVED 2026-10-08 (D6): bare substrings hit "click-to-approve" and
  // "navigate the directory tree". Driving-verb phrases live in BROWSER_DRIVE_RE instead.
];

// Browser-driving intent (D6, 2026-10-08). Each alternative is a phrase that only makes sense
// when something has to drive a real browser; bare nouns/verbs are not enough.
const BROWSER_DRIVE_RE = new RegExp([
  String.raw`\bclick (on|the)\b`,
  String.raw`\bopen\b[^.;\n]{0,80}?\bin (a |the )?(chrome|safari|firefox|browser)\b`,
  String.raw`\b(in|into|using|with) (google )?(chrome|safari|firefox)\b`,
  String.raw`\bnavigate to (https?:|www\.)`,
  String.raw`playwright`, String.raw`puppeteer`, String.raw`selenium`, String.raw`chrome-devtools`, String.raw`lighthouse`,
  String.raw`\bscreenshot (of )?(the|this) (page|site|url|app|live page|dashboard)`,
  String.raw`\btake a screenshot\b`,
  String.raw`\blog ?in(to| to) the (site|page|app|portal|dashboard)`,
  String.raw`mcp__claude-in-chrome`, String.raw`claude_browser`,
].join('|'));

// `browser` counts only when NOT negated earlier in the same clause: "no browser needed",
// "without a browser", "not in a browser", "doesn't need a browser" are not blockers.
const NEGATION_RE = /\b(no|not|without|never|don'?t|doesn'?t|needn'?t|no need for)\b/;
function browserIntent(text) {
  if (BROWSER_DRIVE_RE.test(text)) return true;
  const re = /\bbrowser\b/g; let m;
  while ((m = re.exec(text))) {
    const before = text.slice(0, m.index);
    const clauseStart = Math.max(before.lastIndexOf('.'), before.lastIndexOf(';'), before.lastIndexOf(','),
      before.lastIndexOf(':'), before.lastIndexOf('!'), before.lastIndexOf('?'), before.lastIndexOf('\n'),
      before.lastIndexOf(' but '));
    if (!NEGATION_RE.test(before.slice(clauseStart + 1))) return true;
  }
  return false;
}

// Fitness signals, copied VERBATIM from agy-router.js.
const EXPLORE = /\b(explore|search|find|locate|grep|inventory|sweep|read through|which file|where is|map out|list all|survey)\b/;
const MECHANICAL = /\b(write|implement|generate|scaffold|refactor|convert|transform|port|parse|normali[sz]e|dedupe|script|boilerplate|test cases|unit tests)\b/;
const BULK = /\b(each of|all of the|every file|batch|bulk|across the repo|for all|one per)\b/;
const LONGCTX = /\b(summari[sz]e|extract from|read the entire|whole file|long log|transcript|large file)\b/;

const KEEP_SUBAGENTS = ['fork', 'claude-code-guide', 'statusline-setup', 'Plan'];
const REWRITABLE = new Set(['general-purpose', 'Explore', 'default', 'claude']);

function loadCapacity() {
  try {
    let raw;
    if (process.env.ROUTE_CAPACITY_JSON) {
      raw = fs.readFileSync(process.env.ROUTE_CAPACITY_JSON, 'utf8');
    } else {
      const H = process.env.HOME || require('os').homedir();
      const script = path.join(H, '.claude', 'scripts', 'quota-balance.mjs');
      raw = execSync(`node '${script}' --json`, { timeout: 3000, encoding: 'utf8' });
    }
    const parsed = JSON.parse(raw);
    const rows = parsed.rows || [];
    const find = (label) => rows.find((r) => r.label === label) || null;
    return {
      claude7d: find('Claude 7d'),
      agyWeekly: find('agy weekly'),
      agy5h: find('agy 5h'),
      codex: find('Codex'),
    };
  } catch {
    return null; // any failure (shell, parse, timeout) → unknown capacity, not a crash
  }
}

function logDecision(entry) {
  // Logging is diagnostic only — never let it affect the hook's exit path.
  try {
    const H = process.env.HOME || require('os').homedir();
    fs.appendFileSync(path.join(H, '.claude', 'route-decisions.jsonl'), JSON.stringify(entry) + '\n');
  } catch {}
}

try {
  if (process.env.ROUTE_RESOLVER_OFF === '1') out('{}');

  let raw = '';
  try { raw = fs.readFileSync(0, 'utf8'); } catch { out('{}'); }
  let payload;
  try { payload = JSON.parse(raw); } catch { out('{}'); }

  const toolName = payload && payload.tool_name;
  if (toolName !== 'Agent' && toolName !== 'Workflow') out('{}');

  const isWorkflow = toolName === 'Workflow';
  const input = (payload && payload.tool_input) || {};
  const promptRaw = String(input.prompt || '');
  const desc = String(input.description || '');
  const script = isWorkflow ? String(input.script || '') : '';
  const subagentType = String(input.subagent_type || '');
  const text = `${desc}\n${promptRaw}${isWorkflow ? '\n' + script : ''}`.toLowerCase();

  // ── Blockers: capability gate, not a preference ────────────────────────────
  let blocker = browserIntent(text) ? 'browser' : null;
  if (!blocker) for (const b of BLOCKERS) { if (b.re.test(text)) { blocker = b.name; break; } }
  if (!blocker) {
    for (const s of BROWSER_SIGNALS) { if (text.includes(s)) { blocker = 'browser-signal'; break; } }
  }
  // Explicit call-site model on a judgment task (review/verify/audit/adversarial/plan...) is the
  // caller's deliberate choice and judgment stays on Claude (README § Cross-provider balancing). Before
  // 2026-10-08 only ruflo-model-enforcer.js honored this, but route-chain.js runs the resolver FIRST
  // and returns its rewrite verbatim, so with agy in SPEND an "Adversarial review" pinned to opus was
  // rewritten to agy-worker (and its model deleted). Keep JUDGMENT_RE in sync with ruflo-model-enforcer.js.
  const JUDGMENT_RE = /\b(review|re-?verif|verif(y|ication)|adversarial|audit|security|threat|adjudicat|judg(e|ment)|architect|plan(ning)?|critique|second opinion|red[- ]team)\b/i;
  if (!blocker && input.model && JUDGMENT_RE.test(`${desc} ${promptRaw.slice(0, 600)}`)) blocker = 'explicit-judgment';

  // ── Fitness signals ─────────────────────────────────────────────────────────
  const hits = [];
  if (EXPLORE.test(text)) hits.push('exploration/file-reading');
  if (MECHANICAL.test(text)) hits.push('mechanical code');
  if (BULK.test(text)) hits.push('batch');
  if (LONGCTX.test(text)) hits.push('long-context read');

  const eligible = hits.length >= 1 && promptRaw.length >= 200 && !blocker;
  const capacity = loadCapacity();

  // ── Decision ─────────────────────────────────────────────────────────────
  let decision;
  // A capacity-driven claude verdict has to say WHY on the line itself, or the
  // shadow log is the only place the disagreement is visible — and nobody reads
  // a log mid-call. Hits alone cannot distinguish "agy floor" from "use-or-lose".
  let reason = null;
  if (!isWorkflow && (/agy/i.test(subagentType) || KEEP_SUBAGENTS.includes(subagentType))) {
    decision = 'keep'; // already routed, or a deliberate fork/self-delegation — leave it alone
  } else if (blocker) {
    decision = 'claude';
  } else if (!eligible) {
    decision = 'claude';
  } else if (!capacity) {
    decision = 'agy'; // agy is the measured-equal executor; no data says otherwise
  } else {
    const { claude7d, agyWeekly, agy5h } = capacity;
    const floorBreach =
      (agyWeekly && agyWeekly.floorBreach) || (agy5h && agy5h.floorBreach) ||
      (agyWeekly && agyWeekly.state === 'EXHAUSTED') || (agy5h && agy5h.state === 'EXHAUSTED');
    if (floorBreach) {
      decision = 'claude'; reason = 'agy floor';
    } else if (claude7d && agyWeekly && claude7d.state === 'SPEND'
               && agyWeekly.state !== 'SPEND' && agyWeekly.state !== 'SPRINT' && agyWeekly.state !== 'IDLE'
               && claude7d.surplus >= agyWeekly.surplus + 20) {
      // 7d use-or-lose: Claude has spend-worthy surplus agy doesn't. 2026-10-01: this fired on
      // 61 of 172 eligible calls (26% of the log) while agy's weekly was ALSO expiring unused —
      // Raza: "Gemini models are where we have the most bandwidth… bring it in on more tasks".
      // Now Claude wins the tie-break only when agy has NO expiring surplus of its own; with
      // both expiring, agy takes it (quality parity measured 10-01: 52/52 hard, 64/64 domain).
      // 2026-10-08 (D4, Raza "go"): an IDLE agy weekly (untouched, anchored on first use — see
      // quota-balance.mjs) never loses this tie-break: its surplus is left − floor (≈ +85), and the
      // explicit state check keeps that true even if the surplus formula changes.
      decision = 'claude'; reason = '7d use-or-lose';
    } else {
      decision = 'agy';
    }
  }

  // ── Enforcement (Agent only — Workflow's tool_input can't be rewritten) ────
  const rewritable = !subagentType || REWRITABLE.has(subagentType);
  let updatedInput = null;
  if (!isWorkflow && decision === 'agy' && process.env.ROUTE_ENFORCE === '1' && rewritable) {
    updatedInput = Object.assign({}, input, { subagent_type: 'agy-worker' });
    delete updatedInput.model; // agy-worker pins haiku; a stale model field would fight that
  }
  const wouldRewrite = !isWorkflow && decision === 'agy' && process.env.ROUTE_ENFORCE !== '1' && rewritable;

  // ── One-line output ─────────────────────────────────────────────────────────
  // D14 (2026-10-08): name the caller's pinned model instead of always printing 'sonnet'.
  const first = decision === 'agy' ? 'agy-worker' : decision === 'claude' ? `claude ${input.model || 'sonnet'}` : 'keep';
  const middle = blocker ? `blocker:${blocker}` : (hits.length ? hits.join(' + ') : 'no agy signals');
  const capPart = (capacity && capacity.agyWeekly && capacity.claude7d)
    ? `agy +${Math.round(capacity.agyWeekly.surplus)}${capacity.agyWeekly.state === 'IDLE' ? ' (IDLE)' : ''} / Claude7d +${Math.round(capacity.claude7d.surplus)} (${capacity.claude7d.state})`
    : 'agy +? / Claude7d +? (unknown)';
  let line = `[route] ${first} — ${middle}; ${capPart}${reason ? '; ' + reason : ''}${wouldRewrite ? '; SHADOW: would rewrite' : ''}`;
  if (line.length > 200) line = line.slice(0, 200);

  logDecision({
    ts: new Date().toISOString(),
    session_id: payload && payload.session_id,
    tool: toolName,
    desc: desc.slice(0, 80),
    prompt_len: promptRaw.length,
    subagent_type_in: subagentType || null,
    model_in: input.model || null,
    hits,
    blocker,
    capacity: capacity ? {
      claude7d: capacity.claude7d ? { surplus: capacity.claude7d.surplus, state: capacity.claude7d.state } : null,
      agyWeekly: capacity.agyWeekly ? { surplus: capacity.agyWeekly.surplus, state: capacity.agyWeekly.state, floorBreach: capacity.agyWeekly.floorBreach } : null,
      agy5h: capacity.agy5h ? { surplus: capacity.agy5h.surplus, state: capacity.agy5h.state, floorBreach: capacity.agy5h.floorBreach } : null,
      codex: capacity.codex ? { surplus: capacity.codex.surplus, state: capacity.codex.state } : null,
    } : null,
    decision,
    reason,
    enforced: !!updatedInput,
    mode: process.env.ROUTE_ENFORCE === '1' ? 'enforce' : 'shadow',
  });

  if (decision === 'keep') out('{}');

  const result = {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'allow',
      permissionDecisionReason: line,
      additionalContext: line,
    },
  };
  if (updatedInput) {
    result.systemMessage = line;
    result.hookSpecificOutput.updatedInput = updatedInput;
  }
  out(JSON.stringify(result));
} catch {
  out('{}');
}
