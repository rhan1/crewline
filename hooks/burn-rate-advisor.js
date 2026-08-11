#!/usr/bin/env node
'use strict';

// Burn-rate advisor — spend surplus 5h budget before it is forfeited.
//
// THE IDEA: 5h budget is use-it-or-lose-it. Unspent tokens do NOT roll over at
// reset. So the question is never "how much is left?" in isolation — it is
// "how much is left RELATIVE TO how much clock is left?"
//
//     budget_left_pct   = 100 - five_hour.used_percentage
//     clock_left_pct    = seconds_to_reset / WINDOW_SECS * 100
//     surplus           = budget_left_pct - clock_left_pct
//
// surplus > 0  → under-spending; budget will expire unused → SPEND (fan out)
// surplus < 0  → over-spending; you will hit the wall early → CONSERVE
//
// A common ask: "~20-30 min to reset and still 30-40%+ left → dispatch as many
// agents as possible") is the extreme positive case: little clock, lots of
// budget. That is SPRINT.
//
// WEEKLY OVERRIDE: the 7d window is the real scarce resource — it does not
// refill for days. A 5h surplus is only truly free if 7d has room, so a high
// 7d reading tempers or cancels the sprint (a high 7d reading tempers or cancels the sprint).
//
// Wired on:
//   UserPromptSubmit          — set the posture for the turn
//   PreToolUse (Agent|Workflow) — advise at the actual fan-out decision point
// Silent in NORMAL so it never becomes noise. Always exit 0, never blocks.
//
// Manual check:  node ~/.claude/hooks/burn-rate-advisor.js --report
// Disable:       BURN_ADVISOR_OFF=1
// Tunables:      BURN_SPRINT_SURPLUS (35) BURN_SPEND_SURPLUS (25)
//                BURN_CONSERVE_SURPLUS (-15) BURN_SPRINT_MINS (45)
//                BURN_SPRINT_MIN_LEFT (30)
//                BURN_WEEKLY_GUARD (45)

const fs = require('fs');
const path = require('path');

const HOME = process.env.HOME || '/tmp';
const STATE_FILE = path.join(HOME, '.claude/.session-state.json');
const LOG_FILE = path.join(HOME, '.claude/hooks/burn-rate-advisor.log');

const WINDOW_SECS = 5 * 60 * 60;   // 5h rate-limit window
const STALE_AFTER = 120;           // statusline cache older than this is untrustworthy

const num = (v, d) => { const n = parseFloat(v); return Number.isFinite(n) ? n : d; };
const SPRINT_SURPLUS   = num(process.env.BURN_SPRINT_SURPLUS, 35);
const SPEND_SURPLUS    = num(process.env.BURN_SPEND_SURPLUS, 25);
const CONSERVE_SURPLUS = num(process.env.BURN_CONSERVE_SURPLUS, -15);
const SPRINT_MINS      = num(process.env.BURN_SPRINT_MINS, 45);
const SPRINT_MIN_LEFT  = num(process.env.BURN_SPRINT_MIN_LEFT, 30);
const WEEKLY_GUARD     = num(process.env.BURN_WEEKLY_GUARD, 45);

function log(m) { try { fs.appendFileSync(LOG_FILE, `${new Date().toISOString()} ${m}\n`); } catch {} }

