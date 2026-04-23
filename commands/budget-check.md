---
description: Estimate whether a planned task list will fit in your current 5h token budget
argument-hint: <plan file path OR inline plan description>
---

Before executing a planned task list, estimate whether it will fit in the remaining 5h window. Report fits/tight/won't-fit with concrete options.

## Task
$ARGUMENTS

## Procedure

### 1. Read current session state

Read `~/.claude/.session-state.json` — the statusline writes this every ~10s. You want:
- `rate_limits.five_hour.used_percentage` — how much of the 5h window is used
- `rate_limits.five_hour.resets_at` — Unix epoch of next reset
- `cost.total_cost_usd` — informational

If the cache file is missing or >60s stale (compare `timestamp` field to current Unix epoch), tell the user and stop — don't proceed with stale data.

### 2. Determine what to estimate

- If `$ARGUMENTS` is an existing file path, read its contents.
- If `$ARGUMENTS` starts with `/` or `~` but the file doesn't exist, stop and ask the user to confirm the path.
- Otherwise treat the argument as an inline plan description.

### 3. Estimate plan token cost

Count discrete action steps (bullet points, numbered items, subheaders that imply an action). Classify each:

| Step shape | Cost |
|---|---|
| Small edit / single-file change / targeted tool call | ~8k tokens |
| Multi-file change / requires exploration before editing | ~20k tokens |
| Subagent dispatch or complex search/research | ~35k tokens |
| Bash command sequence / verification / smoke test | ~5k tokens |
| External dispatch to Codex/Gemini (Claude pays only for spec+smoke-test) | ~5k tokens |

Sum steps, then add **30% overhead** for turn-to-turn conversation and unexpected tool iterations.

### 4. Compute fit

- Assume the 5h window budget is **~2,000,000 tokens** (Opus Max approximation; tune later if needed).
- `plan_percent = round((estimate / 2_000_000) * 100)`
- `projected_total = current_used_percentage + plan_percent`

### 5. Report one of three verdicts

**Format:**

```
<✅/⚠️/❌> <verdict headline>
current 5h: X% · plan est: ~Yk tokens (Z%) · projected total: W%
```

- **✅ Fits comfortably** — projected total < 80%. Say "go ahead."
- **⚠️ Tight** — 80 ≤ projected < 100%. List 2–3 specific steps that could be dispatched to Codex/Gemini to cut Claude cost.
- **❌ Won't fit** — projected ≥ 100%. Offer three numbered options:
  1. **Split**: run the first N steps that fit, defer the rest
  2. **Wait**: reset is at `<local HH:MM from resets_at>` — suggest `/execute-at-reset <plan-path>`
  3. **Keep planning**: refine further; execute later

### 6. Length

Keep the whole report under 150 words. Be direct, no preamble. If the plan is inline (not a file), note at the top that estimates are rougher without a structured list to count against.
