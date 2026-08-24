---
description: Spawn an executor session in a new named Warp tab and hand it a self-contained spec
argument-hint: "<task-slug> [what to build]"
---

Hand the given task to a dedicated **executor** session running in its own named
Warp tab, so this (**manager**) session stays free for planning, review and
orchestration instead of being blocked for the length of the build.

The split matters because a session that is executing cannot also be thinking
about what comes next. One tab per workstream; the manager watches them.

## Protocol

1. **Write the spec** to `~/.claude/handoffs/<task-slug>.md`.

   The executor starts with **zero conversation context** — everything it needs
   must be in the file. Include: the goal, success criteria, the exact file
   paths involved, constraints (project conventions, `CLAUDE.md` rules, things
   it must not touch), and the verification steps that prove it worked.
   Spec quality is the whole game; a vague spec produces a confident wrong
   answer in a tab you weren't watching.

2. **Spawn the tab:**

   ```bash
   ~/.claude/scripts/spawn-executor.sh <task-slug> [spec-file] [cwd] [model]
   ```

   Defaults: spec `~/.claude/handoffs/<slug>.md`, cwd `$HOME`, model `opus`
   (override the default with `EXECUTOR_MODEL`).

   The script pre-seeds workspace trust for the cwd so the session never blocks
   on the "Do you trust this folder?" dialog, writes a Warp tab config, and
   opens a tab named `<task-slug>`. Claude engines boot with `/color purple` as
   their first input — a purple prompt bar plus a purple tab is the visual
   convention for "this is an agent session, not me typing."

   **Pick the model per task, don't hardcode one.** Judgment-heavy or
   architectural execution → `opus` (or `opus[1m]` for a large context).
   Mechanical / batch / data work → a cheaper tier, or an external CLI engine.
   Whichever provider has budget to spare should take the work when more than
   one is capable of it — see **Cross-provider balancing** in the README.

   Note that this lane is *not* covered by the RuFlo model-routing hook, which
   only sees `Agent` tool calls. Here the manager applies the routing decision
   directly.

   **Optional engines.** Passing `codex` or `agy` as the model runs those CLIs
   instead of Claude, and requires them on `$PATH` (see Prerequisites in the
   README). Their tabs stay open after the run so you can inspect the output.

3. **Kick off — Claude engines only.** A Claude tab boots interactive and idle;
   it needs a kickoff message.

   Wait for the process, then send it:

   ```bash
   until pgrep -f "[-]n <slug>" >/dev/null; do sleep 2; done; sleep 10
   ```

   Then `SendMessage` to the session name: *"Read `<spec path>` and execute it
   fully"* — with `notify_when_idle: true` **in the same call**, so completion
   arrives as an event. Never poll with "are you done yet?".

   `codex` / `agy` tabs receive the spec at boot and **cannot** be steered by
   `SendMessage`. Babysit those by watching their log instead, and liveness-check
   them early — a silent external CLI can hang for hours, and an empty-but-
   "successful" run is indistinguishable from a real one unless you check the
   deliverable.

4. **Steer mid-flight** with `SendMessage` to the session name (Claude engines).
   Executors are told the manager may steer them.

5. **Report-back contract — every handoff, every engine.** The kickoff message
   (Claude) or the spec itself (codex/agy) must require, as the executor's
   **final** step, writing `~/.claude/handoffs/<slug>.report.md`:

   ```
   # <slug> — completion report
   ## DONE — each completed item, one line each, with evidence (file path, test output, URL)
   ## NOT DONE — anything skipped or blocked, and WHY (empty section if none)
   ## FILES CHANGED — every file created / modified / deleted
   ## VERIFIED — the commands actually run to prove it works
   ```

   Without this, "it finished" is the only signal you get, and that is not the
   same as "it worked."

6. **On the idle notice (Claude) or the report file appearing (codex/agy):**
   read the report, then **spot-verify the deliverables yourself** — verify the
   system, not the report. Then update the task list and any project notes, and
   brief the user. If the report lists NOT-DONE items, decide: steer the
   executor to finish, respawn it with a sharper spec, or surface the blocker.

   Keep writes to shared project state in the manager. Parallel executors
   editing the same notes file is a merge conflict waiting to happen.

## Triggers — spawn without being asked when any of these hit

1. **Plan→execute boundary:** planning is done and the build is substantial
   (≥5 steps, ≥3 files, any fan-out, or a large fraction of the rate-limit
   window).
2. **Continuous execution estimated at more than ~15–20 minutes.**
3. **A second concurrent workstream** while one is already executing — one tab
   per stream.
4. **An external CLI job with a lifecycle worth watching:** builds, batch runs,
   scrapes.
5. The user says "spin it up" / "hand it off" / "new tab" / `/handoff`.

## When not to use

- **Planning, judgment, review, quick questions** — those stay in the manager
  session.
- **Small delegations.** A subagent (`Agent` tool) already runs those, gets
  model-routed automatically, and is cheaper to orchestrate than a whole tab.
- **Mechanical or batch work that has a dispatch path.** `/dispatch-codex`,
  `/dispatch-gemini` and `/dispatch <model>` are the cheaper route; a tab is for
  work with a lifecycle you want to watch and steer.

## Durability warning

Executor tabs are **session-bound**. Closing the tab, quitting Warp, or
rebooting kills the run — a tab does not make work durable. Anything unattended
and long-running (overnight chains, multi-hour pipelines) needs an external
supervisor that owns the process, plus a heartbeat and a deadline. A tab is a
window into a run, not a guarantee that it survives.
