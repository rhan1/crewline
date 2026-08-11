#!/usr/bin/env bash
# Dispatch a task spec to Codex CLI, capture tokens/timing, update status
# artifacts consumed by the Claude Code statusline.
#
# Usage: codex-dispatch.sh <spec-file> [task-name]
#
# Writes:
#   ~/.claude/logs/codex-<ISO>.log       — full stdout+stderr of codex exec
#   ~/.claude/codex-last.json            — { timestamp, task_name, tokens,
#                                            elapsed_s, status, status_detail,
#                                            exit_code, spec_path, log_path,
#                                            model, reasoning_effort }
#   ~/.claude/codex-auth-cache.txt       — refreshed for statusline
#
# Exit code passes through from `codex exec` so callers can branch on failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/dispatch-common.sh"

SPEC_FILE="${1:-}"
TASK_NAME="$(dc_task_name "${SPEC_FILE:-dispatch}" "${2:-}")"

if [ -z "$SPEC_FILE" ] || [ ! -f "$SPEC_FILE" ]; then
  echo "usage: codex-dispatch.sh <spec-file> [task-name]" >&2
  echo "error: spec file missing or unreadable: $SPEC_FILE" >&2
  exit 2
fi

CLAUDE_DIR="$HOME/.claude"
LOG_DIR="$CLAUDE_DIR/logs"
mkdir -p "$LOG_DIR"

TS_FILE="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/codex-${TS_FILE}.log"
LAST_JSON="$CLAUDE_DIR/codex-last.json"

# Refresh auth cache in background (cheap; updates codex-auth-cache.txt)
"$SCRIPT_DIR/codex-refresh-auth-cache.sh" >/dev/null 2>&1 &

{
  echo "── codex-dispatch: $TASK_NAME @ $TS_FILE ──"
  echo "spec: $SPEC_FILE"
  echo ""
} | tee -a "$LOG_FILE"

START_EPOCH="$(dc_now)"

# Snapshot the tree so we can report afterwards whether this dispatch actually
# wrote anything (see dispatch-common.sh). Detection is free and always on.
WORK_DIR="${CODEX_WORK_DIR:-$PWD}"
TREE_BEFORE="$(mktemp "${TMPDIR:-/tmp}/dispatch-tree-before.XXXXXX")"
TREE_AFTER="$(mktemp "${TMPDIR:-/tmp}/dispatch-tree-after.XXXXXX")"
TREE_KIND="$(dc_tree_snapshot "$WORK_DIR" "$TREE_BEFORE")"
TREE_CLEAN_BEFORE=0
dc_tree_was_clean "$TREE_BEFORE" && TREE_CLEAN_BEFORE=1

# </dev/null: codex exec blocks forever ("Reading additional input from stdin...")
# when stdin is an open non-tty pipe (cron/hooks/backgrounded dispatch).
STALL_TICKS="${CODEX_STALL_MINS:-10}"
HARD_CAP_SECS="${CODEX_EXEC_TIMEOUT_SECS:-2700}"
STATUS_FILE="$(mktemp "${TMPDIR:-/tmp}/codex-dispatch-status.XXXXXX")" || exit 1

set -m
(
  set +m
  codex exec --dangerously-bypass-approvals-and-sandbox "$(cat "$SPEC_FILE")" </dev/null 2>&1 \
    | tee -a "$LOG_FILE"
  PIPE_EXIT="${PIPESTATUS[0]}"
  exit "$PIPE_EXIT"
) &
TARGET_PID=$!
set +m

dc_watchdog_start "$LOG_FILE" "$TARGET_PID" "$STALL_TICKS" "$HARD_CAP_SECS" "$TASK_NAME" "$STATUS_FILE"
wait "$TARGET_PID"
EXIT_CODE=$?

END_EPOCH="$(dc_now)"
dc_watchdog_stop
WATCHDOG_STATUS="$(tr -d '\r\n' < "$STATUS_FILE")"
rm -f "$STATUS_FILE"

ELAPSED="$(dc_elapsed "$START_EPOCH" "$END_EPOCH")"

