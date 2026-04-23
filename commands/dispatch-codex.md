---
description: Force-dispatch a task to Codex CLI via the planner/tester workflow
argument-hint: <task description with file paths and pattern references>
---

Run the Codex dispatch workflow for the task below, even if the auto-dispatch heuristics wouldn't have fired. Do NOT shortcut the spec-writing or smoke-test steps.

## Task
$ARGUMENTS

## Workflow

1. **Plan.** Read the referenced files, pattern sources, and data endpoints yourself. If anything essential is missing (target path, output shape, data-source URL), ask before writing the spec — thin specs produce thin code.

2. **Write the spec** to `/tmp/codex-dispatch-<short-task-name>-<unix-ts>.txt`. Cover:
   - Exact target file path
   - 2–3 pattern files to mirror (style + error-handling conventions)
   - Data sources and expected fields
   - Output shape (JSON for APIs, component signature for UI)
   - Explicit "do not do" constraints — no npm/git/vercel/deploy, no tests/READMEs, no modifying other files, no network validation

3. **Dispatch** via `~/.claude/scripts/codex-dispatch.sh <spec-path> <short-task-name>`. The wrapper runs `codex exec`, captures tokens/elapsed to `~/.claude/codex-last.json`, and tees full log to `~/.claude/logs/codex-<ts>.log`.

4. **Smoke-test** the output before claiming success:
   - API handler → mock `req`/`res` Node harness against live data
   - UI component → dev server + browser/curl verification
   - Script → run against real input

5. **Fix small bugs directly** (< 10 lines). Re-dispatch only if the change is substantial. If Codex fails or rate-limits, fall back to `/dispatch-gemini` or `gemini --yolo -p "$(cat spec)"`.

6. **Report**: what shipped, which bugs the smoke test caught, tokens used, wall-clock time, integration status.
