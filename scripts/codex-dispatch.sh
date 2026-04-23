#!/usr/bin/env bash
# Dispatch a task spec to Codex CLI, capture tokens/timing, update status
# artifacts consumed by the Claude Code statusline.
#
# Usage: codex-dispatch.sh <spec-file> [task-name]
#
# Writes:
#   ~/.claude/logs/codex-<ISO>.log       — full stdout+stderr of codex exec
#   ~/.claude/codex-last.json            — { timestamp, task_name, tokens,
#                                            elapsed_s, status, exit_code,
#                                            spec_path, log_path, model,
#                                            reasoning_effort }
#   ~/.claude/codex-auth-cache.txt       — refreshed for statusline
#
# Exit code passes through from `codex exec` so callers can branch on failure.

set -uo pipefail

SPEC_FILE="${1:-}"
TASK_NAME="${2:-$(basename "${SPEC_FILE:-dispatch}" .txt)}"

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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Refresh auth cache in background (cheap; updates codex-auth-cache.txt)
"$SCRIPT_DIR/codex-refresh-auth-cache.sh" >/dev/null 2>&1 &

{
  echo "── codex-dispatch: $TASK_NAME @ $TS_FILE ──"
  echo "spec: $SPEC_FILE"
  echo ""
} | tee -a "$LOG_FILE"

START_EPOCH="$(date +%s)"

codex exec --dangerously-bypass-approvals-and-sandbox "$(cat "$SPEC_FILE")" 2>&1 \
  | tee -a "$LOG_FILE"
EXIT_CODE="${PIPESTATUS[0]}"

END_EPOCH="$(date +%s)"
ELAPSED="$(( END_EPOCH - START_EPOCH ))"

if [ "$EXIT_CODE" -eq 0 ]; then STATUS="success"; else STATUS="failed"; fi

# Parse "tokens used\nNNN,NNN" block from log (case-insensitive, tolerate commas)
TOKENS="$(awk '
  tolower($0) ~ /^[[:space:]]*tokens?[[:space:]]+used/ { want=1; next }
  want {
    t=$0; gsub(/,/, "", t); gsub(/[[:space:]]/, "", t)
    if (t ~ /^[0-9]+$/) { print t; exit }
  }
' "$LOG_FILE")"
[ -z "$TOKENS" ] && TOKENS=0

# Capture active model from the "model: <id>" line Codex prints at session start.
MODEL="$(grep -m1 -E '^model:[[:space:]]' "$LOG_FILE" 2>/dev/null | awk '{print $2}')"
[ -z "$MODEL" ] && MODEL="unknown"

# Capture reasoning effort from the "reasoning effort: <level>" line (default: none).
REASONING="$(grep -m1 -E '^reasoning effort:[[:space:]]' "$LOG_FILE" 2>/dev/null | awk '{print $3}')"
[ -z "$REASONING" ] && REASONING="none"

TASK_NAME="$TASK_NAME" TOKENS="$TOKENS" ELAPSED="$ELAPSED" STATUS="$STATUS" \
EXIT_CODE="$EXIT_CODE" SPEC_FILE="$SPEC_FILE" LOG_FILE="$LOG_FILE" \
MODEL="$MODEL" REASONING="$REASONING" \
python3 - > "$LAST_JSON" <<'PY'
import json, os
from datetime import datetime, timezone
print(json.dumps({
  "timestamp":         datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
  "task_name":         os.environ.get("TASK_NAME", ""),
  "model":             os.environ.get("MODEL", "unknown"),
  "reasoning_effort":  os.environ.get("REASONING", "none"),
  "tokens":            int(os.environ.get("TOKENS") or 0),
  "elapsed_s":         int(os.environ.get("ELAPSED") or 0),
  "status":            os.environ.get("STATUS", "unknown"),
  "exit_code":         int(os.environ.get("EXIT_CODE") or 0),
  "spec_path":         os.environ.get("SPEC_FILE", ""),
  "log_path":          os.environ.get("LOG_FILE", ""),
}, indent=2))
PY

{
  echo ""
  echo "── codex-dispatch done: status=$STATUS tokens=$TOKENS elapsed=${ELAPSED}s ──"
  echo "log:     $LOG_FILE"
  echo "summary: $LAST_JSON"
} | tee -a "$LOG_FILE"

exit "$EXIT_CODE"
