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
#                                            model, reasoning_effort, tier,
#                                            route_source, service_tier }
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

# Reserved-tier / service-tier guard (2026-10-08) — refuse before the quota gate, routing or
# any status write. max/algo (gpt-6-astra) are reserved for architect-level planning/review, so a
# forced max/algo needs an explicit CODEX_ALLOW_RESERVED=1. service_tier is `default` only: flex
# 400s server-side since 2026-09-29 and priority costs extra without buying quota.
case "${CODEX_TIER:-}" in
  max|algo)
    if [ "${CODEX_ALLOW_RESERVED:-}" != "1" ]; then
      echo "codex-dispatch: tier ${CODEX_TIER} is reserved for architect-level planning/review; set CODEX_ALLOW_RESERVED=1 to confirm" >&2
      exit 2
    fi ;;
esac
case "${CODEX_SERVICE_TIER:-}" in
  ""|default) ;;
  *)
    echo "codex-dispatch: CODEX_SERVICE_TIER='${CODEX_SERVICE_TIER}' refused — only 'default' is allowed (flex is dead server-side, priority is never worth paying)" >&2
    exit 2 ;;
esac

# Floor gate (dispatch-common.sh dc_quota_gate) — refuse before any tier routing, prompt
# building or status write, so a refused dispatch leaves codex-last.json untouched and the
# statusline never shows a run that did not happen. Exit 3 = refused. Gates both the 5h
# ("Codex") and weekly ("Codex weekly") windows from /balance.
dc_quota_gate '^Codex( weekly)?$' "$HOME/.claude/codex-rate-limits.json" || exit $?

CLAUDE_DIR="$HOME/.claude"
LOG_DIR="$CLAUDE_DIR/logs"
mkdir -p "$LOG_DIR"

# ── Tier routing ──────────────────────────────────────────────────────────────
# Codex quota is a binding constraint, so a dispatch no longer inherits the
# global ~/.codex/config.toml model. A tier is chosen per task; the table lives
# in dispatch-common.sh (dc_codex_tier_targets).
#
# Env controls:
#   CODEX_TIER=lite|std|high|max|algo
#                             force a tier, skip classification. `max`/`algo`
#                             (GPT-6 Astra) are never chosen automatically.
#                             They also need CODEX_ALLOW_RESERVED=1 (guard above).
#   DISPATCH_FORCE=1          bypass the quota floor gate
#   CODEX_ROUTER=off          disable routing entirely (naked invocation =
#                             whatever ~/.codex/config.toml says)
#   CODEX_MODEL / CODEX_EFFORT / CODEX_SERVICE_TIER
#                             override individual knobs after tier selection
#   CODEX_CX_LITE_MAX / CODEX_CX_MAX_MIN
#                             complexity thresholds (percent) for recalibration
#
# Auto-classification uses the `ruflo` CLI's complexity score when it is on
# PATH (`ruflo hooks model-route`); complexity separates cleanly (renames
# ~10%, mechanical loaders ~30%, architecture/debug ~50%). Any failure —
# ruflo absent, hang, unparseable JSON — falls back to `std`: the safe
# middle, never `max`, so a broken classifier cannot silently restore
# full-price dispatching.
ROUTER_MODE="${CODEX_ROUTER:-on}"
TIER=""
ROUTE_SOURCE="none"
ROUTE_CX=0
export CX_LITE_MAX="${CODEX_CX_LITE_MAX:-20}"   # below this -> lite
export CX_MAX_MIN="${CODEX_CX_MAX_MIN:-42}"     # at/above this -> high
codex_tier_from_ruflo() {
  local text raw parsed
  command -v ruflo >/dev/null 2>&1 || return 1
  text="$(printf '%s %s' "$TASK_NAME" "$(head -c 2000 "$SPEC_FILE" 2>/dev/null)" \
          | tr '\n\r\t' '   ' \
          | tr -cd '[:alnum:][:space:]._/-' \
          | cut -c1-400)"
  [ -n "$text" ] || return 1
  raw="$(dc_timeout 20 ruflo hooks model-route -t "$text" --format json 2>/dev/null)" || return 1
  parsed="$(printf '%s\n' "$raw" | sed -n '/^[[:space:]]*{/,$p' | python3 -c '
import json, os, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(1)
raw_cx = d.get("complexity")
if raw_cx is None:
    sys.exit(1)
cx = float(raw_cx) * 100
lite_max = float(os.environ["CX_LITE_MAX"])
max_min = float(os.environ["CX_MAX_MIN"])
tier = "lite" if cx < lite_max else ("std" if cx < max_min else "high")
print("%s %d" % (tier, round(cx)))
' 2>/dev/null)" || return 1
  [ -n "$parsed" ] || return 1
  printf '%s\n' "$parsed"
}

