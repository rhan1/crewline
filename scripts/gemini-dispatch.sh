#!/usr/bin/env bash
# Dispatch a task spec to Gemini or Antigravity CLI, capture elapsed/status, update status
# artifacts consumed by the Claude Code statusline.
#
# Usage: gemini-dispatch.sh <spec-file> [task-name]
#
# Spec formats (auto-detected by extension):
#   *.txt   — plain prompt text. Fed directly as: gemini --yolo -p "$(cat spec)"
#   *.json  — manifest with { "prompt": "...", "attachments": ["/path/a.png", ...] }.
#             Rendered as a single prompt with @path references appended inline.
#
# Writes:
#   ~/.claude/logs/gemini-<ISO>.log  — full stdout+stderr of the selected executor
#   ~/.claude/gemini-last.json       — { timestamp, task_name, elapsed_s,
#                                        status, status_detail, exit_code,
#                                        executor, spec_path, log_path,
#                                        chars_out, attachments }
#
# Exit code passes through from the selected executor so callers can branch on failure.
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

# Keep the public wrapper's Gemini CLI behavior, with Antigravity available as
# an optional executor. In auto mode, Gemini remains the first choice.
DISPATCH_EXECUTOR="${DISPATCH_EXECUTOR:-auto}"
GEMINI_DISPATCH_MODEL="${GEMINI_DISPATCH_MODEL:-gemini-3.1-pro-preview}"
AGY_PRINT_TIMEOUT="${AGY_PRINT_TIMEOUT:-20m}"
STALL_TICKS="${AGY_STALL_MINS:-5}"

# Convert agy's print timeout to seconds and give the external watchdog a
# five-minute grace period. The watchdog is also the Gemini CLI time limiter.
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

# Resolve binaries by PATH, then check agy's common user-local install path.
AGY_BIN="$(command -v agy 2>/dev/null || true)"
[ -z "$AGY_BIN" ] && [ -x "$HOME/.local/bin/agy" ] && AGY_BIN="$HOME/.local/bin/agy"
GEMINI_BIN="$(command -v gemini 2>/dev/null || true)"

run_agy() { "$AGY_BIN" --dangerously-skip-permissions --print-timeout "$AGY_PRINT_TIMEOUT" -p "$PROMPT" 2>&1; }
run_gemini() { "$GEMINI_BIN" --yolo -m "$GEMINI_DISPATCH_MODEL" -p "$PROMPT" 2>&1; }

CAPTURE_FILE="$(mktemp "${TMPDIR:-/tmp}/gemini-dispatch-capture.XXXXXX")" || exit 1
STATUS_FILE="$(mktemp "${TMPDIR:-/tmp}/gemini-dispatch-status.XXXXXX")" || {
  rm -f "$CAPTURE_FILE"
  exit 1
}

EXIT_CODE=127
EXECUTOR_USED="none"
EXECUTOR_ERROR_DETAIL=""
RUNNER=""

case "$DISPATCH_EXECUTOR" in
  gemini)
    if [ -n "$GEMINI_BIN" ]; then
      EXECUTOR_USED="gemini"
      RUNNER="run_gemini"
    else
      EXECUTOR_ERROR_DETAIL="gemini executable not found"
      echo "error: gemini not found on PATH" | tee -a "$LOG_FILE"
    fi
    ;;
  agy)
    if [ -n "$AGY_BIN" ]; then
      EXECUTOR_USED="agy"
      RUNNER="run_agy"
    else
      EXECUTOR_ERROR_DETAIL="agy executable not found"
      echo "error: agy not found on PATH or $HOME/.local/bin" | tee -a "$LOG_FILE"
    fi
    ;;
  auto)
    if [ -n "$GEMINI_BIN" ]; then
      EXECUTOR_USED="gemini"
      RUNNER="run_gemini"
    elif [ -n "$AGY_BIN" ]; then
      EXECUTOR_USED="agy"
      RUNNER="run_agy"
    else
      EXECUTOR_ERROR_DETAIL="no supported executor found"
      echo "error: neither gemini nor agy was found" | tee -a "$LOG_FILE"
    fi
    ;;
  *)
    EXIT_CODE=2
    EXECUTOR_ERROR_DETAIL="unsupported executor: $DISPATCH_EXECUTOR"
    echo "error: DISPATCH_EXECUTOR must be auto, gemini, or agy" | tee -a "$LOG_FILE"
    ;;
esac

WATCHDOG_STATUS=""
if [ -n "$RUNNER" ]; then
  set -m
  (
    set +m
    "$RUNNER" | tee -a "$LOG_FILE" "$CAPTURE_FILE"
    PIPE_EXIT="${PIPESTATUS[0]}"
    exit "$PIPE_EXIT"
  ) &
  TARGET_PID=$!
  set +m

  dc_watchdog_start "$LOG_FILE" "$TARGET_PID" "$STALL_TICKS" "$HARD_CAP_SECS" "$TASK_NAME" "$STATUS_FILE"
  wait "$TARGET_PID"
  EXIT_CODE=$?
  dc_watchdog_stop
fi

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
      STATUS_DETAIL="${EXECUTOR_ERROR_DETAIL:-$EXECUTOR_USED exited with code $EXIT_CODE}"
    elif [ "$CHARS_OUT" -lt 200 ]; then
      STATUS="empty"
      STATUS_DETAIL="$EXECUTOR_USED output was under 200 bytes"
    else
      STATUS="success"
      STATUS_DETAIL="$EXECUTOR_USED produced at least 200 bytes"
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
