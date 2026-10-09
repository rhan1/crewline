# crewline

A drop-in Claude Code setup that gives you:

1. **A multi-row statusline** showing Claude context, rate-limits (5h + 7d with absolute reset clocks), cache savings, cost, plus dedicated rows for Codex and Gemini dispatch activity. Rate limits use **cross-session reconciliation** (every open session converges on one shared number instead of each showing its own stale snapshot); the Codex row shows **real Codex rate-limit windows** (fetched in the background from `codex app-server`, falling back to a dispatch-count estimate when unavailable); executor rows show a live **`running now`** badge while a dispatch or interactive TUI session is in flight; and a **`bg-claude`** indicator surfaces background `claude -p` jobs that are otherwise invisible to the 5h bar.
2. **Slash commands** that force-dispatch work to Codex or Gemini, budget-check a plan before committing to execution, schedule plans for the next rate-limit window, show a live view of native subagents (`/agents`), and hand a whole build off to a dedicated executor session in its own named terminal tab (`/handoff`). Dispatch wrappers snapshot the working tree around every call and report exactly which files the executor wrote (`[Mutation]` in the log, `mutated`/`mutation_action` in the JSON) — set `CODEX_EXPECT_READONLY=1` to have a nominally read-only run undo its own writes, which is refused if the tree was already dirty. They also carry a built-in **watchdog** (background 60s poll — kills and notifies on stalled or overtime runs, no GNU `timeout` needed) and record honest statuses (`timeout` / `stalled` / `empty` / `suspect`) with a `status_detail` field instead of trusting exit-code success.
3. **Hooks** that warn you before a heavy turn blows the 5h window, tell you when to *spend* surplus budget that would otherwise expire (and when to pull back), rotate dispatch logs weekly, and (optionally) log native-subagent lifecycle for the `/agents` monitor.

The core idea: keep Claude (Opus / Sonnet) on judgment, debugging, smoke-testing, and architecture. Delegate mechanical code generation and long-context / multi-modal work to Codex and Gemini — they're cheaper, sometimes faster, and each has a capability profile the other can't match.

## Example statusline