if [ "$ROUTER_MODE" = "off" ]; then
  ROUTE_SOURCE="disabled"
else
  case "${CODEX_TIER:-}" in
    lite|std|high|max|algo)
      TIER="$CODEX_TIER"; ROUTE_SOURCE="forced" ;;
    "")
      if ROUTE_RESULT="$(codex_tier_from_ruflo)"; then
        TIER="${ROUTE_RESULT%% *}"; ROUTE_CX="${ROUTE_RESULT##* }"; ROUTE_SOURCE="ruflo"
      else
        TIER="std"; ROUTE_SOURCE="fallback"
      fi ;;
    *)
      echo "warning: ignoring invalid CODEX_TIER='$CODEX_TIER' (want lite|std|high|max|algo); using std" >&2
      TIER="std"; ROUTE_SOURCE="fallback" ;;
  esac
fi

CODEX_ARGS=()
TIER_MODEL=""
TIER_EFFORT=""
SERVICE_TIER=""
if [ -n "$TIER" ]; then
  TIER_TARGETS="$(dc_codex_tier_targets "$TIER")"
  TIER_MODEL="$(printf '%s' "$TIER_TARGETS" | awk '{print $1}')"
  TIER_EFFORT="$(printf '%s' "$TIER_TARGETS" | awk '{print $2}')"
  SERVICE_TIER="$(printf '%s' "$TIER_TARGETS" | awk '{print $3}')"
  TIER_MODEL="${CODEX_MODEL:-$TIER_MODEL}"
  TIER_EFFORT="${CODEX_EFFORT:-$TIER_EFFORT}"
  SERVICE_TIER="${CODEX_SERVICE_TIER:-$SERVICE_TIER}"
  CODEX_ARGS=(-m "$TIER_MODEL"
              -c "model_reasoning_effort=\"$TIER_EFFORT\""
              -c "service_tier=\"$SERVICE_TIER\"")
fi

TS_FILE="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/codex-${TS_FILE}.log"
LAST_JSON="$CLAUDE_DIR/codex-last.json"

# Refresh auth cache in background (cheap; updates codex-auth-cache.txt)
"$SCRIPT_DIR/codex-refresh-auth-cache.sh" >/dev/null 2>&1 &

{
  echo "── codex-dispatch: $TASK_NAME @ $TS_FILE ──"
  echo "spec: $SPEC_FILE"
  if [ -n "$TIER" ]; then
    echo "[CodexRoute] tier=$TIER model=$TIER_MODEL effort=$TIER_EFFORT service_tier=$SERVICE_TIER source=$ROUTE_SOURCE complexity=${ROUTE_CX}%"
  else
    echo "[CodexRoute] routing $ROUTE_SOURCE — inheriting ~/.codex/config.toml"
  fi
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
  codex exec ${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"} --dangerously-bypass-approvals-and-sandbox "$(cat "$SPEC_FILE")" </dev/null 2>&1 \
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
# Allowlist matches what the 5.6/6 family accepts: none|low|medium|high|xhigh|max, plus
# `ultra` on sol/astra. `minimal` is rejected upstream with a 400, so it never appears here.
case "$REASONING" in (low|medium|high|xhigh|max|ultra|none) ;; (*) REASONING="none" ;; esac

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
TIER="$TIER" ROUTE_SOURCE="$ROUTE_SOURCE" ROUTE_CX="$ROUTE_CX" \
SERVICE_TIER="$SERVICE_TIER" \
dc_write_last_json "$LAST_JSON" codex

{
  echo ""
  echo "── codex-dispatch done: status=$STATUS tokens=$TOKENS elapsed=${ELAPSED}s ──"
  echo "log:     $LOG_FILE"
  echo "summary: $LAST_JSON"
} | tee -a "$LOG_FILE"

exit "$EXIT_CODE"
