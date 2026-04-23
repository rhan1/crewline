---
description: Force-dispatch a task to Gemini CLI via the planner/tester workflow
argument-hint: <task description — ideally long-context, multi-modal, or batch-style>
---

Run the Gemini dispatch workflow for the task below, even if the auto-dispatch heuristics wouldn't have fired. Do NOT shortcut the spec-writing or smoke-test steps.

## When to prefer Gemini over Codex

Gemini is the right executor when ANY of these apply:
- **Long-context** — input > ~150k tokens (whole repo dump, large logs, big CSV/JSON, long PDFs). Codex's ~200k window can't fit; Gemini's 2M can.
- **Multi-modal** — input includes images, PDFs, screenshots, or video. Codex CLI is text-only.
- **Parallel batch** — 5+ similar sub-tasks to fire concurrently. Codex Plus caps at ~30 msg / 3h; Gemini Pro has more headroom.
- **Codex rate-limited** — existing fallback behavior. `~/.claude/codex-last.json` shows a recent rate-limit failure.

For tight pattern-following on a single file (mirror this Vercel serverless style exactly), prefer Codex.

## Task

$ARGUMENTS

## Workflow

1. **Plan.** Read the referenced files, pattern sources, and data endpoints yourself. If anything essential is missing (target path, output shape, data-source URL, attachment paths), ask before writing the spec — thin specs produce thin code.

2. **Write the spec** to `/tmp/gemini-dispatch-<short-task-name>-<unix-ts>.{txt,json}`.

   **Text spec (most cases)** — `.txt` file containing the full prompt. Cover:
   - Exact target file path (if writing code)
   - 2–3 pattern files to mirror (style + error-handling conventions)
   - Data sources and expected fields
   - Output shape (JSON for APIs, component signature for UI, markdown for analyses)
   - Explicit "do not do" constraints — no npm/git/vercel/deploy, no tests/READMEs, no modifying other files, no network validation

   **Multi-modal spec** — `.json` manifest:
   ```json
   {
     "prompt": "Compare these two dashboard screenshots and list every visual difference you see.",
     "attachments": ["/absolute/path/to/before.png", "/absolute/path/to/after.png"]
   }
   ```
   The wrapper appends `@/path/...` references inline so Gemini reads them as part of the prompt context.

   > **Multi-modal workspace restriction:** Gemini CLI only reads files in the current working directory or `~/.gemini/tmp/<project-name>/`. Files outside those paths silently fail and Gemini may hallucinate from the prompt description. Stage attachments inside the project (e.g. a `.gemini-tmp/` dir) before dispatch.

3. **Dispatch** via `~/.claude/scripts/gemini-dispatch.sh <spec-path> <short-task-name>`. The wrapper runs `gemini --yolo -p "..."`, captures elapsed time + exit code to `~/.claude/gemini-last.json`, and tees the full log to `~/.claude/logs/gemini-<ts>.log`.

4. **Smoke-test** the output before claiming success:
   - API handler → mock `req`/`res` Node harness against live data
   - UI component → dev server + browser/curl verification
   - Analysis/summary → spot-check claims against the source data
   - Multi-modal extraction → cross-check extracted fields against the source image/PDF

5. **Fix small bugs directly** (< 10 lines). Re-dispatch only if the change is substantial. If Gemini fails or rate-limits, fall back to `/dispatch-codex` — both executors have rough quality parity on code gen.

6. **Report**: what shipped, which bugs the smoke test caught, elapsed time, attachment count (if any), integration status.
