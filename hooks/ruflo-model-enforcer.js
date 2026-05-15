#!/usr/bin/env node
'use strict';

// RuFlo Model Enforcer Hook — standalone edition
//
// PreToolUse hook (filters on Agent tool calls). Routes each Agent task to
// haiku / sonnet / opus using inline keyword heuristics — no external `ruflo`
// CLI required.
//
// I/O contract: reads JSON from stdin, writes JSON to stdout, always exits 0.
// Writes a human-readable summary to ~/.claude/hooks/ruflo-last-route.txt
// (consumed by the statusline) and appends to ~/.claude/hooks/ruflo-enforcer.log.
//
// To tune routing: edit the keyword lists in KEYWORDS below.

const fs   = require('fs');
const path = require('path');

const HOME           = process.env.HOME || '/tmp';
const LOG_FILE       = path.join(HOME, '.claude', 'hooks', 'ruflo-enforcer.log');
const LAST_ROUTE_FILE = path.join(HOME, '.claude', 'hooks', 'ruflo-last-route.txt');

function log(msg) {
  try { fs.appendFileSync(LOG_FILE, `${new Date().toISOString()} ${msg}\n`); } catch {}
}

function writeLastRoute(action, chosen, final, confidence) {
  try {
    const pct = typeof confidence === 'number' ? Math.round(confidence * 100) : '';
    fs.writeFileSync(
      LAST_ROUTE_FILE,
      `${new Date().toISOString()} ${action} ${chosen}->${final} conf=${pct}\n`
    );
  } catch {}
}

// ---------------------------------------------------------------------------
// Keyword heuristics — edit these lists to tune routing.
// ---------------------------------------------------------------------------
const KEYWORDS = {
  haiku:  [
    'find', 'search', 'list', 'show', 'lookup', 'grep', 'rename', 'format',
    'add log', 'add print', 'typo', 'comment out', 'add comment', 'sort',
    'count', 'where is', 'what file', 'small fix',
  ],
  sonnet: [
    'implement', 'add', 'create', 'build', 'write', 'extract', 'convert',
    'test', 'review', 'check', 'verify', 'fix bug', 'update', 'modify',
    'replace', 'integrate', 'wire up', 'mirror', 'scaffold',
  ],
  opus:   [
    'architect', 'design', 'debug', 'refactor', 'investigate', 'audit',
    'optimize', 'analyze', 'plan', 'troubleshoot', 'why is', 'explain',
    'compare', 'evaluate', 'security', 'race condition', 'deadlock',
    'memory leak', 'performance', 'root cause',
  ],
};

// Map tier names to a numeric rank (1=cheapest, 3=most capable).
const MODEL_TIER = { haiku: 1, sonnet: 2, opus: 3 };

// ---------------------------------------------------------------------------
// classify(description) → { model, confidence, complexity }
// ---------------------------------------------------------------------------
function classify(description) {
  const text = description.toLowerCase();

  const scores = { haiku: 0, sonnet: 0, opus: 0 };
  for (const tier of Object.keys(scores)) {
    for (const kw of KEYWORDS[tier]) {
      if (text.includes(kw)) scores[tier]++;
    }
  }

  // Length boost — longer descriptions tend to be more complex.
  if (description.length > 200) scores.opus++;
  if (description.length > 400) scores.opus++;

  const total = scores.haiku + scores.sonnet + scores.opus;

  // Fallback when no keywords match.
  if (total === 0) {
    return { model: 'sonnet', confidence: 0, complexity: MODEL_TIER.sonnet / 3 - 0.05 };
  }

  // Pick the tier with the highest score.
  let best = 'sonnet';
  let bestScore = -1;
  for (const tier of Object.keys(scores)) {
    if (scores[tier] > bestScore) { bestScore = scores[tier]; best = tier; }
  }

  const confidence = Math.min(0.95, 0.5 + (bestScore / total) * 0.5);
  const complexity = MODEL_TIER[best] / 3 - 0.05;

  return { model: best, confidence, complexity };
}

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------
function emit(output) {
  process.stdout.write(JSON.stringify(output));
  process.exit(0);
}

function passthrough(chosen, reason) {
  writeLastRoute('PASSTHRU', chosen || 'unknown', chosen || 'unknown', null);
  if (reason) log(`PASSTHRU ${reason}`);
  emit({});
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
function main() {
  let raw = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', c => { raw += c; });
  process.stdin.on('end', () => {
    log(`FIRED raw_len=${raw.length}`);

    let parsed;
    try { parsed = JSON.parse(raw); } catch (e) {
      log(`PARSE_ERR ${e.message}`);
      return passthrough(null, 'parse');
    }

    const input        = parsed.tool_input || {};
    const description  = input.description || '';
    const chosenModel  = input.model || 'opus';

    log(`INPUT desc="${description.slice(0, 80)}" model=${chosenModel}`);

    if (!description || description.length < 5) {
      return passthrough(chosenModel, 'short-desc');
    }

    const { model: recommended, confidence: conf, complexity } = classify(description);

    log(`CLASSIFY recommends=${recommended} confidence=${conf.toFixed(2)}`);

    if (!MODEL_TIER[recommended]) return passthrough(chosenModel, 'unknown-tier');
    if (!(conf > 0.5))            return passthrough(chosenModel, 'low-confidence');

    const pct = Math.round(conf * 100);
    const cpx = Math.round(complexity * 100);

    if (recommended === chosenModel) {
      // AGREE — model already correct, surface the decision without rewriting.
      log(`AGREE ${chosenModel}`);
      writeLastRoute('AGREE', chosenModel, recommended, conf);
      const msg = `[RuFlo] Confirmed ${chosenModel} (${pct}% conf, ${cpx}% complexity)`;
      return emit({
        systemMessage: msg,
        hookSpecificOutput: {
          hookEventName:            'PreToolUse',
          permissionDecision:       'allow',
          permissionDecisionReason: msg,
          additionalContext:        msg,
        },
      });
    }

    // REWRITE — swap the model.
    log(`REWRITE ${chosenModel} -> ${recommended}`);
    writeLastRoute('REWRITE', chosenModel, recommended, conf);
    const updatedInput = Object.assign({}, input, { model: recommended });
    const msg = `[RuFlo] Auto-routed ${chosenModel} -> ${recommended} (${pct}% conf, ${cpx}% complexity)`;

    return emit({
      systemMessage: msg,
      hookSpecificOutput: {
        hookEventName:            'PreToolUse',
        permissionDecision:       'allow',
        permissionDecisionReason: msg,
        updatedInput,
        additionalContext:        msg,
      },
    });
  });
}

main();
