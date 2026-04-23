#!/usr/bin/env node
'use strict';

// Auto-budget-check hook (UserPromptSubmit)
//
// Scans each user prompt for execution-intent keywords. If the prompt looks
// like a commit-to-work request AND the rolling 5h rate-limit is already
// consumed past a threshold, injects an advisory into additionalContext so
// the assistant sees the warning *before* starting the turn.
//
// Non-blocking, non-modifying — only injects a systemMessage. Exit 0 always.

const fs = require('fs');
const path = require('path');

const HOME = process.env.HOME || '/tmp';
const STATE_FILE = path.join(HOME, '.claude/.session-state.json');
const LOG_FILE   = path.join(HOME, '.claude/hooks/auto-budget-check.log');

// Execution-intent patterns. Word boundaries to reduce false positives
// (e.g. "deploying" also matches, but "deployment" as a noun alone does not).
// Tuned conservative — prefer missing a prompt over crying wolf.
const EXECUTION_PATTERNS = [
  /\bexecute\b/i,
  /\bimplement\b/i,
  /\bbuild (it|out|all|the|both|these|them)\b/i,
  /\brun all\b/i,
  /\brun through\b/i,
  /\brun everything\b/i,
  /\bdeploy\b/i,
  /\bship it\b/i,
  /\brefactor\b/i,
  /\brewrite\b/i,
  /\brework\b/i,
  /\bfor each\b/i,
  /\bgo through all\b/i,
  /\bproceed\b/i,
  /\bkick off\b/i,
  /\bmigration\b/i,
  /\bbackfill\b/i,
  /\bdo it\b/i,
  /\bgo ahead (and )?(build|run|do|execute|implement|start)\b/i,
  /\bstart (building|executing|coding|the build|the refactor)\b/i,
  /\bapply (the|all) (fix|changes|edits|patches)\b/i,
  /\bmake (all|the) (edits|changes|updates)\b/i,
];

const WARN_THRESHOLD = 40;   // % of 5h used — start advising
const HIGH_THRESHOLD = 80;   // % — escalate to 🚨

function log(msg) {
  try { fs.appendFileSync(LOG_FILE, `${new Date().toISOString()} ${msg}\n`); } catch {}
}

function emit(out) {
  process.stdout.write(JSON.stringify(out));
  process.exit(0);
}

function main() {
  let raw = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', c => { raw += c; });
  process.stdin.on('end', () => {
    let parsed;
    try { parsed = JSON.parse(raw); } catch { return emit({}); }

    const prompt = (parsed.prompt || '').toString();
    if (prompt.length < 20) return emit({});

    // Find the first matching pattern
    let matchedPattern = null;
    for (const p of EXECUTION_PATTERNS) {
      if (p.test(prompt)) { matchedPattern = p; break; }
    }
    if (!matchedPattern) return emit({});

    // Read session state for current 5h usage
    let usedPct = null;
    let resetsAt = null;
    try {
      const state = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
      usedPct = state.rate_limits?.five_hour?.used_percentage;
      resetsAt = state.rate_limits?.five_hour?.resets_at;
    } catch { return emit({}); }

    if (typeof usedPct !== 'number' || usedPct < WARN_THRESHOLD) {
      log(`SKIP matched="${matchedPattern.source}" used=${usedPct}`);
      return emit({});
    }

    const pct = Math.round(usedPct);
    const matchStr = matchedPattern.source.replace(/\\b/g, '').replace(/[()\\]/g, '');

    let msg;
    if (usedPct >= HIGH_THRESHOLD) {
      msg = `[auto-budget] 🚨 5h at ${pct}% — prompt matched execution pattern /${matchStr}/. A heavy turn will likely push past 100%. Before starting, run /budget-check with the task outline; if ⚠️ or ❌, surface /execute-at-reset or propose splitting the work.`;
    } else {
      msg = `[auto-budget] ⚠️ 5h at ${pct}% — prompt matched execution pattern /${matchStr}/. Consider running /budget-check before committing; one heavy execution turn commonly costs 5–15%.`;
    }

    log(`FIRE used=${pct}% matched="${matchedPattern.source}" level=${usedPct >= HIGH_THRESHOLD ? 'HIGH' : 'WARN'}`);

    return emit({
      systemMessage: msg,
      hookSpecificOutput: {
        hookEventName: 'UserPromptSubmit',
        additionalContext: msg,
      },
    });
  });
}

main();
