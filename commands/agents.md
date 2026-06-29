---
description: Show native Claude Code subagents (Agent/Task tool) — running vs done, their tasks, durations, completion
argument-hint: "[--lookback MINS] [--run-window SECS]  (optional; defaults 12h / 90s)"
---

Show the status of native Claude Code subagents across all recent sessions —
which are running, which finished, what each was tasked with, and a rough
completion count. This reads the subagent transcripts Claude Code maintains at
`~/.claude/projects/<project>/<sessionId>/subagents/agent-<id>.jsonl`, so it
works even for agents launched from another window and even when a session is
rate-limited. No hooks required.

## Procedure

1. Run the scanner, passing through any arguments:

   ```bash
   python3 ~/.claude/scripts/agents-status.py $ARGUMENTS
   ```

2. Present its output to the user as-is (it is already a formatted table). Do
   not re-summarize unless the user asks — the table is the deliverable.

3. If the user wants a true per-task completion **percentage** (not just
   running/done counts), remind them that native subagents are opaque — the
   reliable way to get `done/total %` is the manager-mode convention: the
   orchestrator calls `TaskCreate` once per work-item before fanning out, and
   each worker calls `TaskUpdate` (in_progress → completed). That populates the
   native bottom task tracker with a live `done/total`.

## Notes
- "RUNNING" = a transcript written within the last `--run-window` secs (default
  90). A long-thinking agent that hasn't written a tool call recently may show
  as idle — the "last write … ago" column makes this transparent.
- The bold name (e.g. `graceful-skipping-galaxy`) is Claude Code's auto-generated
  friendly handle, not the agent type. The task line conveys purpose.
- `--lookback` controls how far back finished agents are listed (mins; default 720).
