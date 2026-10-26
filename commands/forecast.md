---
description: Show which Codex/Gemini/Claude 5h windows are spoken for by running and waiting jobs across all sessions, and what is queued
---

Run the usage forecast and explain it in plain English.

```bash
node ~/.claude/scripts/quota-forecast.mjs
```

Then give a short read-out — the call, not the arithmetic:

1. **What's full** — any window marked FULL/OVER/TIGHT: which sessions' jobs fill it and when it frees up (the reset time).
2. **What's waiting** — jobs in the "waiting" list, whose they are, and when they start on their own (they re-check every 2 minutes and start the moment they fit; nothing needs doing).
3. **What to do** — usually nothing. Say so. Only if an urgent job is waiting: re-run it with `DISPATCH_PRIORITY=pin`, or `DISPATCH_ADMIT=off` to force it.

If asked "will X fit?", answer with a dry run, e.g.:
```bash
node ~/.claude/scripts/quota-forecast.mjs --admit --provider codex --tier high --size L --task what-if --dry-run
```
(`--provider agy --tier flash` for Gemini; sizes S/M/L/XL.)

Claude agents: running Claude subagents (all sessions) are counted on the Claude 5h row; they never wait — the agent router just avoids sending work to a 5h window that is already spoken for. The "Window sizes" line says whether the daily re-measure of each window's size changed anything.

How it decides (for questions): the caller picks the model from the task's needs; the forecast only decides when a job starts. It never switches vendor or downgrades a model. First come, first served; while another project is waiting, no project takes more than its fair share; a `DISPATCH_PRIORITY=pin` job goes first; a running job is never stopped. A job may fill a window to 85 % (100 % in the window's last hour).
