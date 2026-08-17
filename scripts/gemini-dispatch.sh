#!/usr/bin/env bash
# Dispatch a task spec to Gemini CLI, capture elapsed/status, update status
# artifacts consumed by the Claude Code statusline.
#
# Usage: gemini-dispatch.sh <spec-file> [task-name]
#
# Spec formats (auto-detected by extension):
#   *.txt   — plain prompt text. Fed directly as: agy --dangerously-skip-permissions -p "$(cat spec)"
#   *.json  — manifest with { "prompt": "...", "attachments": ["/path/a.png", ...] }.
#             Rendered as a single prompt with @path references appended inline.
#
# Writes:
#   ~/.claude/logs/gemini-<ISO>.log  — full stdout+stderr of gemini run
#   ~/.claude/gemini-last.json       — { timestamp, task_name, elapsed_s,
#                                        status, exit_code, spec_path,
#                                        log_path, chars_out, attachments }
#
# Exit code passes through from `gemini` so callers can branch on failure.
#
# Note: no `tokens` field — Gemini CLI's free/OAuth tier does not consistently
# print token counts to stdout. `chars_out` is used as a proxy for output volume.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/dispatch-common.sh"

SPEC_FILE="${1:-}"
TASK_NAME="$(dc_task_name "${SPEC_FILE:-dispatch}" "${2:-}")"

if [ -z "$SPEC_FILE" ] || [ ! -f "$SPEC_FILE" ]; then
  echo "usage: gemini-dispatch.sh <spec-file> [task-name]" >&2
  echo "error: spec file missing or unreadable: $SPEC_FILE" >&2
  exit 2
fi

CLAUDE_DIR="$HOME/.claude"
LOG_DIR="$CLAUDE_DIR/logs"
mkdir -p "$LOG_DIR"

TS_FILE="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/gemini-${TS_FILE}.log"
LAST_JSON="$CLAUDE_DIR/gemini-last.json"

# Build prompt + attachment list based on spec format
PROMPT=""
ATTACHMENT_COUNT=0

case "$SPEC_FILE" in
  *.json)
    # Parse JSON manifest: { "prompt": "...", "attachments": [...] }
    PARSED="$(SPEC_FILE="$SPEC_FILE" python3 - <<'PY'
import json, os, sys
with open(os.environ["SPEC_FILE"]) as f:
    doc = json.load(f)
prompt = doc.get("prompt", "")
attachments = doc.get("attachments", []) or []
# Validate attachments exist
missing = [a for a in attachments if not os.path.isfile(a)]
if missing:
    sys.stderr.write("missing attachment(s): " + ", ".join(missing) + "\n")
    sys.exit(3)
# Build composite prompt: original prompt + @path lines
parts = [prompt]
for a in attachments:
    parts.append("@" + a)
print(json.dumps({
    "prompt": "\n\n".join(parts),
    "count":  len(attachments),
}))
PY
)"
    PARSE_EXIT=$?
    if [ "$PARSE_EXIT" -ne 0 ]; then
      echo "error: failed to parse JSON manifest (exit $PARSE_EXIT)" >&2
      exit "$PARSE_EXIT"
    fi
    PROMPT="$(echo "$PARSED" | python3 -c 'import sys,json; print(json.load(sys.stdin)["prompt"])')"
    ATTACHMENT_COUNT="$(echo "$PARSED" | python3 -c 'import sys,json; print(json.load(sys.stdin)["count"])')"
    ;;
  *)
    PROMPT="$(cat "$SPEC_FILE")"
    ;;
esac

[ -n "$PROMPT" ] || { echo "ERROR: empty prompt extracted from spec" >&2; exit 3; }

{
  echo "── gemini-dispatch: $TASK_NAME @ $TS_FILE ──"
  echo "spec:        $SPEC_FILE"
  echo "attachments: $ATTACHMENT_COUNT"
  echo ""
} | tee -a "$LOG_FILE"

START_EPOCH="$(dc_now)"

