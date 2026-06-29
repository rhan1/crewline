#!/usr/bin/env node
// agent-activity-log.js — SubagentStart / SubagentStop hook.
//
// Appends one line per native-subagent lifecycle event to
// ~/.claude/agent-activity.jsonl, giving /agents (and any future in-Warp
// surface) a persistent completion history + a cheap running-count without
// globbing every session transcript.
//
// SAFETY (critical): this fires on EVERY subagent in EVERY session. It must
// never disrupt subagent execution, so it:
//   • ALWAYS exits 0 (a non-zero exit / "block" decision on SubagentStop would
//     re-enter the subagent),
//   • never writes to stdout,
//   • swallows every error.
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

function done() { process.exit(0); }

let raw = '';
try {
  raw = fs.readFileSync(0, 'utf8');
} catch (_) { done(); }

try {
  if (!raw || raw.length > 1000000) done(); // ignore empty / absurd payloads

  let d = {};
  try { d = JSON.parse(raw); } catch (_) { done(); }

  // "SubagentStart" -> "start", "SubagentStop" -> "stop"
  const event = String(d.hook_event_name || '')
    .replace(/^Subagent/, '')
    .toLowerCase() || 'unknown';

  const rec = {
    ts: Math.floor(Date.now() / 1000),
    event,
    agent_id: d.agent_id || null,
    agent_type: d.agent_type || null,
    session_id: d.session_id || null,
    cwd: d.cwd || null,
  };

  const file = path.join(os.homedir(), '.claude', 'agent-activity.jsonl');
  fs.appendFileSync(file, JSON.stringify(rec) + '\n');
} catch (_) {
  // swallow — never let logging break a subagent
}

done();
