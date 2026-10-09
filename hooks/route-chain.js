#!/usr/bin/env node
// route-chain.js — the ONE rewriting PreToolUse:Agent hook (Raza 2026-09-24: "I don't want to have
// to tell you when to dispatch what to Gemini"). Claude Code runs PreToolUse hooks in PARALLEL and
// keeps only one `updatedInput`, so route-resolver.js (provider) and ruflo-model-enforcer.js (Claude
// tier) fought each other: on 2026-09-23 18:10Z the resolver logged enforced=true → agy-worker while the
// agent that actually launched was general-purpose. This hook runs them SEQUENTIALLY on the same stdin:
//   1. route-resolver.js — if it rewrites (decision=agy under ROUTE_ENFORCE=1) its output wins, verbatim;
//   2. otherwise ruflo-model-enforcer.js decides the Claude tier and its output is returned
//      (if the enforcer isn't installed, the resolver's advisory output is returned as-is).
// Both children keep their own logs. Always exits 0; on any error emits {} (allow, unchanged).
'use strict';
const { spawnSync } = require('child_process');
const path = require('path'); const os = require('os');
const hooks = path.join(os.homedir(), '.claude', 'hooks');
function run(script, input) {
  const r = spawnSync(process.execPath, [path.join(hooks, script)], { input, encoding: 'utf8', timeout: 20000, env: process.env });
  if (r.status !== 0 || !r.stdout) return null;
  try { return JSON.parse(r.stdout.trim() || '{}'); } catch { return null; }
}
let raw = '';
try { raw = require('fs').readFileSync(0, 'utf8'); } catch { process.stdout.write('{}'); process.exit(0); }
const resolver = run('route-resolver.js', raw);
if (resolver && resolver.hookSpecificOutput && resolver.hookSpecificOutput.updatedInput) {
  process.stdout.write(JSON.stringify(resolver)); process.exit(0);
}
// Tier enforcer not installed (route-chain without the RuFlo component): the resolver's own output —
// advisory line or nothing — is the answer; never drop it to {}.
if (!require('fs').existsSync(path.join(hooks, 'ruflo-model-enforcer.js'))) {
  process.stdout.write(JSON.stringify(resolver || {})); process.exit(0);
}
const ruflo = run('ruflo-model-enforcer.js', raw) || {};
// carry the resolver's advisory line so the chat still shows the provider decision
if (resolver && resolver.hookSpecificOutput && resolver.hookSpecificOutput.additionalContext) {
  ruflo.hookSpecificOutput = ruflo.hookSpecificOutput || { hookEventName: 'PreToolUse', permissionDecision: 'allow' };
  const prev = ruflo.hookSpecificOutput.additionalContext || '';
  ruflo.hookSpecificOutput.additionalContext = [resolver.hookSpecificOutput.additionalContext, prev].filter(Boolean).join('\n');
}
process.stdout.write(JSON.stringify(ruflo)); process.exit(0);