# ── Executor resolution ──────────────────────────────────────────────────────
# Antigravity CLI (`agy`) is the SOLE executor as of the 2026-05-29 cutover.
# Gemini CLI is retired and is no longer an available fallback.
#
#   DISPATCH_EXECUTOR=auto|agy   (default: auto → agy only)
#
# AGY_PRINT_TIMEOUT caps agy's print-mode wait (default 20m).
# Prevent the PATH `agy`/`codex` shims from also ledger-logging this dispatch —
# the wrapper already writes its own gemini-*.log, which the statusline counts.
# (agy is invoked by absolute path below so it bypasses the shim anyway; this is
# belt-and-suspenders in case that ever changes.)
export LLM_LEDGER_SKIP=1
DISPATCH_EXECUTOR="${DISPATCH_EXECUTOR:-auto}"
AGY_PRINT_TIMEOUT="${AGY_PRINT_TIMEOUT:-20m}"
STALL_TICKS="${AGY_STALL_MINS:-5}"

case "$AGY_PRINT_TIMEOUT" in
  *m)
    AGY_TIMEOUT_NUMBER="${AGY_PRINT_TIMEOUT%m}"
    AGY_TIMEOUT_MULTIPLIER=60
    ;;
  *s)
    AGY_TIMEOUT_NUMBER="${AGY_PRINT_TIMEOUT%s}"
    AGY_TIMEOUT_MULTIPLIER=1
    ;;
  *)
    AGY_TIMEOUT_NUMBER="$AGY_PRINT_TIMEOUT"
    AGY_TIMEOUT_MULTIPLIER=1
    ;;
esac
case "$AGY_TIMEOUT_NUMBER" in
  ""|*[!0-9]*) AGY_PRINT_TIMEOUT_SECS=1200 ;;
  *) AGY_PRINT_TIMEOUT_SECS=$(( 10#$AGY_TIMEOUT_NUMBER * AGY_TIMEOUT_MULTIPLIER )) ;;
esac
HARD_CAP_SECS="$(( AGY_PRINT_TIMEOUT_SECS + 300 ))"

# Resolve binaries by PATH, then by known install location (this script runs in a
# non-login shell, so ~/.local/bin from the agy installer may not be on PATH).
AGY_BIN="$(command -v agy 2>/dev/null || true)"
[ -z "$AGY_BIN" ] && [ -x "$HOME/.local/bin/agy" ] && AGY_BIN="$HOME/.local/bin/agy"

# Model / effort selection (added 2026-08-18). agy 1.1.13 exposes `--model` and `--effort`
# (low|medium|high); older notes claiming "no model flag exists" are stale. `agy models`
# lists them — currently gemini-3.7/3.6/3.5-flash-{high,medium,low}, gemini-3.1-pro-{high,low},
# claude-opus-4-6-thinking, claude-sonnet-4-6, gpt-oss-120b-medium.
#
# Default to the STRONGEST sensible tier, not the cheapest: agy quota is effectively
# unlimited at the user's volume (weekly sits ~0-1% used), so down-tiering here saves nothing
# and only costs quality. Override per-dispatch with AGY_MODEL / AGY_EFFORT.
AGY_MODEL="${AGY_MODEL:-}"
AGY_EFFORT="${AGY_EFFORT:-high}"

AGY_ARGS=(--dangerously-skip-permissions --print-timeout "$AGY_PRINT_TIMEOUT")
[ -n "$AGY_MODEL" ] && AGY_ARGS+=(--model "$AGY_MODEL")

# --effort is REJECTED outright for models whose thinking is built in (verified 2026-08-18:
# `--model claude-opus-4-6-thinking --effort high` fails instantly with
# "invalid model selection ... --effort is not supported"). Passing it anyway kills the
# dispatch in ~5s with no output, which reads exactly like a silent no-op — so suppress it
# rather than let a flag error masquerade as a model failure.
case "$AGY_MODEL" in
  claude-*|gpt-*) AGY_EFFORT="" ;;
esac
case "$AGY_EFFORT" in
  low|medium|high) AGY_ARGS+=(--effort "$AGY_EFFORT") ;;
  "") ;;
  *) echo "warning: ignoring invalid AGY_EFFORT='$AGY_EFFORT' (want low|medium|high)" >&2 ;;
