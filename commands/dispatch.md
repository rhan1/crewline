---
description: Dispatch a task to any registered LLM CLI via the planner/tester workflow
argument-hint: <model_id> <task description with file paths and pattern references>
---

Run the dispatch workflow for the task below using the specified model. Do NOT shortcut the spec-writing or smoke-test steps.

The first word of `$ARGUMENTS` is the **model ID** (e.g. `codex`, `gemini`, `qwen`, `ollama`, `llm`). Everything after it is the task.

## Task

$ARGUMENTS

## Workflow

1. **Parse the model ID.** Extract the first token of `$ARGUMENTS` as the model ID; the rest is the task description. If the model ID is blank or unrecognized, check `~/.claude/orchestrator-models.json` for available models and ask the user which to use.

2. **Plan.** Read the referenced files, pattern sources, and data endpoints yourself. If anything essential is missing (target path, output shape, data-source URL), ask before writing the spec — thin specs produce thin code.

3. **Write the spec** to `/tmp/dispatch-<model_id>-<short-task-name>-<unix-ts>.txt`. Cover:
   - Exact target file path
   - 2–3 pattern files to mirror (style + error-handling conventions)
   - Data sources and expected fields
   - Output shape (JSON for APIs, component signature for UI)
   - Explicit "do not do" constraints — no npm/git/vercel/deploy, no tests/READMEs, no modifying other files, no network validation

4. **Dispatch** via `~/.claude/scripts/llm-dispatch.sh <model_id> <spec-path> <short-task-name>`. The wrapper runs the CLI, captures elapsed time + exit code to the model's `last_file` (path in `~/.claude/orchestrator-models.json`), and tees the full log to `~/.claude/logs/llm-dispatch-<model_id>-<ts>.log`.

5. **Smoke-test** the output before claiming success:
   - API handler → mock `req`/`res` Node harness against live data
   - UI component → dev server + browser/curl verification
   - Script → run against real input
   - Analysis/summary → spot-check claims against source data

6. **Fix small bugs directly** (< 10 lines). Re-dispatch only if the change is substantial. If the chosen model fails or rate-limits, re-dispatch to a different model ID — `/dispatch codex <task>` or `/dispatch gemini <task>`.

7. **Report**: what shipped, which bugs the smoke test caught, elapsed time, integration status.

## Available models

Run: `jq '.models[] | {id, display_name, command}' ~/.claude/orchestrator-models.json`

Or check `~/.claude/orchestrator-models.json` directly. To add a model, see the Model Registry section in the repo README, or re-run `./install.sh`.
