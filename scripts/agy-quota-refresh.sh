#!/bin/bash
# Antigravity (agy) quota refresher → ~/.claude/agy-quota.json
#
# agy's real quota is served by its LOCAL language server over ConnectRPC:
#   POST http://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary
# No auth header is needed on the plaintext port (the LS binds a pair: the
# lower port is HTTPS, the higher is plain HTTP — probe both, keep whichever
# returns JSON). The backend's own retrieveUserQuota/-Summary RPCs are NOT a
# substitute: with the CLI's plain OAuth token they return either
# PERMISSION_DENIED or a stub bucket list frozen at remainingFraction=1.
#
# Port discovery, cheapest first:
#   1. an agy process already listening (a live dispatch/TUI) → free read
#   2. otherwise boot `agy models`, which starts the LS for ~2s and exits —
#      it sends NO prompt, so it costs ZERO quota
#
# Output schema (percent USED, so it reads like the other statusline rows):
#   {fetched_at, source, groups:{gemini:{weekly:{used_percent,resets_at},
#    five_hour:{...}}, third_party:{...}}}
# Usage: agy-quota-refresh.sh [--no-boot]

OUT="$HOME/.claude/agy-quota.json"
ERR="$HOME/.claude/agy-quota.err"          # last failure reason (deleted on success)
AGY_BIN="${AGY_BIN:-$(command -v agy 2>/dev/null || printf '%s' "$HOME/.local/bin/agy")}"
RPC_PATH="/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
NO_BOOT=0
[ "$1" = "--no-boot" ] && NO_BOOT=1

# CSRF (agy 1.2.2, 2026-09-12): the LS now rejects every RPC without an
# `x-codeium-csrf-token` header ("missing CSRF token"), and the token is
# generated in-process — no discovery file, no env, no log line. But the CLI
# accepts a hidden TOP-LEVEL `--csrf_token <t>` flag (before any subcommand /
# -p) and the embedded LS then honours that value. So we mint one stable
# per-machine token, boot with it, and send it back. (A live dispatch's LS uses
# its own token, so while one runs this falls through to booting a second LS.) Verified 2026-09-12:
# our token + header -> full buckets JSON; env ANTIGRAVITY_CSRF_TOKEN is NOT
# honoured ("invalid CSRF token"); `agy models --csrf_token` (after the
# subcommand) is rejected — it must come first.
CSRF_FILE="$HOME/.claude/.agy-csrf-token"
if [ ! -s "$CSRF_FILE" ]; then
  (umask 077; uuidgen | tr 'A-Z' 'a-z' > "$CSRF_FILE") 2>/dev/null
fi
CSRF_TOKEN="$(head -c 128 "$CSRF_FILE" 2>/dev/null | tr -d '[:space:]')"

fail() { printf '%s %s\n' "$(date +%s)" "$*" > "$ERR" 2>/dev/null; exit 1; }

agy_listen_ports() {
  lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '/^agy/ {print $9}' | sed 's/.*://' | sort -u
}

# Echoes the quota JSON on success, nothing on failure. The LS binds a pair of
# ports (lower HTTPS, higher HTTP); probe both schemes on each so a swap in a
# future build can't blank the row again. LAST_BODY keeps the final rejection
# text for the .err file.
LAST_BODY=""
try_ports() {
  local p body scheme
  for p in $1; do
    for scheme in http https; do
      body=$(curl -sk -m 4 -X POST "$scheme://127.0.0.1:$p$RPC_PATH" \
        -H 'Content-Type: application/json' -H 'Connect-Protocol-Version: 1' \
        -H "x-codeium-csrf-token: $CSRF_TOKEN" \
        -d '{}' 2>/dev/null)
      case "$body" in
        *'"buckets"'*) printf '%s' "$body"; return 0 ;;
        "") ;;
        *) LAST_BODY="$scheme:$p $(printf '%s' "$body" | head -c 120)" ;;
      esac
    done
  done
  return 1
}

SOURCE="live-ls"
RAW=$(try_ports "$(agy_listen_ports)")

# Every open session's statusline can kick this when the cache goes stale, so
# guard the boot path with an atomic mkdir lock (stale locks >120s are reaped)
# to avoid N concurrent `agy models` spawns. A live-LS read needs no lock — it's
# a single cheap HTTP call.
LOCK="$HOME/.claude/.agy-quota.lock"
if [ -z "$RAW" ]; then
  if [ -d "$LOCK" ]; then
    lock_mtime=$(stat -f "%m" "$LOCK" 2>/dev/null)
    if [[ "$lock_mtime" =~ ^[0-9]+$ ]] && [ "$(( $(date +%s) - lock_mtime ))" -gt 120 ]; then
      rmdir "$LOCK" 2>/dev/null
    else
      exit 0   # another refresh is already booting the LS
    fi
  fi
  mkdir "$LOCK" 2>/dev/null || exit 0
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
fi

if [ -z "$RAW" ] && [ "$NO_BOOT" -eq 0 ] && [ -x "$AGY_BIN" ]; then
  SOURCE="booted"
  "$AGY_BIN" --csrf_token "$CSRF_TOKEN" models >/dev/null 2>&1 &
  BOOT_PID=$!
  for _ in $(seq 1 40); do
    RAW=$(try_ports "$(agy_listen_ports)")
    [ -n "$RAW" ] && break
    kill -0 "$BOOT_PID" 2>/dev/null || break
    perl -e 'select(undef,undef,undef,0.25)'
  done
  wait "$BOOT_PID" 2>/dev/null
fi

[ -z "$RAW" ] && fail "no quota JSON from LS (source=$SOURCE) last=${LAST_BODY:-no-response}"

printf '%s' "$RAW" | OUT="$OUT" SOURCE="$SOURCE" python3 -c '
import json, os, sys, time, calendar

def epoch(s):
    try:
        return calendar.timegm(time.strptime(s.split(".")[0].rstrip("Z"), "%Y-%m-%dT%H:%M:%S"))
    except Exception:
        return None

raw = json.load(sys.stdin)
groups = raw.get("response", {}).get("groups", [])
# Group 0 is the Gemini pool (what agy dispatches actually burn); the second is
# the separate third-party pool (Claude/GPT via Antigravity). Key off the
# bucketId prefix rather than list order.
out = {"fetched_at": int(time.time()), "source": os.environ["SOURCE"], "groups": {}}
for g in groups:
    for b in g.get("buckets", []):
        bid = b.get("bucketId", "")
        gkey = "gemini" if bid.startswith("gemini") else "third_party"
        wkey = {"weekly": "weekly", "5h": "five_hour"}.get(b.get("window", ""))
        if not wkey:
            continue
        frac = b.get("remainingFraction")
        if not isinstance(frac, (int, float)):
            continue
        out["groups"].setdefault(gkey, {})[wkey] = {
            "used_percent": round((1.0 - float(frac)) * 100, 1),
            "resets_at": epoch(b.get("resetTime", "")),
            "display_name": b.get("displayName", ""),
        }
if not out["groups"].get("gemini"):
    sys.exit(1)
tmp = os.environ["OUT"] + ".tmp"
with open(tmp, "w") as f:
    json.dump(out, f, indent=2)
os.replace(tmp, os.environ["OUT"])
' || fail "parse/write failed (source=$SOURCE)"

rm -f "$ERR" 2>/dev/null
exit 0