// Returns null when the signal can't be trusted — silence beats a wrong number.
function assess() {
  let st;
  try { st = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')); } catch { return null; }

  const now = Math.floor(Date.now() / 1000);
  if (typeof st.timestamp === 'number' && (now - st.timestamp) > STALE_AFTER) return null;

  const five = (st.rate_limits || {}).five_hour || {};
  const weekly = (st.rate_limits || {}).seven_day || (st.rate_limits || {}).weekly || {};
  const used = five.used_percentage;
  const resetsAt = five.resets_at;
  if (typeof used !== 'number' || typeof resetsAt !== 'number') return null;

  // Window already rolled over: budget is fresh, the cached % is from a dead window.
  if (now >= resetsAt) {
    return { phase: 'FRESH', used: 0, budgetLeft: 100, minsLeft: Math.round(WINDOW_SECS / 60),
             surplus: 0, weekly: weekly.used_percentage };
  }

  const secsLeft = resetsAt - now;
  const budgetLeft = Math.max(0, 100 - used);
  const clockLeft = (secsLeft / WINDOW_SECS) * 100;
  const surplus = budgetLeft - clockLeft;
  const minsLeft = Math.round(secsLeft / 60);
  const wk = typeof weekly.used_percentage === 'number' ? weekly.used_percentage : null;

  // SPRINT keys off the literal rule — "reset is close AND there's still a
  // lot left" — not off surplus. Near the end of a window surplus ≈ budgetLeft
  // anyway, and this states the intent directly: that budget is about to be
  // forfeited. Surplus still grades the general SPEND/CONSERVE posture.
  let phase, critReason = '';
  if (minsLeft <= SPRINT_MINS && budgetLeft >= SPRINT_MIN_LEFT) phase = 'SPRINT';
  else if (used >= 85) { phase = 'CRITICAL'; critReason = `only ${Math.round(budgetLeft)}% of the window is left`; }
  else if (surplus <= CONSERVE_SURPLUS - 25) { phase = 'CRITICAL'; critReason = `burning far faster than the clock (${surplus >= 0 ? '+' : ''}${Math.round(surplus)} pts behind pace)`; }
  else if (surplus >= SPEND_SURPLUS) phase = 'SPEND';
  else if (surplus <= CONSERVE_SURPLUS) phase = 'CONSERVE';
  else phase = 'NORMAL';

  // The 5h refills in minutes; the 7d does not. Never sprint into a weekly wall.
  let weeklyNote = '';
  if (wk !== null && (phase === 'SPRINT' || phase === 'SPEND') && wk >= WEEKLY_GUARD) {
    weeklyNote = ` NOTE: 7d is at ${Math.round(wk)}% (guard ${WEEKLY_GUARD}%) — the weekly window is the binding constraint and does NOT refill today, so cap the fan-out and prefer external executors (Codex/agy) over Claude subagents.`;
    if (wk >= 70) { phase = 'NORMAL'; weeklyNote = ` OVERRIDE: 5h shows surplus but 7d is at ${Math.round(wk)}% — do NOT sprint. Weekly budget is the scarce resource; spend it only on work that must be Claude.`; }
  }

  return { phase, used, budgetLeft, minsLeft, surplus, weekly: wk, weeklyNote, critReason };
}

function message(a, atFanOut) {
  const head = `[burn] 5h ${Math.round(a.used)}% used · ${Math.round(a.budgetLeft)}% left · resets in ${a.minsLeft}m`;
  const surplus = `surplus ${a.surplus >= 0 ? '+' : ''}${Math.round(a.surplus)} pts`;

  switch (a.phase) {
    case 'SPRINT':
      return `${head} — 🚀 SPRINT (${surplus}). Budget does NOT roll over: ~${Math.round(a.budgetLeft)}% of this window expires unused in ${a.minsLeft}m. Spend it. Fan out to the MAXIMUM useful width right now — parallel Agent calls in a single message (RuFlo routes each to its cheapest sufficient tier), or a Workflow for structured fan-out; route mechanical work to Codex and multimodal/batch to agy so they burn no Claude budget at all. Prefer breadth (more independent workers) over depth. Anything still running at reset continues into a full fresh window, so starting big work now is free.${a.weeklyNote}`;
    case 'SPEND':
      return `${head} — ✅ SPEND (${surplus}, ahead of pace). Parallelize freely; don't serialize work that could fan out. Batch independent items into concurrent Agent calls.${a.weeklyNote}`;
    case 'CONSERVE':
      return `${head} — ⚠️ CONSERVE (${surplus}, behind pace). Burning faster than the clock: work sequentially, keep fan-outs to 2-3 workers on the cheapest sufficient tier, push mechanical work to Codex/agy, and checkpoint so the task can resume after reset.`;
    case 'CRITICAL':
      return `${head} — 🚨 CRITICAL (${a.critReason || surplus}). Near the wall: no new fan-outs, finish and checkpoint the current item, and chain the remainder to the next window (/execute-at-reset, dead-man's cron at resets_at+7m).`;
    case 'FRESH':
      return `${head} — window just reset, full budget available.`;
    default:
      return atFanOut ? null : `${head} — on pace.`;
  }
}

function emit(o) { process.stdout.write(JSON.stringify(o)); process.exit(0); }

// --report: human-readable one-liner for a shell / slash command
if (process.argv.includes('--report')) {
  const a = assess();
  if (!a) { console.log('[burn] no fresh rate-limit signal (statusline cache stale or absent)'); process.exit(0); }
  console.log(message(a, false));
  process.exit(0);
}

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => { raw += c; });
process.stdin.on('end', () => {
  if (process.env.BURN_ADVISOR_OFF === '1') return emit({});
  let ev = 'UserPromptSubmit';
  try { const p = JSON.parse(raw); if (p.hook_event_name) ev = p.hook_event_name; } catch {}

  const a = assess();
  if (!a) return emit({});

  const atFanOut = ev === 'PreToolUse';
  // At the fan-out decision point, only speak when there is something to change.
  if (atFanOut && !['SPRINT', 'CONSERVE', 'CRITICAL'].includes(a.phase)) return emit({});
  if (!atFanOut && a.phase === 'NORMAL') return emit({});

  const msg = message(a, atFanOut);
  if (!msg) return emit({});

  log(`${ev} phase=${a.phase} used=${Math.round(a.used)} left=${Math.round(a.budgetLeft)} mins=${a.minsLeft} surplus=${Math.round(a.surplus)} weekly=${a.weekly ?? '?'}`);
  return emit({
    systemMessage: msg,
    hookSpecificOutput: { hookEventName: ev, additionalContext: msg },
  });
});
