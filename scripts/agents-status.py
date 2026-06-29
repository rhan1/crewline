#!/usr/bin/env python3
"""
agents-status.py — live view of native Claude Code subagents (Agent/Task tool).

Source of truth: subagent transcripts that Claude Code writes at
    ~/.claude/projects/<project>/<sessionId>/subagents/agent-<id>.jsonl
A transcript is appended to while its agent runs, so file mtime age is a
liveness proxy: recent write => still running; quiet => finished.

No hooks required — this reads files Claude Code maintains itself, so it works
across ALL sessions (including ones you launched from another window) and even
when a session is fully rate-limited.

Usage:
    agents-status.py [--run-window SECS] [--lookback MINS] [--no-color] [--json]
Defaults: --run-window 90, --lookback 720 (12h)
"""
import os, sys, json, glob, time, argparse, datetime

HOME = os.path.expanduser("~")
PROJECTS = os.path.join(HOME, ".claude", "projects")


def supports_color(force_off):
    if force_off:
        return False
    return sys.stdout.isatty()


def parse_args():
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("--run-window", type=int, default=90,
                   help="mtime within N secs => classified running (default 90)")
    p.add_argument("--lookback", type=int, default=720,
                   help="only show agents active within last N mins (default 720 = 12h)")
    p.add_argument("--no-color", action="store_true")
    p.add_argument("--json", action="store_true", help="emit raw JSON instead of a table")
    return p.parse_args()


def short_id(aid):
    if not aid:
        return "?"
    return (aid[:6] + "…" + aid[-3:]) if len(aid) > 10 else aid


def ago(secs):
    secs = int(max(0, secs))
    if secs < 60:
        return f"{secs}s"
    if secs < 3600:
        return f"{secs // 60}m"
    if secs < 86400:
        return f"{secs // 3600}h {(secs % 3600) // 60}m"
    return f"{secs // 86400}d {(secs % 86400) // 3600}h"


def first_line(path):
    try:
        with open(path, "r", errors="replace") as f:
            return f.readline()
    except Exception:
        return ""


def extract_task(rec):
    """Pull a short task description from the first transcript record."""
    try:
        msg = rec.get("message", {})
        content = msg.get("content", "")
        if isinstance(content, list):
            parts = []
            for b in content:
                if isinstance(b, dict) and b.get("type") == "text":
                    parts.append(b.get("text", ""))
                elif isinstance(b, str):
                    parts.append(b)
            content = " ".join(parts)
        content = " ".join(str(content).split())
        return content
    except Exception:
        return ""


def iso_to_epoch(s):
    if not s:
        return None
    try:
        s = s.replace("Z", "+00:00")
        return datetime.datetime.fromisoformat(s).timestamp()
    except Exception:
        return None


def collect():
    now = time.time()
    agents = []
    pattern = os.path.join(PROJECTS, "*", "*", "subagents", "agent-*.jsonl")
    for path in glob.glob(pattern):
        try:
            st = os.stat(path)
        except OSError:
            continue
        agents.append((path, st))
    return now, agents


def main():
    args = parse_args()
    color = supports_color(args.no_color)
    now, raw = collect()

    C = {
        "dim": "\033[2m", "reset": "\033[0m", "bold": "\033[1m",
        "grn": "\033[38;2;80;220;120m", "yel": "\033[38;2;240;200;80m",
        "red": "\033[38;2;230;90;90m", "cyan": "\033[38;2;100;210;230m",
        "gray": "\033[38;2;130;140;150m",
    }
    if not color:
        C = {k: "" for k in C}

    rows = []
    for path, st in raw:
        age = now - st.st_mtime
        if age > args.lookback * 60:
            continue
        line = first_line(path)
        rec = {}
        if line:
            try:
                rec = json.loads(line)
            except Exception:
                rec = {}
        aid = rec.get("agentId") or os.path.basename(path)[len("agent-"):-len(".jsonl")]
        # `slug` is Claude Code's auto-generated friendly handle (e.g.
        # "graceful-skipping-galaxy"), NOT the agent type. Use as a handle only.
        slug = rec.get("slug") or ""
        start = iso_to_epoch(rec.get("timestamp")) or st.st_ctime
        cwd = rec.get("cwd", "")
        cwd_short = os.path.basename(cwd.rstrip("/")) if cwd else ""
        session = os.path.basename(os.path.dirname(os.path.dirname(path)))
        task = extract_task(rec)
        running = age <= args.run_window
        rows.append({
            "id": aid, "slug": slug, "start": start, "last": st.st_mtime,
            "age": age, "dur": st.st_mtime - start, "running": running,
            "cwd": cwd_short, "session": session, "task": task,
        })

    rows.sort(key=lambda r: r["last"], reverse=True)
    running = [r for r in rows if r["running"]]
    done = [r for r in rows if not r["running"]]

    if args.json:
        print(json.dumps({"now": now, "running": running, "done": done}, default=str))
        return

    def fmt_row(r, mark, mark_color):
        handle = f"{C['bold']}{r['slug']}{C['reset']}  " if r["slug"] else ""
        head = (f"  {mark_color}{mark}{C['reset']} "
                f"{C['cyan']}{short_id(r['id']):<11}{C['reset']} "
                f"{handle}"
                f"{C['gray']}ran {ago(r['dur'])} · last write {ago(r['age'])} ago"
                f"{('  ·  ' + r['cwd']) if r['cwd'] else ''}{C['reset']}")
        task = r["task"][:96] + ("…" if len(r["task"]) > 96 else "")
        return head + (f"\n      {C['dim']}{task}{C['reset']}" if task else "")

    print(f"{C['bold']}NATIVE CLAUDE SUBAGENTS{C['reset']} "
          f"{C['gray']}· scanned {PROJECTS}/*/*/subagents "
          f"· {datetime.datetime.now().strftime('%H:%M:%S')}{C['reset']}")
    print()

    if running:
        print(f"{C['grn']}{C['bold']}RUNNING{C['reset']} "
              f"{C['gray']}(last write < {args.run_window}s){C['reset']}")
        for r in running:
            print(fmt_row(r, "⟳", C["grn"]))
        print()
    else:
        print(f"{C['gray']}RUNNING — none active in the last {args.run_window}s{C['reset']}")
        print()

    if done:
        print(f"{C['yel']}{C['bold']}DONE / IDLE{C['reset']} "
              f"{C['gray']}(active within {args.lookback // 60}h, newest first){C['reset']}")
        for r in done[:15]:
            print(fmt_row(r, "✓", C["yel"]))
        if len(done) > 15:
            print(f"  {C['gray']}… +{len(done) - 15} more{C['reset']}")
        print()

    total = len(running) + len(done)
    pct = (len(done) / total * 100) if total else 0
    print(f"{C['gray']}running {C['grn']}{len(running)}{C['gray']} · "
          f"done {C['yel']}{len(done)}{C['gray']} · "
          f"{pct:.0f}% of recent ({args.lookback // 60}h) complete{C['reset']}")
    if total == 0:
        print(f"{C['dim']}No subagents found. They appear here once an Agent/Task tool runs.{C['reset']}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"agents-status: {e}", file=sys.stderr)
        sys.exit(0)
