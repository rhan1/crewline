#!/usr/bin/env bash
# Shared helpers for the Codex and Antigravity dispatch wrappers.
# This file intentionally performs no work when sourced.

dc_write_last_json() {
  local target="${1:-}"
  local summary_kind="${2:-}"
  local tmp

  [ -n "$target" ] || return 2
  case "$summary_kind" in
    codex|gemini) ;;
    *) return 2 ;;
  esac

  command -v python3 >/dev/null 2>&1 || return 127
  tmp="${target}.tmp.$$"

  if ! DC_JSON_KIND="$summary_kind" \
    TASK_NAME="${TASK_NAME:-}" TOKENS="${TOKENS:-}" \
    ELAPSED="${ELAPSED:-}" STATUS="${STATUS:-}" \
    STATUS_DETAIL="${STATUS_DETAIL:-}" EXIT_CODE="${EXIT_CODE:-}" \
    SPEC_FILE="${SPEC_FILE:-}" LOG_FILE="${LOG_FILE:-}" \
    MODEL="${MODEL:-}" REASONING="${REASONING:-}" \
    CHARS_OUT="${CHARS_OUT:-}" ATTACHMENT_COUNT="${ATTACHMENT_COUNT:-}" \
    EXECUTOR_USED="${EXECUTOR_USED:-}" \
    python3 - > "$tmp" <<'PY'
import json
import os
from datetime import datetime, timezone

kind = os.environ["DC_JSON_KIND"]
if kind == "codex":
    summary = {
        "timestamp":        datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "task_name":        os.environ.get("TASK_NAME", ""),
        "model":            os.environ.get("MODEL", "unknown"),
        "reasoning_effort": os.environ.get("REASONING", "none"),
        "tokens":           int(os.environ.get("TOKENS") or 0),
        "elapsed_s":        int(os.environ.get("ELAPSED") or 0),
        "status":           os.environ.get("STATUS", "unknown"),
        "status_detail":    os.environ.get("STATUS_DETAIL", ""),
        "exit_code":        int(os.environ.get("EXIT_CODE") or 0),
        "spec_path":        os.environ.get("SPEC_FILE", ""),
        "log_path":         os.environ.get("LOG_FILE", ""),
    }
else:
    summary = {
        "timestamp":     datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "task_name":     os.environ.get("TASK_NAME", ""),
        "elapsed_s":     int(os.environ.get("ELAPSED") or 0),
        "status":        os.environ.get("STATUS", "unknown"),
        "status_detail": os.environ.get("STATUS_DETAIL", ""),
        "exit_code":     int(os.environ.get("EXIT_CODE") or 0),
        "executor":      os.environ.get("EXECUTOR_USED", "unknown"),
        "spec_path":     os.environ.get("SPEC_FILE", ""),
        "log_path":      os.environ.get("LOG_FILE", ""),
        "chars_out":     int(os.environ.get("CHARS_OUT") or 0),
        "attachments":   int(os.environ.get("ATTACHMENT_COUNT") or 0),
    }

print(json.dumps(summary, indent=2))
PY
  then
    rm -f "$tmp"
    return 1
  fi

  if ! mv -f "$tmp" "$target"; then
    rm -f "$tmp"
    return 1
  fi
}

dc_watchdog_start() {
  local log_file="$1"
  local target_pid="$2"
  local stall_ticks="$3"
  local hard_cap_secs="$4"
  local task_name="$5"
  local status_file="$6"

  (
    local started_at last_size current_size elapsed unchanged_ticks
    started_at="$(dc_now)"
    last_size="$(stat -f %z "$log_file" 2>/dev/null || printf '0')"
    unchanged_ticks=0

    dc_watchdog_trip() {
      local status="$1"
      local log_message="$2"
      local notification="$3"

      printf '[watchdog] %s\n' "$log_message" >> "$log_file"
      printf '%s\n' "$status" > "$status_file"
      osascript \
        -e 'on run argv' \
        -e 'display notification (item 1 of argv) with title "dispatch watchdog"' \
        -e 'end run' \
        "$notification" >/dev/null 2>&1 || true

      if ! kill -9 -- "-${target_pid}" 2>/dev/null; then
        pkill -9 -P "$target_pid" 2>/dev/null || true
        kill -9 "$target_pid" 2>/dev/null || true
      fi
      exit 0
    }

    while :; do
      sleep 60
      kill -0 "$target_pid" 2>/dev/null || exit 0

      current_size="$(stat -f %z "$log_file" 2>/dev/null || printf '0')"
      elapsed="$(( $(dc_now) - started_at ))"
      if [ "$elapsed" -gt "$hard_cap_secs" ]; then
        dc_watchdog_trip \
          "timeout" \
          "TIMEOUT after ${hard_cap_secs}s hard cap - killing" \
          "${task_name}: timed out after ${hard_cap_secs}s; killed"
      fi

      if [ "$current_size" = "$last_size" ]; then
        unchanged_ticks="$(( unchanged_ticks + 1 ))"
      else
        unchanged_ticks=0
        last_size="$current_size"
      fi

      if [ "$unchanged_ticks" -ge "$stall_ticks" ]; then
        dc_watchdog_trip \
          "stalled" \
          "STALLED after ${stall_ticks}m of no log growth - killing" \
          "${task_name}: stalled for ${stall_ticks}m; killed"
      fi
    done
  ) &
  DC_WATCHDOG_PID=$!
  disown -h "$DC_WATCHDOG_PID" 2>/dev/null || true
}

dc_watchdog_stop() {
  local watchdog_pid="${DC_WATCHDOG_PID:-}"

  [ -n "$watchdog_pid" ] || return 0
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  DC_WATCHDOG_PID=""
}

dc_task_name() {
  local spec_path="${1:-dispatch}"
  local override="${2:-}"

  if [ -n "$override" ]; then
    printf '%s\n' "$override"
  else
    basename "${spec_path:-dispatch}" | sed 's/\.[^.]*$//'
  fi
}

dc_now() {
  date +%s
}

dc_elapsed() {
  local start_epoch="$1"
  local end_epoch="${2:-$(dc_now)}"

  printf '%s\n' "$(( end_epoch - start_epoch ))"
}
