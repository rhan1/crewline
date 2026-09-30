---
description: Force-dispatch a task to Codex CLI via the planner/tester workflow
argument-hint: <task description with file paths and pattern references>
---

Run the Codex dispatch workflow for the task below, even if the auto-dispatch heuristics wouldn't have fired. Do NOT shortcut the spec-writing or smoke-test steps.

> **Executor:** Codex CLI, **tier-routed**. `codex-dispatch.sh` picks a tier per task (auto-routing tops out at `high`; `max`/`algo` only when forced):
>
> | Tier | Model | Effort | service_tier | Typical work |
> |---|---|---|---|---|
> | `lite` | gpt-6-luna | low | default | renames, typos, reformatting, boilerplate |
> | `std` | gpt-5.6-terra | high | default | most mechanical code / API / data-transform specs (there is no GPT-6 Terra) |
> | `high` | gpt-6-sol | high | default | executor top tier: hard mechanical builds, multi-file parsers |
> | `max` | gpt-6-astra | high | default | forced only: audits, planning review, hard debugging |
> | `algo` | gpt-6-astra | ultra | default | forced only: genuinely algorithmic specs |
>
> `flex` was removed server-side on 2026-09-29 (every model returns `Unsupported service_tier: flex`) — never set `CODEX_SERVICE_TIER=flex`. Overrides: `CODEX_TIER=lite|std|high|max|algo` forces a tier; `CODEX_ROUTER=off` reverts to whatever `~/.codex/config.toml` says; `CODEX_MODEL` / `CODEX_EFFORT` / `CODEX_SERVICE_TIER` override individual knobs. Anything unexpected (classifier missing, bad tier name) falls back to `std`, never `max`.

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
