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

/** Build one comparable row regardless of which provider's JSON shape it came from. */
function makeRow(label, usedPct, resetsAt, windowSecs, capabilities) {
  if (usedPct == null || !resetsAt || !windowSecs) return null;
  const leftPct = Math.max(0, 100 - usedPct);
  const secsLeft = Math.max(0, resetsAt - now);
  const timeLeftPct = Math.min(100, (secsLeft / windowSecs) * 100);
  const surplus = leftPct - timeLeftPct;

  let state;
  if (leftPct <= 2) state = "EXHAUSTED";
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
if (cc?.rate_limits) {
  const caps = "everything: judgment, research, code, interactive";
  const f = cc.rate_limits.five_hour, w = cc.rate_limits.seven_day;
  if (f) rows.push(makeRow("Claude 5h", f.used_percentage, f.resets_at, 5 * HOUR, caps));
  if (w) rows.push(makeRow("Claude 7d", w.used_percentage, w.resets_at, 7 * DAY, caps));
}

// --- Codex (OpenAI) ---------------------------------------------------------
const cx = await readJson(path.join(HOME, ".claude", "codex-rate-limits.json"));
const cxp = cx?.rate_limits?.primary;
if (cxp) {
  rows.push(makeRow("Codex", cxp.used_percent, cxp.resets_at,
    (cxp.window_duration_mins || 10080) * MIN,
    "mechanical code, build/deploy chains, no browser/DB"));
}

// --- agy / Antigravity (Gemini) --------------------------------------------
const ag = await readJson(path.join(HOME, ".claude", "agy-quota.json"));
const agw = ag?.groups?.gemini?.weekly, agf = ag?.groups?.gemini?.five_hour;
const agCaps = "multimodal, long-context, batch — NOT browser-driving";
if (agf) rows.push(makeRow("agy 5h", agf.used_percent, agf.resets_at, 5 * HOUR, agCaps));
if (agw) rows.push(makeRow("agy weekly", agw.used_percent, agw.resets_at, 7 * DAY, agCaps));

const live = rows.filter(Boolean);

// --- Verdict ----------------------------------------------------------------
// Long-window rows are what routing decisions actually hinge on; a 5h window refills
// too often to be worth steering by.
const longWindows = live.filter(r => r.secsLeft > 6 * HOUR || /7d|weekly/.test(r.label));
const usable = longWindows.filter(r => r.state !== "EXHAUSTED");
const best = usable.slice().sort((a, b) => b.surplus - a.surplus)[0];
const worst = longWindows.slice().sort((a, b) => a.surplus - b.surplus)[0];
const expiring = live.filter(r => r.state === "SPEND" && r.secsLeft < 24 * HOUR)
  .sort((a, b) => a.secsLeft - b.secsLeft)[0];
const breaches = live.filter(r => r.floorBreach);

if (process.argv.includes("--json")) {
  console.log(JSON.stringify({ rows: live, best: best?.label, worst: worst?.label, breaches: breaches.map(b => b.label) }, null, 2));
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
  if (expiring) {
    console.log(`USE IT OR LOSE IT: ${expiring.label} has ${expiring.leftPct}% left and resets in ${expiring.resetsIn}.`);
    console.log(`  That budget is forfeited if unspent — lean on it hard until then.`);
  }
  if (breaches.length) {
    for (const b of breaches) {
      console.log(`FLOOR BREACH: ${b.label} is down to ${b.leftPct}% with ${b.resetsIn} still to go — stop routing new work here.`);
    }
  }
  if (best) console.log(`ROUTE TO: ${best.label} (surplus ${best.surplus > 0 ? "+" : ""}${best.surplus}) — most headroom among providers that can take work.`);
  if (worst && worst.surplus < CONSERVE_AT) console.log(`AVOID: ${worst.label} (surplus ${worst.surplus}) — running ahead of its refill.`);
}
