---
description: Show every provider's budget health and who should take the next job
---

Run the cross-provider quota balancer and explain the result in plain English.

```bash
node ~/.claude/scripts/quota-balance.mjs
```

Then give Raza a short read-out — no jargon, no table repetition:

1. **Who's in trouble** — any provider in FLOOR BREACH or CONSERVE, and how long until it refills. A provider at 0% with days to go is the headline; say it first.
2. **What's about to be wasted** — any provider in SPEND state whose reset is within ~24h. That budget disappears unused. Name it and say how long is left to burn it.
3. **Where work should go right now** — the ROUTE TO line, translated: "mechanical work goes to X today, not Y."

Then, if he's about to start something substantial, say explicitly whether to fan out wide or stay narrow.

Keep the whole reply under ~8 lines. He wants the call, not the arithmetic.

**Reading the surplus number:** it's `% budget left − % of the window still to come`. Positive means he's underspending and will forfeit budget at reset; negative means he's outrunning the refill and will strand himself. Zero is perfectly on pace. That single number is the only thing being ranked.
