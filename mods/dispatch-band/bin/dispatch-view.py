#!/usr/bin/env python3
"""dispatch-view.py — one JSON list of the external dispatches running right now (Codex, agy).

Feeds the `dispatch-band` Claude Code mod (above-prompt band). Source: the markers
dispatch-common.sh writes to ~/.claude/run-status/dispatch-running/*.json; a marker whose
pid is gone is skipped. Per row: executor, task, model, profile, elapsed seconds, seconds
since the log last grew, the launching session's name, and a one-line description of the
task from its spec (first "# " heading, else the first plain sentence).
Waiting jobs (2026-10-25): entries the usage forecast parked in ~/.claude/run-status/dispatch-queue
(state "waiting", owner pid alive) come back as rows with "waiting": true and "fits_at" (epoch it should start).
Usage: dispatch-view.py [--dir DIR] [--queue-dir DIR] [--now EPOCH]
"""
import argparse, glob, json, os, re, time

H = os.path.expanduser("~")


def describe(spec):
    try:
        with open(spec, errors="replace") as f:
            lines = [l.strip() for l in f.read(20000).splitlines()]
    except OSError:
        return ""
    for l in lines:
        if l.startswith("# ") and len(l) > 3:
            return clean(l[2:])
    for l in lines:
        if l and not l.startswith(("#", "-", "*", "|", "```", ">", "<")) and len(l) > 20:
            return clean(re.split(r"(?<=[.!?])\s", l, maxsplit=1)[0])
    return ""


def clean(s):
    s = re.sub(r"[`*]", "", s).strip()
    return s if len(s) <= 90 else s[:89] + "…"


def log_detail(path):
    """Stage + live action from the tail of a dispatch log (codex text or agy stream-json)."""
    out = {"stage": None, "of": None, "stage_name": "", "doing": "", "files": 0, "tests": "", "steps": 0}
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(max(0, size - 400000))
            text = f.read().decode("utf-8", "replace")
    except OSError:
        return out
    for m in re.finditer(r"PROGRESS (\d+)/(\d+) (?:start|done) ([\w-]+)", text):
        out["stage"], out["of"], out["stage_name"] = int(m.group(1)), int(m.group(2)), m.group(3).replace("-", " ")
    out["files"] = len(set(re.findall(r"^diff --git a/(\S+)", text, re.M)))
    p_ = re.findall(r"\u2139 pass (\d+)|(?<![\w-])(\d+) (?:passed|passing)\b", text); f_ = re.findall(r"\u2139 fail (\d+)|(?<![\w-])(\d+) failed\b", text)
    p_ = [a or b for a, b in p_]; f_ = [a or b for a, b in f_]
    if p_:
        out["tests"] = f"{p_[-1]} pass" + (f" · {f_[-1]} fail" if f_ and f_[-1] != "0" else "")
    if '"step_update"' in text:                                   # agy
        steps = re.findall(r'"step_index":(\d+)', text)
        out["steps"] = int(steps[-1]) if steps else 0
        for line in reversed(text.splitlines()):
            if '"tool_info"' not in line:
                continue
            try:
                su = json.loads(line)["step_update"]; ti = su.get("tool_info") or {}; par = ti.get("parameters") or {}
            except Exception:
                continue
            arg = par.get("CommandLine") or par.get("TargetFile") or par.get("AbsolutePath") or par.get("SearchPath") or par.get("Query") or ""
            verb = {"run_command": "$", "view_file": "read", "replace_file_content": "edit", "multi_replace_file_content": "edit",
                    "write_to_file": "write", "grep_search": "search", "list_dir": "ls", "read_url_content": "fetch"}.get(ti.get("name", ""), ti.get("name", ""))
            out["doing"] = clean(f"{verb} {str(arg).splitlines()[0] if arg else ''}".replace(H, "~"))
            break
    else:                                                         # codex
        out["steps"] = len(re.findall(r"^exec$", text, re.M))
        cmds = re.findall(r"^exec\n(.+)", text, re.M)
        if cmds:
            c = re.sub(r"^/bin/(?:zsh|bash) -lc ['\"]?", "", cmds[-1]); c = re.sub(r"['\"]? in /\S+$", "", c)
            out["doing"] = clean("$ " + c.replace(H, "~"))
    return out


def session_name(pid):
    try:
        return json.load(open(f"{H}/.claude/sessions/{int(pid)}.json")).get("name") or ""
    except Exception:
        return ""


def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except Exception:
        return False


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--dir", default=f"{H}/.claude/run-status/dispatch-running")
    a.add_argument("--queue-dir", default=f"{H}/.claude/run-status/dispatch-queue")
    a.add_argument("--now", type=float, default=None)
    a.add_argument("--session-pid", type=int, default=None, help="only dispatches launched by this Claude process")
    o = a.parse_args()
    o.dir = os.environ.get("DISPATCH_BAND_DIR") or o.dir   # review-page replays only (set in the capture session's env)
    now = o.now or time.time()
    rows = []
    for f in sorted(glob.glob(os.path.join(o.dir, "*.json"))):
        try:
            m = json.load(open(f))
        except Exception:
            continue
        if not alive(m.get("pid")):
            continue
        if o.session_pid and m.get("parent_pid") != o.session_pid and not os.environ.get("DISPATCH_BAND_DIR"):
            continue
        log = m.get("log") or ""
        quiet = int(now - os.path.getmtime(log)) if log and os.path.exists(log) else None
        prof = os.path.basename(m.get("profile") or "")
        rows.append({
            "executor": m.get("executor", "?"),
            "parent_pid": m.get("parent_pid"),
            "task": m.get("task", "?"),
            "model": m.get("model", ""),
            "profile": "work" if prof.endswith("-work") else ("" if prof in ("", ".codex") else prof),
            "elapsed": int(now - float(m.get("started") or now)),
            "quiet": quiet,
            "log_bytes": os.path.getsize(log) if log and os.path.exists(log) else 0,
            "session": m.get("session_name") or (session_name(m.get("parent_pid")) if m.get("parent_pid") else ""),
            "what": describe(m.get("spec") or ""),
            **(log_detail(log) if log else {}),
        })
    rows.sort(key=lambda r: -r["elapsed"])
    rows += waiting(o, now)
    print(json.dumps(rows))


WINDOW = {"codex_personal_5h": "codex", "codex_work_5h": "codex work", "agy_5h": "gemini", "agy_argon_weekly": "argon"}


def waiting(o, now):
    """Jobs the forecast is holding until their window has room (oldest first)."""
    out = []
    qdir = os.environ.get("DISPATCH_BAND_QUEUE_DIR") or o.queue_dir
    for f in glob.glob(os.path.join(qdir, "*.json")):
        try:
            q = json.load(open(f))
        except Exception:
            continue
        if q.get("state", "waiting") != "waiting" or not q.get("pid") or not alive(q["pid"]):
            continue
        if o.session_pid and q.get("parent_pid") != o.session_pid and not os.environ.get("DISPATCH_BAND_QUEUE_DIR"):
            continue
        out.append({
            "executor": "codex" if q.get("provider") == "codex" else "agy",
            "parent_pid": q.get("parent_pid"), "task": q.get("task") or "?", "model": "", "profile": "",
            "elapsed": int(now - float(q.get("created") or now)), "quiet": None, "log_bytes": 0, "session": "", "what": "",
            "waiting": True, "fits_at": q.get("fits_at"), "window": WINDOW.get(q.get("window"), q.get("window") or ""),
        })
    out.sort(key=lambda r: -r["elapsed"])
    return out


if __name__ == "__main__":
    main()
