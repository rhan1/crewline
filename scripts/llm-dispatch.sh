#!/usr/bin/env bash
# Generic LLM dispatcher — reads ~/.claude/orchestrator-models.json and
# dispatches a prompt to any registered CLI-based model.
#
# Usage: llm-dispatch.sh <model_id> <prompt_file_path>
#
# Writes:
#   ~/.claude/logs/llm-dispatch-<id>-<ISO>.log  — full stdout+stderr
#   <last_file from config>                      — { timestamp, task_name,
#                                                    elapsed_s, status,
#                                                    exit_code, model,
#                                                    spec_path, log_path }
#
# Exit code passes through from the dispatched CLI.

set -uo pipefail

MODEL_ID="${1:-}"
PROMPT_FILE="${2:-}"
TASK_NAME="${3:-$(basename "${PROMPT_FILE:-dispatch}" | sed 's/\.[^.]*$//')}"

if [ -z "$MODEL_ID" ] || [ -z "$PROMPT_FILE" ]; then
  echo "usage: llm-dispatch.sh <model_id> <prompt_file_path> [task_name]" >&2
  exit 2
fi

if [ ! -f "$PROMPT_FILE" ]; then
  echo "error: prompt file missing or unreadable: $PROMPT_FILE" >&2
  exit 2
fi

REGISTRY="$HOME/.claude/orchestrator-models.json"

if [ ! -f "$REGISTRY" ]; then
  echo "error: model registry not found: $REGISTRY" >&2
  echo "  Add it manually or run ./install.sh to launch the model wizard." >&2
  exit 1
fi

# Validate JSON
if ! jq empty "$REGISTRY" 2>/dev/null; then
  echo "error: $REGISTRY is not valid JSON" >&2
  exit 1
fi

# Look up the model entry
MODEL_ENTRY="$(jq -c --arg id "$MODEL_ID" '.models[] | select(.id == $id)' "$REGISTRY" 2>/dev/null)"

if [ -z "$MODEL_ENTRY" ]; then
  echo "error: model '$MODEL_ID' not found in $REGISTRY" >&2
  echo "  Add it to $REGISTRY or run ./install.sh to launch the model wizard." >&2
  exit 1
fi

# Extract fields (Bash 3.2 compat — no associative arrays, query individually)
MODEL_COMMAND="$(echo "$MODEL_ENTRY" | jq -r '.command')"
ARGS_TEMPLATE="$(echo "$MODEL_ENTRY" | jq -r '.args_template')"
LAST_FILE_RAW="$(echo "$MODEL_ENTRY" | jq -r '.last_file')"
MODEL_LABEL="$(echo "$MODEL_ENTRY" | jq -r '.model_label // ""')"

# Expand ~ in last_file path
LAST_FILE="${LAST_FILE_RAW/#\~/$HOME}"

# Verify the CLI is on PATH
if ! command -v "$MODEL_COMMAND" >/dev/null 2>&1; then
  echo "error: command not found: $MODEL_COMMAND" >&2
  echo "  Install it, or remove model '$MODEL_ID' from $REGISTRY." >&2
  exit 1
fi

CLAUDE_DIR="$HOME/.claude"
LOG_DIR="$CLAUDE_DIR/logs"
mkdir -p "$LOG_DIR"
mkdir -p "$(dirname "$LAST_FILE")"

TS_FILE="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/llm-dispatch-${MODEL_ID}-${TS_FILE}.log"

# Build a temp output file path (some CLIs need --output-last-message style flag)
OUTPUT_FILE="$(mktemp /tmp/llm-dispatch-output-XXXXXX)"

# Substitute template placeholders
RESOLVED_ARGS="${ARGS_TEMPLATE//\{prompt_file\}/$PROMPT_FILE}"
RESOLVED_ARGS="${RESOLVED_ARGS//\{output_file\}/$OUTPUT_FILE}"

{
  echo "── llm-dispatch ($MODEL_ID): $TASK_NAME @ $TS_FILE ──"
  echo "command:     $MODEL_COMMAND $RESOLVED_ARGS"
  echo "prompt_file: $PROMPT_FILE"
  echo "last_file:   $LAST_FILE"
  echo ""
} | tee -a "$LOG_FILE"

START_EPOCH="$(date +%s)"

# Use eval to correctly handle quoted args in the template
eval "$MODEL_COMMAND $RESOLVED_ARGS" 2>&1 | tee -a "$LOG_FILE"
EXIT_CODE="${PIPESTATUS[0]}"

END_EPOCH="$(date +%s)"
ELAPSED="$(( END_EPOCH - START_EPOCH ))"

if [ "$EXIT_CODE" -eq 0 ]; then STATUS="success"; else STATUS="failed"; fi

# Clean up temp output file
rm -f "$OUTPUT_FILE"

# Write last-run JSON (lean schema — richer codex/gemini schemas stay in their scripts)
MODEL_LABEL_VAL="$MODEL_LABEL" \
TASK_NAME="$TASK_NAME" \
MODEL_ID="$MODEL_ID" \
ELAPSED="$ELAPSED" \
STATUS="$STATUS" \
EXIT_CODE="$EXIT_CODE" \
PROMPT_FILE="$PROMPT_FILE" \
LOG_FILE="$LOG_FILE" \
python3 - > "$LAST_FILE" <<'PY'
import json, os
from datetime import datetime, timezone
print(json.dumps({
  "timestamp":   datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
  "task_name":   os.environ.get("TASK_NAME", ""),
  "model":       os.environ.get("MODEL_LABEL_VAL") or os.environ.get("MODEL_ID", ""),
  "elapsed_s":   int(os.environ.get("ELAPSED") or 0),
  "status":      os.environ.get("STATUS", "unknown"),
  "exit_code":   int(os.environ.get("EXIT_CODE") or 0),
  "spec_path":   os.environ.get("PROMPT_FILE", ""),
  "log_path":    os.environ.get("LOG_FILE", ""),
  "tokens":      None,
  "reasoning":   None,
}, indent=2))
PY

{
  echo ""
  echo "── llm-dispatch ($MODEL_ID) done: status=$STATUS elapsed=${ELAPSED}s ──"
  echo "log:     $LOG_FILE"
  echo "summary: $LAST_FILE"
} | tee -a "$LOG_FILE"

exit "$EXIT_CODE"