# ── Did this dispatch touch the tree? ────────────────────────────────────────
MUTATED=0; MUTATED_COUNT=0; MUTATION_ACTION="none"
if [ "$TREE_KIND" = "git" ]; then
  dc_tree_snapshot "$WORK_DIR" "$TREE_AFTER" >/dev/null
  TREE_CHANGES="$(dc_tree_changes "$TREE_BEFORE" "$TREE_AFTER")"
  if [ -n "$TREE_CHANGES" ]; then
    MUTATED=1
    MUTATED_COUNT="$(printf '%s\n' "$TREE_CHANGES" | grep -c . || true)"
    {
      echo ""
      echo "[Mutation] this dispatch wrote $MUTATED_COUNT path(s) under $WORK_DIR:"
      printf '%s\n' "$TREE_CHANGES" | sed 's/^/  /'
    } | tee -a "$LOG_FILE"
    if [ "${CODEX_EXPECT_READONLY:-0}" = "1" ]; then
      if [ "$TREE_CLEAN_BEFORE" -eq 1 ]; then
        dc_tree_revert "$WORK_DIR" "$TREE_CHANGES"
        MUTATION_ACTION="reverted"
        echo "[Mutation] CODEX_EXPECT_READONLY=1 — reverted the above (tree was clean before)." | tee -a "$LOG_FILE"
      else
        MUTATION_ACTION="kept-dirty-tree"
        echo "[Mutation] CODEX_EXPECT_READONLY=1 but the tree was ALREADY dirty — refusing to revert; inspect manually." | tee -a "$LOG_FILE"
      fi
    else
      MUTATION_ACTION="kept"
    fi
  fi
fi
rm -f "$TREE_BEFORE" "$TREE_AFTER"

# Parse "tokens used\nNNN,NNN" block from log (case-insensitive, tolerate commas)
TOKENS="$(tr -d '\000' < "$LOG_FILE" | LC_ALL=C awk '
  tolower($0) ~ /^[[:space:]]*tokens?[[:space:]]+used/ { want=1; next }
  want {
    t=$0; gsub(/,/, "", t); gsub(/[[:space:]]/, "", t)
    if (t ~ /^[0-9]+$/) { print t; exit }
  }
')"
[ -z "$TOKENS" ] && TOKENS=0

# Capture active model from the "model: <id>" line Codex prints at session start.
MODEL="$(grep -m1 -aE '^model:[[:space:]]' "$LOG_FILE" 2>/dev/null | awk '{print $2}')"
# -a + an allowlist prevent binary-log diagnostics from being parsed as a model.
case "$MODEL" in (*[!A-Za-z0-9._-]*|"") MODEL="unknown" ;; esac

# Capture reasoning effort from the "reasoning effort: <level>" line (default: none).
REASONING="$(grep -m1 -aE '^reasoning effort:[[:space:]]' "$LOG_FILE" 2>/dev/null | awk '{print $3}')"
case "$REASONING" in (minimal|low|medium|high|xhigh|ultra|none) ;; (*) REASONING="none" ;; esac

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
      STATUS_DETAIL="codex exited with code $EXIT_CODE"
    elif [ "$TOKENS" -eq 0 ]; then
      STATUS="suspect"
      STATUS_DETAIL="no token count found in log"
    else
      STATUS="success"
      STATUS_DETAIL="completed with nonzero token count"
    fi
    ;;
esac

TASK_NAME="$TASK_NAME" TOKENS="$TOKENS" ELAPSED="$ELAPSED" STATUS="$STATUS" \
STATUS_DETAIL="$STATUS_DETAIL" EXIT_CODE="$EXIT_CODE" \
SPEC_FILE="$SPEC_FILE" LOG_FILE="$LOG_FILE" \
MODEL="$MODEL" REASONING="$REASONING" \
dc_write_last_json "$LAST_JSON" codex

{
  echo ""
  echo "── codex-dispatch done: status=$STATUS tokens=$TOKENS elapsed=${ELAPSED}s ──"
  echo "log:     $LOG_FILE"
  echo "summary: $LAST_JSON"
} | tee -a "$LOG_FILE"

exit "$EXIT_CODE"
