# LLM Orchestrator + Status Line

A drop-in Claude Code setup that gives you:

1. **A multi-row statusline** showing Claude context, rate-limits (5h + 7d with absolute reset clocks), cache savings, cost, plus dedicated rows for Codex and Gemini dispatch activity. Rate limits use **cross-session reconciliation** (every open session converges on one shared number instead of each showing its own stale snapshot); executor rows show a live **`running now`** badge while a dispatch is in flight; and a **`bg-claude`** indicator surfaces background `claude -p` jobs that are otherwise invisible to the 5h bar.
2. **Slash commands** that force-dispatch work to Codex or Gemini, budget-check a plan before committing to execution, schedule plans for the next rate-limit window, and show a live view of native subagents (`/agents`).
3. **Hooks** that warn you before a heavy turn blows the 5h window, rotate dispatch logs weekly, and (optionally) log native-subagent lifecycle for the `/agents` monitor.

The core idea: keep Claude (Opus / Sonnet) on judgment, debugging, smoke-testing, and architecture. Delegate mechanical code generation and long-context / multi-modal work to Codex and Gemini — they're cheaper, sometimes faster, and each has a capability profile the other can't match.

## Example statusline

```
Opus 4.7 (1M context) | [████░░░░░░] 38% | [██░░░░░░░░] 5h:20% (4h 52m - 05:01) | [█████▉░░░░] 7d:59% (3d 13h - 13:09) | cache:82% (saved $4.21) | $31.32 | 2797m | @yourname
codex plus · gpt-5.4 | [██░░░░] 8/~50 · 42.1k toks (5h) | last: scraper-api · 6.2k toks · 2m ago · 47s
gemini pro · 3.1-pro-preview | [▌░░░░░] 2/~100 · 8.4k chars (5h) | last: summarize-log · 4.1k chars · 12m ago · 18s
```

Rows 2 and 3 only render when Codex / Gemini are installed. First row always renders.

## Prerequisites

