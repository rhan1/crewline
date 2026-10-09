#!/usr/bin/env node
// agy-worker-audit.js — SubagentStop hook. When an `agy-worker` subagent stops, prove that IT ran
// Gemini. Fallback (no transcript path in the payload): a gemini log newer than the agent's start, marked
// UNATTRIBUTED because other sessions also dispatch. 2026-09-24 04:3x: the first version passed a worker that
// never called Gemini because another session's job finished in the same minute — hence the transcript scan.
//
// 2026-10-08 (D5): "dispatched" now needs ALL THREE, from the transcript:
//   1. a Bash tool_use whose command INVOKES gemini-dispatch.sh (a command segment starts with it, after
//      VAR=val / env / bash prefixes; heredoc bodies and # comments are stripped first — a mention is not a call);
//   2. that tool_use's tool_result is not is_error (hook denials and failed calls are is_error:true);
//   3. a ~/.claude/logs/gemini-*.log with mtime >= the agent's start (agent-activity.jsonl start, else the
//      transcript's first timestamp).
// Anything else is a VIOLATION, and a non-DISPATCHED verdict is now surfaced to chat via the hook's JSON
// `systemMessage` (it used to go only to stderr at exit 0, which nobody sees) as well as route-violations.jsonl.
// SAFETY: always exit 0, stdout only ever carries {"systemMessage": …}, swallow errors.
'use strict';
const fs = require('fs'); const os = require('os'); const path = require('path');
function done(msg) { if (msg) { try { process.stdout.write(JSON.stringify({ systemMessage: msg })); } catch (_) {} } process.exit(0); }

// Does this Bash command actually invoke gemini-dispatch.sh?
const INVOKE_RE = /(^|[;&|\n])[ \t]*(?:[A-Za-z_]\w*=\S*[ \t]+)*(?:env[ \t]+(?:[A-Za-z_]\w*=\S*[ \t]+)*)?(?:(?:bash|sh|zsh)[ \t]+)?["']?(?:~|\$HOME|\$\{HOME\}|\/[^\s;&|'"]*)\/\.claude\/scripts\/gemini-dispatch\.sh["']?(?=[\s;&|]|$)/;
function invokesDispatch(cmd) {
  // drop heredoc bodies (<<'TAG' … TAG) then unquoted-ish comments, then test command positions
  let c = String(cmd).replace(/<<-?[ \t]*(['"]?)(\w+)\1[^\n]*\n(?:[\s\S]*?\n)?[ \t]*\2[ \t]*(?=\n|$)/g, (m) => m.split('\n')[0]);
  c = c.split('\n').map((l) => l.replace(/(^|[ \t;&|])#.*$/, '$1')).join('\n');
  return INVOKE_RE.test(c);
}

function newestGeminiLog(home) {
  let newest = 0;
  try { for (const f of fs.readdirSync(path.join(home, '.claude', 'logs'))) if (/^gemini-.*\.log$/.test(f)) newest = Math.max(newest, Math.floor(fs.statSync(path.join(home, '.claude', 'logs', f)).mtimeMs / 1000)); } catch (_) {}
  return newest;
}
function activityStart(home, agentId) {
  try {
    const lines = fs.readFileSync(path.join(home, '.claude', 'agent-activity.jsonl'), 'utf8').trim().split('\n');
    for (let i = lines.length - 1; i >= 0 && i >= lines.length - 2000; i--) { let r; try { r = JSON.parse(lines[i]); } catch (_) { continue; } if (r.event === 'start' && r.agent_id === agentId) return r.ts; }
  } catch (_) {}
  return null;
}

try {
  const d = JSON.parse(fs.readFileSync(0, 'utf8') || '{}');
  if (String(d.hook_event_name || '') !== 'SubagentStop') done();
  if (String(d.agent_type || '') !== 'agy-worker') done();
  const home = os.homedir();
  let verdict = 'UNKNOWN', how = 'none', dispatchCmd = null, why = null;
  let startTs = activityStart(home, d.agent_id);
  const newest = newestGeminiLog(home);
  const tp = d.agent_transcript_path || d.transcript_path || null;
  if (tp && fs.existsSync(tp)) {
    how = 'transcript';
    const calls = new Map(); const results = new Map(); let firstTs = null;
    for (const line of fs.readFileSync(tp, 'utf8').split('\n')) {
      if (!line.trim()) continue;
      let j; try { j = JSON.parse(line); } catch (_) { continue; }
      if (!firstTs && j.timestamp) { const t = Date.parse(j.timestamp); if (!isNaN(t)) firstTs = Math.floor(t / 1000); }
      const m = j.message || j;
      if (!Array.isArray(m.content)) continue;
      for (const c of m.content) {
        if (!c) continue;
        if (c.type === 'tool_use' && c.name === 'Bash' && invokesDispatch((c.input || {}).command || '')) calls.set(c.id, String(c.input.command));
        if (c.type === 'tool_result' && c.tool_use_id) results.set(c.tool_use_id, c);
      }
    }
    if (!startTs) startTs = firstTs;
    let okCall = null, sawErr = false;
    for (const [id, cmd] of calls) {
      const r = results.get(id);
      if (r && r.is_error !== true) { okCall = cmd; break; }
      sawErr = true;
    }
    if (!calls.size) { verdict = 'VIOLATION'; why = 'no Bash tool_use invoking gemini-dispatch.sh (a mention in text or a comment does not count)'; }
    else if (!okCall) { verdict = 'VIOLATION'; why = sawErr ? 'the gemini-dispatch.sh call errored or was denied' : 'the gemini-dispatch.sh call has no tool_result'; dispatchCmd = [...calls.values()][0].slice(0, 200); }
    else if (!startTs || newest < startTs - 5) { verdict = 'VIOLATION'; why = 'no ~/.claude/logs/gemini-*.log written after the agent started'; dispatchCmd = okCall.slice(0, 200); }
    else { verdict = 'DISPATCHED'; dispatchCmd = okCall.slice(0, 200); }
  } else {
    how = 'time-window';
    verdict = startTs && newest >= startTs - 5 ? 'UNATTRIBUTED' : 'VIOLATION';
    why = verdict === 'UNATTRIBUTED' ? 'no transcript; a gemini log appeared after start but may be another session\'s' : 'no transcript and no gemini log after start';
  }
  const rec = { ts: Math.floor(Date.now() / 1000), agent_id: d.agent_id || null, session_id: d.session_id || null, how, verdict, why, dispatchCmd, start_ts: startTs || null, newest_gemini_log: newest || null, payload_keys: Object.keys(d) };
  try { fs.appendFileSync(path.join(home, '.claude', 'route-violations.jsonl'), JSON.stringify(rec) + '\n'); } catch (_) {}
  if (verdict !== 'DISPATCHED') {
    const msg = `[agy-worker AUDIT] ${verdict}: agy-worker ${d.agent_id || ''} — ${why} (${how}). If it did the work itself, that ran on Claude tokens — re-dispatch via ~/.claude/scripts/gemini-dispatch.sh.`;
    try { process.stderr.write(msg + '\n'); } catch (_) {}
    done(msg);
  }
} catch (_) {}
done();
