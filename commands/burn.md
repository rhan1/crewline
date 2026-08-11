---
description: Show the current 5h burn-rate posture — is there surplus budget to spend before reset, or should we conserve?
---

Run this and report the result verbatim, then add one line of interpretation:

```bash
node $HOME/.claude/hooks/burn-rate-advisor.js --report
```

Interpretation guide:

- **SPRINT** — the window resets soon and a large share of the budget is still
  unspent. That budget is forfeited at reset, so spend it: fan out to the widest
  useful set of parallel workers now (multiple Agent calls in ONE message so they
  run concurrently, or a Workflow), route mechanical work to your external CLI
  executors (Codex/Gemini) so it costs no Claude budget, and prefer breadth over
  depth. Work still running at reset continues into a fresh window.
- **SPEND** — ahead of pace. Parallelize freely; don't serialize what could fan out.
- **NORMAL** — on pace. No change in posture.
- **CONSERVE** — burning faster than the clock. Sequential work, 2–3 workers max
  on the cheapest sufficient tier, checkpoint for resume.
- **CRITICAL** — near the wall. Finish and checkpoint the current item, no new
  fan-outs, chain the rest to the next window (`/execute-at-reset`).

If a 7d note is attached, it wins: the weekly window does not refill today, so a
5h surplus is not free when 7d is high.

If the report says the signal is stale, the statusline hasn't rendered recently —
trust the live statusline numbers instead.