- **Claude Code** — [download](https://claude.com/claude-code) (required; this is a Claude Code add-on)
- **jq** — `brew install jq` (statusline uses it to parse Claude Code's stdin JSON)
- **Node.js** ≥ 18 — for the two hooks (`brew install node` or nvm)
- **Python 3** — for the dispatch wrappers' JSON helpers (preinstalled on macOS)

**Optional but recommended:**
- **[Codex CLI](https://github.com/openai/codex)** — `brew install codex` — enables Codex dispatches and the Codex statusline row. Requires a ChatGPT Plus/Pro/Enterprise subscription.
- **[Gemini CLI](https://github.com/google-gemini/gemini-cli)** — `npm install -g @google/gemini-cli` then `gemini` to OAuth — enables Gemini dispatches and the Gemini statusline row. Free tier works; Pro recommended for larger contexts.

The statusline degrades gracefully — if `codex` or `gemini` isn't installed, those rows simply don't render.

**Platform:** Built on macOS (uses BSD `date -j` syntax and `stat -f "%m"`). Should work on Linux with `date -d` / `stat -c "%Y"` tweaks — PRs welcome.

## Install

Quickest path:

```bash
git clone https://github.com/rhan1/LLM-orchestrator-status.git
cd LLM-orchestrator-status
./install.sh
```

The installer:
1. Prompts once per optional component — accept the default (Y) to match the author's setup, or decline to skip. Pass `--all` to skip prompts and install everything, or `--minimal` to install only the statusline.
2. Backs up any existing `~/.claude/statusline.sh`, `~/.claude/scripts/`, `~/.claude/commands/`, and `~/.claude/hooks/` targets to `~/.claude/backups/pre-install-<ts>/`
3. Symlinks this repo's files into `~/.claude/` (so `git pull` upgrades everything)
4. Prints the settings.json snippet for only the components you installed

**Manual install** — if you'd rather see what's going on:

```bash
mkdir -p ~/.claude/{scripts,commands,hooks}
cp statusline.sh ~/.claude/statusline.sh
cp scripts/*.sh ~/.claude/scripts/
cp commands/*.md ~/.claude/commands/
cp hooks/*.js ~/.claude/hooks/
chmod +x ~/.claude/statusline.sh ~/.claude/scripts/*.sh
```

Then merge `examples/settings.json` into `~/.claude/settings.json`.

## Slash commands

Once installed and the settings.json snippet is merged, these are available via the Claude Code skill picker or by typing `/<name>`:

| Command | When to use |
|---|---|
| `/dispatch <model_id> <task>` | Dispatch to any model in the registry — e.g. `/dispatch codex <task>`, `/dispatch qwen <task>` |
| `/dispatch-codex <task>` | Shortcut for `/dispatch codex` — Codex for mechanical code gen, CRUD scaffolds, pattern-following |
| `/dispatch-gemini <task>` | Shortcut for `/dispatch gemini` — Gemini for long-context (>150k tokens), multi-modal, parallel-batch |
| `/budget-check <plan>` | Pre-flight: does this plan fit in the remaining 5h window? Returns ✅ / ⚠️ / ❌ with concrete options |
| `/execute-at-reset <plan>` | Schedule a plan to auto-execute ~1 min after the next 5h reset (via Claude Code's `CronCreate`) |
| `/agents` | Live view of native Claude subagents (Agent/Task tool) — running vs done, each one's task, duration, and a completion count. Reads the subagent transcripts Claude Code maintains, so it works across sessions and even when rate-limited |

## Hooks

| Hook | Event | What it does |
|---|---|---|
| `auto-budget-check.js` | `UserPromptSubmit` | Scans each prompt for execution-intent keywords (execute, implement, deploy, refactor…). If matched AND 5h usage ≥40%, injects a `[auto-budget]` advisory into the context so Claude sees it before starting. Escalates to 🚨 at ≥80%. |
| `weekly-maintenance.js` | `SessionStart` | Once per 7 days, rotates dispatch logs older than 30 days and refreshes the Gemini model cache. Runs in background (`child.unref()`) so session startup is never blocked. |
| `ruflo-model-enforcer.js` | `PreToolUse` (Agent) | Optional. See below. |

### RuFlo (model routing)

`hooks/ruflo-model-enforcer.js` fires on every `Agent` tool call and rewrites the `model` parameter to the cheapest tier that fits the task. It uses keyword heuristics — no external CLI, no network calls, no LLM inference. The whole thing is ~120 lines of Node.js with no dependencies.

**How it works:** the hook scores the agent's `description` field against three keyword lists (haiku / sonnet / opus). Longer descriptions get a small complexity boost toward opus. When the winning tier beats a 0.5 confidence threshold, the hook either confirms the chosen model (AGREE) or swaps it (REWRITE). Below threshold it passes through without touching anything.

**Writes:** `~/.claude/hooks/ruflo-last-route.txt` — a one-line record of the last routing decision, consumed by the statusline. `~/.claude/hooks/ruflo-enforcer.log` — append-only log of every firing.

**Tuning:** the keyword lists are at the top of `hooks/ruflo-model-enforcer.js` in a `KEYWORDS` object. Add or remove terms to match your own usage patterns. The length thresholds (200 / 400 chars) are also in the same block.

The installer prompts before installing this hook. To add it later, copy or symlink `hooks/ruflo-model-enforcer.js` to `~/.claude/hooks/` and add the `PreToolUse` block from `examples/settings.json`.

## Statusline

Writes `~/.claude/.session-state.json` on every tick (every ~10s). This file is the ground truth for `/budget-check`, `/execute-at-reset`, and `auto-budget-check.js` — the statusline is the only component that actually sees Claude Code's rate-limit data, so it mirrors it into a file the other components can read.

### Customization

Environment variables (set in your shell profile):

| Var | Default | Purpose |
|---|---|---|
| `CODEX_DISPATCH_CAP_5H` | `50` | Messages-per-5h cap used for the Codex usage bar. ChatGPT Plus is typically 20–100 on GPT-5; pick the midpoint or tune to your actual plan. |
| `GEMINI_DISPATCH_CAP_5H` | `100` | Same idea for Gemini. Free tier has lower effective caps — tune down if you see the bar peg at 100%. |
| `GEMINI_DISPATCH_MODEL` | `gemini-3.1-pro-preview` | The model the Gemini dispatch wrapper forces via `-m`. If you don't have Pro, set this to `gemini-2.0-flash` or another model your account can access. |

To change the statusline colors, the gradient is defined in `pct_color()` near the top — green → yellow → red by default.

## Architecture

```
 ┌─────────────────────────────────────────┐
 │ Claude Code (you're typing here)        │
 └─────────────────────────────────────────┘
    │                           │
    │ stdin JSON every ~10s     │ hook events
    ▼                           ▼
 ┌──────────────────┐    ┌─────────────────────────┐
 │ statusline.sh    │    │ hooks/                  │
 │ - renders 3 rows │    │ - auto-budget-check.js  │
 │ - writes cache → │    │ - weekly-maintenance.js │
 └──────────────────┘    └─────────────────────────┘
           │                      │
           ▼                      ▼
    ~/.claude/.session-state.json
           │                      │
           │                      │
           ▼                      ▼
 ┌─────────────────────────────────────────┐
 │ slash commands read this cache:         │
 │  /budget-check, /execute-at-reset       │
 └─────────────────────────────────────────┘

 ┌─────────────────────────────────────────┐
 │ /dispatch-codex, /dispatch-gemini       │
 │  → write spec to /tmp/...               │
 │  → run scripts/codex-dispatch.sh or     │
 │          scripts/gemini-dispatch.sh     │
 │  → wrapper writes codex-last.json       │
 │    or gemini-last.json                  │
 │  → statusline picks those up next tick  │
 └─────────────────────────────────────────┘
```

## Model registry

`~/.claude/orchestrator-models.json` is the single source of truth for the statusline and `/dispatch`. The install wizard writes it; you can also edit it by hand.

### Schema

```json
{
  "version": 1,
  "models": [
    {
      "id":             "qwen",
      "display_name":   "qwen 2.5",
      "model_label":    "72b-instruct",
      "command":        "qwen",
      "args_template":  "run {prompt_file}",
      "rate_limit_5h":  200,
      "color":          "#e05c2a",
      "last_file":      "~/.claude/qwen-last.json"
    }
  ]
}
```

| Field | Required | Description |
|---|---|---|
| `id` | yes | Unique key. Used for log file naming and `/dispatch <id>`. |
| `command` | yes | The CLI binary name (must be on `$PATH`). |
| `args_template` | yes | Command arguments. `{prompt_file}` is replaced with the spec file path. `{output_file}` is available for CLIs that write output to a file rather than stdout. |
| `last_file` | yes | Path where the dispatcher writes the last-run JSON (`~` is expanded). Statusline reads this. |
| `display_name` | no | Label shown in the statusline. Defaults to `id`. |
| `model_label` | no | Model version shown next to the display name. |
| `rate_limit_5h` | no | Dispatch cap per 5-hour rolling window — used for the usage bar. Omit if you don't want a bar. |
| `color` | no | `#rrggbb` hex color for the statusline row label. Defaults to white. |

### Adding a model without re-running install

1. Open `~/.claude/orchestrator-models.json`.
2. Append an entry to the `models` array following the schema above.
3. Restart Claude Code (or wait for the next statusline tick).

No hook changes or script installs needed — the generic dispatcher `~/.claude/scripts/llm-dispatch.sh` handles all models in the registry.

### Example: `llm` (Simon Willison's LLM CLI)

```json
{
  "id":            "llm",
  "display_name":  "llm",
  "model_label":   "claude-3-haiku",
  "command":       "llm",
  "args_template": "prompt -m claude-3-haiku < {prompt_file}",
  "rate_limit_5h": 500,
  "color":         "#3db8f5",
  "last_file":     "~/.claude/llm-last.json"
}
```

Then dispatch with: `/dispatch llm <task description>`

## When to use what

Routing heuristics the author has settled on after ~6 weeks of daily use:

| Task profile | Executor |
|---|---|
| Judgment, debugging, architecture, security, ambiguous scope | **Claude** (don't delegate) |
| Mechanical code, ~60+ lines, mirroring an existing file's style | `/dispatch codex` (default) |
| Input > ~150k tokens (summarize log, analyze whole repo, big PDF) | `/dispatch gemini` |
| Multi-modal input (images, screenshots, PDFs, video) | `/dispatch gemini` (Codex CLI is text-only) |
| 5+ similar mechanical sub-tasks in parallel | `/dispatch gemini` (Pro tier has more headroom than Codex Plus) |
| Any other registered CLI model | `/dispatch <model_id>` |
| Small edit (<30 lines) | **Claude direct** (dispatch overhead exceeds gain) |

Codex and Gemini have rough quality parity on code generation. The bottleneck is usually spec precision and your smoke-test discipline, not the model.

## Caveats

- **Multi-modal Gemini dispatches** must stage attachments inside the project directory (or `~/.gemini/tmp/<project>/`). Files outside those paths silently fail, and Gemini may hallucinate from the prompt description. Add `.gemini-tmp/` to your project's `.gitignore` if you go this route.
- **Rate-limit resets are rolling, not scheduled.** Claude Code's `resets_at` is an approximation; the statusline advances it by the window size if it's stale, so your countdown won't lie even when the source timestamp has drifted.
- **The budget-check heuristics** (~2M tokens per 5h, ~8k per small edit, etc.) are eyeballed — tune them for your own plan tier by editing `commands/budget-check.md`.

## License

MIT — see [LICENSE](./LICENSE).
