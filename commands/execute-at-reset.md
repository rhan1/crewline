---
description: Schedule a plan to execute automatically once the 5h window resets
argument-hint: <plan file path>
---

Schedule a one-shot execution that fires ~1 minute after the 5h rate limit resets. Use this when `/budget-check` returns ❌ (won't fit) and the user wants to walk away rather than keep planning.

## Task
Schedule execution of: $ARGUMENTS

## Procedure

### 1. Validate the plan file

- `$ARGUMENTS` must be an absolute file path.
- If missing or relative, stop and ask the user to save the plan to a file first (suggest `~/.claude/plans/<name>.md`).
- Resolve to an absolute path — the scheduled trigger runs later; relative paths could resolve wrong.

### 2. Read reset time from session state

Read `~/.claude/.session-state.json`:
- `rate_limits.five_hour.resets_at` — Unix epoch of next 5h reset

If the cache file is missing or the timestamp >60s stale, stop — don't schedule against stale data.

### 3. Compute the fire time

- Target epoch = `resets_at + 60` (1-minute buffer past reset)
- Convert to local time → extract `minute`, `hour`, `day-of-month`, `month`
- If target minute is 0 or 30, bump by +1 to avoid the global fleet spike (per CronCreate guidance).
- Build cron: `"<min> <hour> <dom> <month> *"`

### 4. Create the trigger

Call `CronCreate` with:
- `cron`: the expression from step 3
- `prompt`: `"Execute the plan at <absolute-path>. Read it first, confirm it matches the intent, then work through the steps. Stop and surface anything ambiguous before committing destructive changes."`
- `recurring`: `false` (one-shot, auto-deletes after firing)
- `durable`: `true` (persists to disk, survives Claude Code restarts)

### 5. Confirm to the user

Report:
- 🗓️ Scheduled for: `<local YYYY-MM-DD HH:MM>`
- 📄 Plan: `<absolute path>`
- 🆔 Job ID: `<id from CronCreate>`
- ⚠️ Note: Claude Code must be *running* for the trigger to fire. The schedule persists across restarts, but a completely closed app means the trigger queues and fires on next start.
- 💡 To cancel: `CronDelete` with the job ID above, or invoke `/cancel-scheduled-execution` (if built).

### 6. Length

Keep output under 100 words. One clean confirmation block; no filler.
