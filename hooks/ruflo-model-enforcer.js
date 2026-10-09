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
//
// Passthroughs (never rewritten), checked before the classifier:
//   • agent pin — ~/.claude/agents/<type>.md frontmatter `model:` and the call names no model
//     (agy-worker pins haiku; that pin is a deliberate cost decision);
//   • explicit-judgment — the call names a model AND the task is review/verify/audit/plan-shaped
//     (JUDGMENT_RE is byte-identical to route-resolver.js's — keep them in sync).
// FABLE_FALLBACK: a no-verdict call with no model would inherit the parent tier; under a Fable
// main thread (statusline's ~/.claude/.session-state.json) it is routed to FABLE_INHERIT_FALLBACK
// (default opus) instead of billing the subagent at Fable rates.

const fs   = require('fs');
const path = require('path');

const HOME           = process.env.HOME || '/tmp';
const LOG_FILE       = path.join(HOME, '.claude', 'hooks', 'ruflo-enforcer.log');
const LAST_ROUTE_FILE = path.join(HOME, '.claude', 'hooks', 'ruflo-last-route.txt');
const SESSION_STATE  = path.join(HOME, '.claude', '.session-state.json');

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
// fable is never recommended by the classifier; it is listed so FABLE_INHERIT_FALLBACK=fable validates.
const MODEL_TIER = { haiku: 1, sonnet: 2, opus: 3, fable: 4 };
const INHERIT_FALLBACK = MODEL_TIER[process.env.FABLE_INHERIT_FALLBACK]
  ? process.env.FABLE_INHERIT_FALLBACK
  : 'opus';

// Same regex as route-resolver.js — keep byte-identical.
const JUDGMENT_RE = /\b(review|re-?verif|verif(y|ication)|adversarial|audit|security|threat|adjudicat|judg(e|ment)|architect|plan(ning)?|critique|second opinion|red[- ]team)\b/i;

// True when the live interactive session runs a Fable-tier model. Reads the
// statusline's session-state cache; any doubt (missing, stale >30min, parse
// error) means false, so the call passes through untouched.
function sessionIsFable() {
  try {
    const st = JSON.parse(fs.readFileSync(SESSION_STATE, 'utf8'));
    const fresh = Math.abs(Date.now() / 1000 - (st.timestamp || 0)) < 1800;
    return fresh && /fable/i.test(st.model || '');
  } catch { return false; }
}

// Reads `model:` out of the YAML frontmatter of ~/.claude/agents/<type>.md.
// Any doubt (missing file, no frontmatter, no model line) returns null so the
// call routes normally.
function agentPinnedModel(subagentType) {
  try {
    if (!/^[A-Za-z0-9._-]+$/.test(subagentType)) return null;
    const file = path.join(HOME, '.claude', 'agents', `${subagentType}.md`);
    if (!fs.existsSync(file)) return null;
    const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
    if ((lines[0] || '').trim() !== '---') return null;
    for (let i = 1; i < lines.length; i++) {
      if (lines[i].trim() === '---') break;
      const m = /^model:\s*(\S+)\s*$/.exec(lines[i]);
      if (m) return m[1];
    }
    return null;
  } catch { return null; }
}

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

function passthrough(chosen, reason, input) {
  // A no-verdict call with no explicit model inherits the parent tier. Under
  // a Fable main thread that bills the subagent at Fable rates for no reason —
  // route it to INHERIT_FALLBACK instead. Confident verdicts, explicit
  // models, and non-Fable sessions never reach this branch.
  if (input && chosen === 'inherit' && sessionIsFable()) {
    writeLastRoute('FABLE_FALLBACK', 'inherit', INHERIT_FALLBACK, null);
    log(`FABLE_FALLBACK ${reason} -> ${INHERIT_FALLBACK}`);
    const msg = `[RuFlo] No routing verdict (${reason}) — inherit -> ${INHERIT_FALLBACK} (Fable stays main-thread only)`;
    return emit({
      systemMessage: msg,
      hookSpecificOutput: {
        hookEventName:            'PreToolUse',
        permissionDecision:       'allow',
        permissionDecisionReason: msg,
        updatedInput:             Object.assign({}, input, { model: INHERIT_FALLBACK }),
        additionalContext:        msg,
      },
    });
  }
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

    // Agent-definition pin: only when the CALL named no model — an explicit model on the call still wins.
    if (!input.model && input.subagent_type) {
      const pinned = agentPinnedModel(String(input.subagent_type));
      if (pinned) {
        writeLastRoute('PASSTHRU', 'agent-pinned', pinned, null);
        log(`PASSTHRU agent-pinned ${input.subagent_type}=${pinned}`);
        return emit({});
      }
    }
    const description  = input.description || '';
    // Explicit call-site model on a judgment task is the caller's deliberate choice.
    if (input.model && JUDGMENT_RE.test(`${description} ${String(input.prompt || '').slice(0, 600)}`)) {
      writeLastRoute('PASSTHRU', 'explicit-judgment', input.model, null);
      log(`PASSTHRU explicit-judgment model=${input.model} desc="${description.slice(0, 60)}"`);
      return emit({});
    }
    // 'inherit' = no model on the call: the subagent inherits the parent thread's tier
    // (whatever the session runs). A sentinel, deliberately absent from MODEL_TIER.
    const chosenModel  = input.model || 'inherit';

    log(`INPUT desc="${description.slice(0, 80)}" model=${chosenModel}`);

    if (!description || description.length < 5) {
      return passthrough(chosenModel, 'short-desc', input);
    }

    const { model: recommended, confidence: conf, complexity } = classify(description);

    log(`CLASSIFY recommends=${recommended} confidence=${conf.toFixed(2)}`);

    if (!MODEL_TIER[recommended]) return passthrough(chosenModel, 'unknown-tier', input);
    if (!(conf > 0.5))            return passthrough(chosenModel, 'low-confidence', input);

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