```
Opus 4.7 (1M context) | [████░░░░░░] 38% | [██░░░░░░░░] 5h:20% (4h 52m - 05:01) | [█████▉░░░░] 7d:59% (3d 13h - 13:09) | cache:82% (saved $4.21) | $31.32 | 2797m | @yourname
codex plus · gpt-5.4 | [█▋░░░░] 7d:27% (5d 21h - 16:49) | 42.1k toks (5h) | last: scraper-api · 6.2k toks · 2m ago · 47s
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
- **[Warp](https://warp.dev)** — only needed for `/handoff` / **Executor tabs**, which drive named Warp tabs via `~/.warp/tab_configs`. Nothing else in the repo touches it.

The statusline degrades gracefully — if `codex` or `gemini` isn't installed, those rows simply don't render.

**Platform:** Built on macOS (uses BSD `date -j` syntax and `stat -f "%m"`). Should work on Linux with `date -d` / `stat -c "%Y"` tweaks — PRs welcome.

## Install

Quickest path:

```bash
git clone https://github.com/rhan1/crewline.git
cd crewline
./install.sh
```

The installer:
1. Prompts once per optional component — accept the default (Y) to match the author's setup, or decline to skip. Pass `--all` to skip prompts and install everything, or `--minimal` to install only the statusline.
2. Backs up any existing `~/.claude/statusline.sh`, `~/.claude/scripts/`, `~/.claude/commands/`, and `~/.claude/hooks/` targets to `~/.claude/backups/pre-install-<ts>/`
3. Symlinks this repo's files into `~/.claude/` (so `git pull` upgrades everything)
4. Prints the settings.json snippet for only the components you installed (one complete JSON object between `BEGIN`/`END crewline settings snippet` lines)

**Non-interactive install** (scripts, CI): `CREWLINE_COMPONENTS="0,1,4,8" ./install.sh --copy` installs exactly the listed component indexes, skips every prompt (including the model wizard), and still prints the snippet. Indexes: 0 Codex dispatch, 1 Gemini dispatch, 2 budget check, 3 execute-at-reset, 4 RuFlo, 5 log rotation, 6 `/agents` monitor, 7 burn-rate advisor, 8 cross-provider routing, 9 executor tabs.

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

### Upgrading from an earlier install

Earlier versions shipped an advisory `agy-router.js` hook that only *suggested* Antigravity. Routing is now enforced (see **How a subagent call is routed**). To upgrade:

1. `git pull` in your crewline clone.
2. `./install.sh` and re-select your components (say yes to "Cross-provider routing" and "Gemini dispatch").
3. In `~/.claude/settings.json`, delete the `PreToolUse` entry running `node ~/.claude/hooks/agy-router.js` and the old `~/.claude/hooks/agy-router.js` file.
4. In the same file, replace the `Agent` `PreToolUse` entry running `ruflo-model-enforcer.js` with `node ~/.claude/hooks/route-chain.js`, add `node ~/.claude/hooks/agy-worker-audit.js` under `SubagentStop`, and add `"env": {"ROUTE_ENFORCE": "1"}`.
5. Restart Claude Code.
6. Run `/balance` and confirm every provider row is present (Claude 5h/7d, Codex, Codex weekly, agy 5h/weekly) and none is listed under `STALE`.

## Slash commands

Once installed and the settings.json snippet is merged, these are available via the Claude Code skill picker or by typing `/<name>`:

| Command | When to use |
|---|---|
| `/dispatch <model_id> <task>` | Dispatch to any model in the registry — e.g. `/dispatch codex <task>`, `/dispatch qwen <task>` |
| `/dispatch-codex <task>` | Shortcut for `/dispatch codex` — Codex for mechanical code gen, CRUD scaffolds, pattern-following |
| `/dispatch-gemini <task>` | Shortcut for `/dispatch gemini` — Gemini for long-context (>150k tokens), multi-modal, parallel-batch |
| `/budget-check <plan>` | Pre-flight: does this plan fit in the remaining 5h window? Returns ✅ / ⚠️ / ❌ with concrete options |
| `/execute-at-reset <plan>` | Schedule a plan to auto-execute ~1 min after the next 5h reset (via Claude Code's `CronCreate`) |
| `/burn` | Burn-rate posture: is there surplus 5h budget that will expire unused, or should you conserve? Reports SPRINT / SPEND / NORMAL / CONSERVE / CRITICAL |
| `/agents` | Live view of native Claude subagents (Agent/Task tool) — running vs done, each one's task, duration, and a completion count. Reads the subagent transcripts Claude Code maintains, so it works across sessions and even when rate-limited |
| `/balance` | Cross-provider budget health: scores Claude / Codex / Gemini together and says who should take the next job. See **Cross-provider balancing** below |
| `/handoff <slug> <task>` | Hand a task to a dedicated executor session in its own named Warp tab, keeping the current session free to plan and review. See **Executor tabs** below |

## Hooks

| Hook | Event | What it does |
|---|---|---|
| `burn-rate-advisor.js` | `UserPromptSubmit` + `PreToolUse (Agent\|Workflow)` | Grades **budget left vs clock left** (`surplus = budget_left% − clock_left%`). 5h budget does not roll over, so when the window is about to reset with a lot unspent it says **SPRINT** — fan out to maximum useful width, breadth over depth, push mechanical work to external CLI executors. When burning faster than the clock it says **CONSERVE**/**CRITICAL** — sequential, cheapest tier, checkpoint and chain to the next window. **Silent when on pace**, and silent at the fan-out decision point unless the posture is actionable. A high 7d reading tempers or cancels a sprint, since the weekly window does not refill. |
| `auto-budget-check.js` | `UserPromptSubmit` | Scans each prompt for execution-intent keywords (execute, implement, deploy, refactor…). If matched AND 5h usage ≥40%, injects a `[auto-budget]` advisory into the context so Claude sees it before starting. Escalates to 🚨 at ≥80%. |
| `weekly-maintenance.js` | `SessionStart` | Once per 7 days, rotates dispatch logs older than 30 days and refreshes the Gemini model cache. Runs in background (`child.unref()`) so session startup is never blocked. |
| `ruflo-model-enforcer.js` | `PreToolUse` (Agent), or via `route-chain.js` | Optional. See below. |
| `route-chain.js` | `PreToolUse` (Agent) | Installed with cross-provider routing. The ONE rewriting `Agent` hook: runs `route-resolver.js`, and if that doesn't send the call to Antigravity, runs `ruflo-model-enforcer.js` (when installed) for the Claude tier. Claude Code runs PreToolUse hooks in parallel and keeps only one `updatedInput`, so the two must not be separate entries. |
| `route-resolver.js` | called by `route-chain.js` | Decides Claude vs Antigravity for each subagent call: capability blockers first, then live capacity from `/balance`. Rewrites the call to `agy-worker` when `ROUTE_ENFORCE=1`. See **How a subagent call is routed** below. |
| `agy-worker-audit.js` | `SubagentStop` | When an `agy-worker` stops, checks that it really ran `gemini-dispatch.sh` (transcript + a fresh `gemini-*.log`). Otherwise it posts a `VIOLATION` line: the work ran on Claude tokens. |

## Cross-provider balancing

RuFlo answers "which Claude tier?" These two answer the question one level up: **which provider should do this at all?**

### `/balance` and `scripts/quota-balance.mjs`

Reads every provider's quota cache in one place — Claude 5h + 7d, Codex 5h + weekly, Gemini/agy 5h + weekly — and scores each on a single signed number:

```
surplus = (% budget left) − (% of window still to come)
```

Positive means you are underspending and that budget expires unused at reset. Negative means you are outrunning the refill and will strand yourself mid-week.

Two rules fall out of it, and both exist because of a real failure: one provider hit **100% used with 4.6 days left to reset** while another sat at 0.3% used the entire time.

- **Floor rule** — never drain a provider below ~15% while more than ~40% of its window remains. Flags `⚠ FLOOR`.
- **Use it or lose it** — a provider in `SPEND` state whose reset is under 24h away should be leaned on hard, not conserved. Applies per provider, not just to the 5h window.

Capability still decides who *can* do a job (no browser driving on agy, no VPN-gated DB from a sandboxed executor). Among those that can, surplus decides who *should*.

### How a subagent call is routed

Unconditional rules like "mechanical work goes to executor X" are what drain a single provider dry. Every `Agent` call goes through `route-chain.js`, which applies this ladder in order:

1. **Capability blockers → Claude.** Browser driving, DB/VPN/credential work, MCP tools, security review, anything interactive, and an explicit `model:` on a judgment task (review, verify, audit, plan, adversarial…) stay on Claude. A negated mention ("no browser needed") is not a blocker.
2. **agy-eligibility.** The task must hit at least one fitness signal (exploration/file-reading, mechanical code, batch, long-context read) AND the prompt must be ≥ 200 chars. Otherwise it stays on Claude.
3. **Capacity from `/balance`.** agy weekly or 5h in floor breach or `EXHAUSTED` → Claude. Claude 7d in `SPEND` with surplus ≥ agy weekly surplus + 20, and agy weekly not `SPEND`/`SPRINT`/`IDLE` → Claude (use-or-lose). Otherwise → `agy-worker`.
4. **Enforcement.** With `ROUTE_ENFORCE=1` the call is rewritten to `subagent_type: "agy-worker"`. Unset, the hook only adds a one-line `[route] …` advisory.
5. **Claude tier.** Whatever stays on Claude goes to RuFlo (`ruflo-model-enforcer.js`), which picks haiku/sonnet/opus.
6. **Audit.** `agy-worker-audit.js` flags an `agy-worker` that did the work itself on Claude tokens instead of dispatching.

`agents/agy-worker.md` is a thin dispatcher subagent pinned to `model: haiku` with only the Bash tool. It writes the spec, runs `gemini-dispatch.sh` in the foreground, and **verifies the deliverable exists and parses before reporting success.** Antigravity has a documented failure mode where it returns a detailed, confident success narrative for a file it never wrote, so "it said it worked" is not evidence.

**Kill switches.** `ROUTE_RESOLVER_OFF=1` disables the resolver entirely (route-chain then only runs RuFlo). Removing `ROUTE_ENFORCE` keeps routing advisory. `AGY_ROUTER_OFF` no longer exists: the old `agy-router.js` hook is gone, so delete it if an earlier install left it behind (see **Upgrading from an earlier install**).

**Decision log.** Every routing decision is appended to `~/.claude/route-decisions.jsonl` (hits, blocker, capacity snapshot, decision, reason, enforced). Audit results go to `~/.claude/route-violations.jsonl`.

**What `/balance` reads, and who writes it:**

| Cache | Written by |
|---|---|
| `~/.claude/.session-state.json` (Claude 5h + 7d) | `statusline.sh`, every render |
| `~/.claude/codex-rate-limits.json` (Codex 5h + weekly) | `scripts/codex-rate-limits-refresh.mjs`, kicked by `statusline.sh` when stale |
| `~/.claude/agy-quota.json` (agy 5h + weekly) | `scripts/agy-quota-refresh.sh`, kicked by `statusline.sh` when stale (installed with cross-provider routing) |
| `~/.claude/ollama-quota.json` (optional) | nothing in this repo. Ollama Cloud rows only render if you supply your own refresher. |

**Stale and IDLE.** A cache older than 6h, or a window whose reset time has already passed, is dropped from the table and listed under `STALE` (`stale` in `--json`). Consumers treat a missing row as unknown, not as live data. agy and Codex windows are anchored on first use, so an untouched window reads as `IDLE`: surplus = left% − floor (≈ +85), and it never loses the use-or-lose tie-break. Codex shows two rows, `Codex` (5h) and `Codex weekly`.

**Wrapper floor gate.** `codex-dispatch.sh` and `gemini-dispatch.sh` call `dc_quota_gate` before building a prompt or writing any status file. A fresh `/balance` reading of `EXHAUSTED` or floor breach for that provider refuses the dispatch with exit code `3`. Missing, stale or unparseable quota data fails **open** (the dispatch proceeds). `DISPATCH_FORCE=1` overrides.

**Reserved Codex tiers.** `CODEX_TIER=max` / `algo` (GPT-6 Astra) are for architect-level planning/review and need `CODEX_ALLOW_RESERVED=1`; without it the wrapper exits `2`. `CODEX_SERVICE_TIER` accepts only `default` (`flex` is dead server-side, `priority` costs extra without buying quota).

**Dispatch threshold.** The common ">60 lines" heuristic assumes you are trading one paid quota for another. When the target provider's quota is effectively free, the only cost is spec-writing plus verification, so the threshold drops: dispatch when **the spec is shorter than the work** — roughly 30+ lines of output, 3+ files to read, or any repeated/batch task. Exploration almost always qualifies, since one sentence of spec buys a large pile of reading.

### Codex tiers (`scripts/codex-dispatch.sh`)

Every Codex dispatch is routed to a tier instead of inheriting the global `~/.codex/config.toml` model. The table is the single source of truth in `scripts/dispatch-common.sh` (`dc_codex_tier_targets`):

| Tier | Model | Effort | Picked when |
|---|---|---|---|
| `lite` | `gpt-6-luna` | low | classifier complexity < 20% — renames, typos, boilerplate |
| `std` | `gpt-5.6-terra` | high | 20–42% — most mechanical code (no GPT-6 Terra exists yet) |
| `high` | `gpt-6-sol` | high | ≥ 42% — hard mechanical builds; the auto-route ceiling |
| `max` | `gpt-6-astra` | high | `CODEX_TIER=max` + `CODEX_ALLOW_RESERVED=1` only — audits, planning review |
| `algo` | `gpt-6-astra` | ultra | `CODEX_TIER=algo` + `CODEX_ALLOW_RESERVED=1` only — genuinely algorithmic specs |

Auto-classification uses the `ruflo` CLI's complexity score when it is on PATH; without it every dispatch lands on `std` (never `max`, so a missing classifier cannot silently restore full-price dispatching). `CODEX_ROUTER=off` inherits `config.toml`; `CODEX_MODEL` / `CODEX_EFFORT` override single knobs (`CODEX_SERVICE_TIER` accepts only `default`). The tier, route source and service tier are written to `codex-last.json` and echoed as a `[CodexRoute]` line at the top of every dispatch log.

Service tier is always `default`: OpenAI removed `flex` on 2026-09-29 (every model now returns `400 Unsupported service_tier: flex`), and `priority` buys latency, not quota.

### Model and effort selection

`gemini-dispatch.sh` accepts `AGY_MODEL` and `AGY_EFFORT` (`low|medium|high`, default `high`). Run the strongest tier when the quota is idle — down-tiering a budget you never exhaust saves nothing and only costs quality.

One sharp edge: `--effort` is **rejected** for models with built-in thinking (e.g. `claude-opus-4-6-thinking`). Passing it kills the dispatch in ~5s with no output, which is indistinguishable from a silent no-op. The wrapper suppresses `--effort` for `claude-*` and `gpt-*` models for exactly that reason.

`agy models` lists what your account can reach. Notably it may include Claude-family models — Claude-quality output billed to the Gemini pool.

### Picking a model: measure, don't assume

A worked example, because the intuitive answer was wrong twice.

A first pass had Gemini 3.7 fail one task where 3.6 passed, which looked like a clear regression. It wasn't reproducible. A powered rerun — 6 trials x 4 tasks x both models, 48 cells — put both at **24/24 correct and 168/180 (93%) on beyond-spec robustness stress cases**, statistically indistinguishable. The single failure never recurred across 30 further attempts.

Two methodology rules came out of it:

1. **n=1 is not a verdict.** Run at least 3 trials before recording any model comparison.
2. **Give the incumbent equal attempts.** The challenger had been run 4x and the incumbent once, so "the incumbent is perfect" was equally unsupported.

And a third, about the instrument itself: measure quality separately from correctness. A pass/fail grader scores a solution that scrapes through a 5s gate identically to one finishing in 0.2s, and scores one that happens to survive the specified cases identically to one that also handles input nobody mentioned. `quality_probe.py` adds perf headroom, beyond-spec robustness, and structural craft signals for exactly that reason.

### RuFlo (model routing)

`hooks/ruflo-model-enforcer.js` fires on every `Agent` tool call and rewrites the `model` parameter to the cheapest tier that fits the task. It uses keyword heuristics — no external CLI, no network calls, no LLM inference. It is a single Node.js file with no dependencies. With cross-provider routing installed it is called by `route-chain.js` instead of being wired directly.

**How it works:** the hook scores the agent's `description` field against three keyword lists (haiku / sonnet / opus). Longer descriptions get a small complexity boost toward opus. When the winning tier beats a 0.5 confidence threshold, the hook either confirms the chosen model (AGREE) or swaps it (REWRITE). Below threshold it passes through without touching anything.

**Never rewritten:** an agent whose definition pins a model (`model:` in `~/.claude/agents/<type>.md` frontmatter, e.g. `agy-worker` → haiku) when the call names no model; and a call that names a model explicitly on a judgment task (review, verify, audit, plan, adversarial — same regex as `route-resolver.js`).

**Fable fallback:** when the hook has no verdict and the call names no model, the subagent would inherit the parent session's tier. If the statusline's `~/.claude/.session-state.json` says the session runs a Fable-tier model, the call is routed to `FABLE_INHERIT_FALLBACK` (default `opus`) instead.

**Writes:** `~/.claude/hooks/ruflo-last-route.txt` — a one-line record of the last routing decision, consumed by the statusline. `~/.claude/hooks/ruflo-enforcer.log` — append-only log of every firing.

**Tuning:** the keyword lists are at the top of `hooks/ruflo-model-enforcer.js` in a `KEYWORDS` object. Add or remove terms to match your own usage patterns. The length thresholds (200 / 400 chars) are also in the same block.

The installer prompts before installing this hook. To add it later, copy or symlink `hooks/ruflo-model-enforcer.js` to `~/.claude/hooks/` and add the `PreToolUse` block from `examples/settings.json`.

## Executor tabs (manager→executor lane)

Everything above routes *work*. This routes *sessions*.

A session that is executing cannot also be thinking about what comes next, so
past a certain size the session you're typing in is the wrong place to run the
build. `/handoff` splits the two: the session you're in becomes the **manager**
(planning, review, steering), and the build runs in a dedicated **executor**
session in its own named Warp tab.

```bash
~/.claude/scripts/spawn-executor.sh <task-slug> [spec-file] [cwd] [model]
```

The script pre-seeds workspace trust for the cwd (so the executor never sits
blocked on the "Do you trust this folder?" dialog), writes a Warp tab config,
and opens a tab named after the slug. Claude engines boot with `/color purple`
so a purple prompt bar plus a purple tab reads at a glance as "agent session,
not a human typing." Model is a positional argument, not a constant —
`opus`, `opus[1m]`, `sonnet`, `haiku`, or `codex` / `agy` to run those CLIs
instead of Claude (optional; they must be on `$PATH`, and their tabs stay open
after exit so you can read the output). Defaults come from `EXECUTOR_MODEL` and
`EXECUTOR_EFFORT`.

Two details are what make the lane actually usable rather than a way to lose
track of work:

- **The spec is the whole game.** The executor starts with zero conversation
  context, so `~/.claude/handoffs/<slug>.md` has to carry the goal, the file
  paths, the constraints, and the verification steps. A vague spec buys you a
  confident wrong answer in a tab you weren't watching.
- **A report-back contract, every time.** The executor's final step is writing
  `~/.claude/handoffs/<slug>.report.md` with DONE / NOT DONE / FILES CHANGED /
  VERIFIED sections. Then the manager **spot-verifies the deliverable itself** —
  "it finished" and "it worked" are different claims, and only one of them is
  checkable. Claude tabs are kicked off and steered over `SendMessage` with
  `notify_when_idle`; `codex` / `agy` tabs take the spec at boot and can't be
  steered, so you watch their log and their report file instead.

Note this lane is **not** covered by RuFlo, which only sees `Agent` tool calls —
the model choice here is made explicitly at spawn time. And executor tabs are
session-bound: closing the tab or rebooting kills the run. A tab is a window
into a run, not a guarantee that it survives one.

Use it at the plan→execute boundary, for anything running longer than ~15–20
minutes, or for a second concurrent workstream. Don't use it for planning,
review, or small delegations — a subagent already handles those more cheaply.

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
| Substantial build (>15–20 min), or a second parallel workstream | `/handoff` — executor tab, manager session stays free |

Codex and Gemini have rough quality parity on code generation. The bottleneck is usually spec precision and your smoke-test discipline, not the model.

## Caveats

- **Multi-modal Gemini dispatches** must stage attachments inside the project directory (or `~/.gemini/tmp/<project>/`). Files outside those paths silently fail, and Gemini may hallucinate from the prompt description. Add `.gemini-tmp/` to your project's `.gitignore` if you go this route.
- **Rate-limit resets are rolling, not scheduled.** Claude Code's `resets_at` is an approximation; the statusline advances it by the window size if it's stale, so your countdown won't lie even when the source timestamp has drifted.
- **The budget-check heuristics** (~2M tokens per 5h, ~8k per small edit, etc.) are eyeballed — tune them for your own plan tier by editing `commands/budget-check.md`.

## License

MIT — see [LICENSE](./LICENSE).
