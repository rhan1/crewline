#!/usr/bin/env node
/**
 * agy-router — PreToolUse:Agent advisory that pushes eligible work onto Antigravity.
 *
 * Why this exists: agy's quota sits ~0-1% used every week while the Anthropic 7-day window
 * is what actually strands Raza. Benchmarked 2026-08-16/18, agy TIED Opus at 52/52 on the
 * hard tier and was the fastest executor — there is no measured quality reason to prefer a
 * Claude subagent for mechanical or file-reading work.
 *
 * Deliberately a SEPARATE hook from ruflo-model-enforcer.js: that one is load-bearing for
 * model routing, and a bug here must not be able to break it.
 *
 * Advisory only — never denies, never rewrites. It classifies the Agent call and, when the
 * profile is clearly agy-eligible, tells Claude to use `subagent_type: "agy-worker"`. Raza
 * never types anything; the hook plus the CLAUDE.md rule are the trigger.
 *
 * Disable with AGY_ROUTER_OFF=1.
 */
const fs = require('fs');

function emit(obj) { process.stdout.write(JSON.stringify(obj)); process.exit(0); }
function pass() { process.exit(0); }

if (process.env.AGY_ROUTER_OFF === '1') pass();

let raw = '';
try { raw = fs.readFileSync(0, 'utf8'); } catch { pass(); }

let payload;
try { payload = JSON.parse(raw); } catch { pass(); }

const input = payload?.tool_input || {};
const prompt = String(input.prompt || '');
const desc = String(input.description || '');
const already = String(input.subagent_type || '');
const text = `${desc}\n${prompt}`.toLowerCase();

// Already routed, or a deliberate fork/self-delegation — leave it alone.
if (/agy/i.test(already) || already === 'fork') pass();

// ── Disqualifiers: things agy genuinely cannot or should not do ───────────────
// Kept broad on purpose. A false "route to agy" wastes a dispatch and, worse, teaches
// distrust of the hook; a missed opportunity only costs some Claude quota.
const BLOCKERS = [
  // agy headless cannot drive its browser: returns empty-but-success or hangs.
  /\bbrowser\b|playwright|chrome-devtools|screenshot|lighthouse|click |navigate |devtools/,
  // VPN/credential-gated data work.
  /\bmysql\b|\bpsql\b|postgres|\bdb99\b|\bdb01\b|limpar|keychain|\bvpn\b|credential|\bsecret\b/,
  // MCP tools are not available inside agy.
  /\bmcp\b|codebase-memory|context7|scrapling|roseland/,
  // Judgment / security / anything where being wrong is expensive.
  /security review|threat model|vulnerabilit|audit the security|is this safe/,
  // Explicitly interactive or user-facing decisions.
  /ask the user|confirm with|decide whether we should|recommend to raza/,
];
if (BLOCKERS.some((re) => re.test(text))) pass();

// ── Positive signals: profiles agy is measured-good at ───────────────────────
const EXPLORE = /\b(explore|search|find|locate|grep|inventory|sweep|read through|which file|where is|map out|list all|survey)\b/;
const MECHANICAL = /\b(write|implement|generate|scaffold|refactor|convert|transform|port|parse|normali[sz]e|dedupe|script|boilerplate|test cases|unit tests)\b/;
const BULK = /\b(each of|all of the|every file|batch|bulk|across the repo|for all|one per)\b/;
const LONGCTX = /\b(summari[sz]e|extract from|read the entire|whole file|long log|transcript|large file)\b/;

const hits = [];
if (EXPLORE.test(text)) hits.push('exploration/file-reading');
if (MECHANICAL.test(text)) hits.push('mechanical code');
if (BULK.test(text)) hits.push('batch');
if (LONGCTX.test(text)) hits.push('long-context read');

if (!hits.length) pass();

// Very short asks are cheaper done inline than specced out and verified.
if (prompt.length < 200) pass();

const why = hits.join(' + ');
const msg =
  `[agy] agy-eligible (${why}) — spawn this with subagent_type: "agy-worker" so it bills ` +
  `Gemini quota instead of the Anthropic 7-day window. agy tied Opus 52/52 on the hard-tier ` +
  `benchmark, so this is not a quality downgrade. Keep it on Claude only if it needs ` +
  `browser/DB/MCP access, security judgment, or is under ~30 lines of output.`;

emit({
  systemMessage: msg,
  hookSpecificOutput: {
    hookEventName: 'PreToolUse',
    permissionDecision: 'allow',
    permissionDecisionReason: msg,
    additionalContext: msg,
  },
});