esac

run_agy() { "$AGY_BIN" "${AGY_ARGS[@]}" -p "$PROMPT" 2>&1; }

EXIT_CODE=127
EXECUTOR_USED="none"
WATCHDOG_STATUS=""
CAPTURE_FILE=""
STATUS_FILE=""
case "$DISPATCH_EXECUTOR" in
  gemini)
    echo "ERROR: gemini executor retired 2026-06-18 — agy is the sole executor" >&2
    exit 2
    ;;
  auto|agy|*)
    # agy is the only auto executor; no silent gemini fallback.
    CAPTURE_FILE="$(mktemp "${TMPDIR:-/tmp}/gemini-dispatch-capture.XXXXXX")" || exit 1
    STATUS_FILE="$(mktemp "${TMPDIR:-/tmp}/gemini-dispatch-status.XXXXXX")" || {
      rm -f "$CAPTURE_FILE"
      exit 1
    }
    if [ -n "$AGY_BIN" ]; then
      EXECUTOR_USED="agy"
      set -m
      (
        set +m
        run_agy | tee -a "$LOG_FILE" "$CAPTURE_FILE"
        PIPE_EXIT="${PIPESTATUS[0]}"
        exit "$PIPE_EXIT"
      ) &
      TARGET_PID=$!
      set +m

      dc_watchdog_start "$LOG_FILE" "$TARGET_PID" "$STALL_TICKS" "$HARD_CAP_SECS" "$TASK_NAME" "$STATUS_FILE"
      wait "$TARGET_PID"
      EXIT_CODE=$?
      dc_watchdog_stop
    else
      echo "error: agy not found on PATH or ~/.local/bin — install Antigravity CLI (https://antigravity.google/cli)" | tee -a "$LOG_FILE"
      EXIT_CODE=127; EXECUTOR_USED="none"
    fi
    ;;
esac

END_EPOCH="$(dc_now)"
ELAPSED="$(dc_elapsed "$START_EPOCH" "$END_EPOCH")"
WATCHDOG_STATUS="$(tr -d '\r\n' < "$STATUS_FILE")"

CHARS_OUT="$(wc -c < "$CAPTURE_FILE" | tr -d ' ')"

case "$WATCHDOG_STATUS" in
  stalled)
    STATUS="stalled"
    STATUS_DETAIL="no log growth for ${STALL_TICKS}m"
    ;;
  timeout)
    STATUS="timeout"
    STATUS_DETAIL="hard cap exceeded (${HARD_CAP_SECS}s)"
    ;;
  *)
    if [ "$EXIT_CODE" -ne 0 ]; then
      STATUS="error"
      STATUS_DETAIL="agy exited with code $EXIT_CODE"
    elif [ "$CHARS_OUT" -lt 200 ]; then
      STATUS="empty"
      STATUS_DETAIL="agy output was under 200 bytes"
    else
      STATUS="success"
      STATUS_DETAIL="agy produced at least 200 bytes"
    fi
    ;;
esac

TASK_NAME="$TASK_NAME" ELAPSED="$ELAPSED" STATUS="$STATUS" \
STATUS_DETAIL="$STATUS_DETAIL" EXIT_CODE="$EXIT_CODE" \
SPEC_FILE="$SPEC_FILE" LOG_FILE="$LOG_FILE" \
CHARS_OUT="$CHARS_OUT" ATTACHMENT_COUNT="$ATTACHMENT_COUNT" \
EXECUTOR_USED="$EXECUTOR_USED" \
dc_write_last_json "$LAST_JSON" gemini

rm -f "$STATUS_FILE" "$CAPTURE_FILE"

{
  echo ""
  echo "── gemini-dispatch done: executor=$EXECUTOR_USED status=$STATUS chars_out=$CHARS_OUT elapsed=${ELAPSED}s ──"
  echo "log:     $LOG_FILE"
  echo "summary: $LAST_JSON"
} | tee -a "$LOG_FILE"

exit "$EXIT_CODE"
