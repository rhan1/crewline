#!/usr/bin/env bash
# Installer for LLM Orchestrator + Status Line.
#
# Symlinks this repo's files into ~/.claude/ so `git pull` upgrades everything.
# Backs up any existing targets to ~/.claude/backups/pre-install-<ts>/ first.
#
# Usage:
#   ./install.sh              # interactive: prompts per component (recommended)
#   ./install.sh --all        # skip prompts, install everything
#   ./install.sh --minimal    # skip prompts, install statusline only
#   ./install.sh --copy       # copy files instead of symlinking (no auto-upgrade)
#   ./install.sh --uninstall  # remove symlinks, restore backups if any
#   ./install.sh -h|--help    # show this help

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
BACKUP_DIR="$CLAUDE_DIR/backups/pre-install-$(date +%Y%m%dT%H%M%S)"

MODE="symlink"
PRESET=""   # "all" | "minimal" | ""

for arg in "$@"; do
  case "$arg" in
    --copy)      MODE="copy" ;;
    --uninstall) MODE="uninstall" ;;
    --symlink)   MODE="symlink" ;;
    --all)       PRESET="all" ;;
    --minimal)   PRESET="minimal" ;;
    -h|--help)
      grep -E '^# ' "$0" | sed 's/^# //; s/^#$//'
      exit 0
      ;;
    *)
      echo "error: unknown flag: $arg" >&2
      echo "usage: $0 [--all|--minimal|--symlink|--copy|--uninstall]" >&2
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Component definitions (Bash 3.2 compatible — no associative arrays).
# Parallel indexed arrays: COMP_NAME, COMP_LABEL, COMP_FILES.
# COMP_FILES entries are colon-separated "src:rel" pairs, space-separated.
# ---------------------------------------------------------------------------

# Index 0: Codex dispatch
COMP_NAME_0="codex"
COMP_LABEL_0="Codex dispatch (/dispatch-codex, scripts, auth-cache refresh)"
COMP_FILES_0="scripts/codex-dispatch.sh:scripts/codex-dispatch.sh scripts/codex-refresh-auth-cache.sh:scripts/codex-refresh-auth-cache.sh commands/dispatch-codex.md:commands/dispatch-codex.md"

# Index 1: Gemini dispatch
COMP_NAME_1="gemini"
COMP_LABEL_1="Gemini dispatch (/dispatch-gemini, scripts, model-cache refresh)"
COMP_FILES_1="scripts/gemini-dispatch.sh:scripts/gemini-dispatch.sh scripts/gemini-refresh-model-cache.sh:scripts/gemini-refresh-model-cache.sh commands/dispatch-gemini.md:commands/dispatch-gemini.md"

# Generic dispatcher + /dispatch command (always installed when codex or gemini is)
# These are added programmatically to ACTIVE_FILES in build_files_list() when any
# dispatch component is selected — no separate prompt needed.
DISPATCH_GENERIC_FILES="scripts/llm-dispatch.sh:scripts/llm-dispatch.sh commands/dispatch.md:commands/dispatch.md"

# Index 2: Budget check
COMP_NAME_2="budget"
COMP_LABEL_2="Budget check (/budget-check + auto-budget-check hook)"
COMP_FILES_2="commands/budget-check.md:commands/budget-check.md hooks/auto-budget-check.js:hooks/auto-budget-check.js"

# Index 3: Execute-at-reset
COMP_NAME_3="execute_at_reset"
COMP_LABEL_3="Execute-at-reset (/execute-at-reset command)"
COMP_FILES_3="commands/execute-at-reset.md:commands/execute-at-reset.md"

# Index 4: RuFlo routing
COMP_NAME_4="ruflo"
COMP_LABEL_4="RuFlo model routing (PreToolUse hook, inline keyword heuristics, no external CLI)"
COMP_FILES_4="hooks/ruflo-model-enforcer.js:hooks/ruflo-model-enforcer.js"

# Index 5: Log rotation
COMP_NAME_5="logrotate"
COMP_LABEL_5="Log rotation (rotate-logs.sh + weekly-maintenance hook)"
COMP_FILES_5="scripts/rotate-logs.sh:scripts/rotate-logs.sh hooks/weekly-maintenance.js:hooks/weekly-maintenance.js"

COMP_COUNT=6

# Statusline files — always installed (no prompt).
STATUSLINE_FILES="statusline.sh:statusline.sh"

# ---------------------------------------------------------------------------
# Prompt helper — asks "Install X? [Y/n]" and sets the answer variable.
# Usage: prompt_yes VARNAME "label"
# ---------------------------------------------------------------------------
prompt_yes() {
  local varname="$1"
  local label="$2"
  local answer
  printf "Install %s? [Y/n] " "$label"
  read -r answer </dev/tty
  case "${answer:-y}" in
    [Yy]*) eval "${varname}=1" ;;
    *)     eval "${varname}=0" ;;
  esac
}

# ---------------------------------------------------------------------------
# Decide which components to install based on preset / interactive prompts.
# Sets INSTALL_0 .. INSTALL_5 to 1 (yes) or 0 (no).
# ---------------------------------------------------------------------------
decide_components() {
  local i=0
  while [ "$i" -lt "$COMP_COUNT" ]; do
    eval "local label=\"\$COMP_LABEL_${i}\""
    case "$PRESET" in
      all)
        eval "INSTALL_${i}=1"
        ;;
      minimal)
        eval "INSTALL_${i}=0"
        ;;
      "")
        eval "prompt_yes INSTALL_${i} \"\$label\""
        ;;
    esac
    i=$(( i + 1 ))
  done
}

# ---------------------------------------------------------------------------
# Build the active FILES list from chosen components.
# ---------------------------------------------------------------------------
build_files_list() {
  # Always include statusline.
  ACTIVE_FILES="$STATUSLINE_FILES"

  local i=0
  while [ "$i" -lt "$COMP_COUNT" ]; do
    eval "local chosen=\$INSTALL_${i}"
    if [ "${chosen:-0}" -eq 1 ]; then
      eval "local cfiles=\"\$COMP_FILES_${i}\""
      ACTIVE_FILES="$ACTIVE_FILES $cfiles"
    fi
    i=$(( i + 1 ))
  done

  # Include generic dispatcher + /dispatch command whenever codex or gemini is selected.
  if [ "${INSTALL_0:-0}" -eq 1 ] || [ "${INSTALL_1:-0}" -eq 1 ]; then
    ACTIVE_FILES="$ACTIVE_FILES $DISPATCH_GENERIC_FILES"
  fi
}

# ---------------------------------------------------------------------------
# Dependency check.
# ---------------------------------------------------------------------------
check_deps() {
  local missing=()
  command -v jq     >/dev/null 2>&1 || missing+=("jq (brew install jq)")
  command -v node   >/dev/null 2>&1 || missing+=("node (brew install node)")
  command -v python3 >/dev/null 2>&1 || missing+=("python3")
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "warning: missing required dependencies:"
    for m in "${missing[@]}"; do echo "    - $m"; done
    echo "Install them and re-run ./install.sh"
    exit 1
  fi

  if ! command -v codex >/dev/null 2>&1; then
    echo "info: codex CLI not found — /dispatch-codex + Codex statusline row will be inactive."
    echo "  Install: brew install codex (requires ChatGPT Plus/Pro/Enterprise)"
  fi
  if ! command -v gemini >/dev/null 2>&1; then
    echo "info: gemini CLI not found — /dispatch-gemini + Gemini statusline row will be inactive."
    echo "  Install: npm install -g @google/gemini-cli, then run 'gemini' to OAuth"
  fi
}

# ---------------------------------------------------------------------------
# Install files from ACTIVE_FILES.
# ---------------------------------------------------------------------------
install_files() {
  echo "-> Installing to $CLAUDE_DIR (mode: $MODE)"

  mkdir -p "$CLAUDE_DIR/scripts" "$CLAUDE_DIR/commands" "$CLAUDE_DIR/hooks"

  local backed_up=0
  for entry in $ACTIVE_FILES; do
    local src="${entry%%:*}"
    local rel="${entry##*:}"
    local src_path="$REPO_DIR/$src"
    local tgt_path="$CLAUDE_DIR/$rel"

    # Back up if target exists and isn't already our symlink.
    if [ -e "$tgt_path" ] || [ -L "$tgt_path" ]; then
      if [ -L "$tgt_path" ] && [ "$(readlink "$tgt_path")" = "$src_path" ]; then
        : # already our symlink, skip backup
      else
        if [ "$backed_up" -eq 0 ]; then
          mkdir -p "$BACKUP_DIR"
          echo "-> Backing up existing files to $BACKUP_DIR"
          backed_up=1
        fi
        local backup_target="$BACKUP_DIR/$rel"
        mkdir -p "$(dirname "$backup_target")"
        mv "$tgt_path" "$backup_target"
      fi
    fi

    case "$MODE" in
      symlink) ln -sf "$src_path" "$tgt_path" ;;
      copy)    cp "$src_path" "$tgt_path" ;;
    esac
    echo "  ok $rel"
  done

  chmod +x "$CLAUDE_DIR/statusline.sh" "$CLAUDE_DIR/scripts/"*.sh 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Uninstall: walk the full set of all known files.
# ---------------------------------------------------------------------------
uninstall_files() {
  local all_files="$STATUSLINE_FILES $COMP_FILES_0 $COMP_FILES_1 $COMP_FILES_2 $COMP_FILES_3 $COMP_FILES_4 $COMP_FILES_5 $DISPATCH_GENERIC_FILES"
  echo "-> Uninstalling from $CLAUDE_DIR"
  for entry in $all_files; do
    local rel="${entry##*:}"
    local tgt_path="$CLAUDE_DIR/$rel"
    if [ -L "$tgt_path" ]; then
      rm "$tgt_path"
      echo "  removed symlink: $rel"
    fi
  done

  local latest
  latest="$(ls -1t "$CLAUDE_DIR/backups" 2>/dev/null | grep -m1 '^pre-install-' || true)"
  if [ -n "$latest" ]; then
    echo ""
    echo "info: found backup: $CLAUDE_DIR/backups/$latest"
    echo "  Restore manually with: cp -R \"$CLAUDE_DIR/backups/$latest/\"* \"$CLAUDE_DIR/\""
  fi
}

# ---------------------------------------------------------------------------
# Model wizard — builds ~/.claude/orchestrator-models.json interactively.
# Only runs when the codex or gemini dispatch component was installed.
# Bash 3.2 compatible: no associative arrays. Accumulates JSON fragments into
# a temp file, then merges with jq at the end.
# ---------------------------------------------------------------------------

# Autodetect a binary path; prints the path or empty string.
_autodetect_bin() {
  local bin="$1"
  command -v "$bin" 2>/dev/null || true
}

# Read a value from stdin with a default. Reads from /dev/tty.
# Usage: _prompt_field "Prompt text" "default" VARNAME
_prompt_field() {
  local prompt="$1"
  local default="$2"
  local varname="$3"
  local answer
  if [ -n "$default" ] && [ "$default" != "-" ]; then
    printf "%s [%s]: " "$prompt" "$default"
  else
    printf "%s: " "$prompt"
  fi
  read -r answer </dev/tty
  if [ -z "$answer" ] && [ -n "$default" ] && [ "$default" != "-" ]; then
    answer="$default"
  fi
  eval "${varname}=\"\$answer\""
}

# Emit one JSON model object from args. Each field is passed as a positional.
# $1=id $2=display_name $3=model_label $4=command $5=args_template
# $6=rate_limit_5h (or empty) $7=color $8=last_file
_emit_model_json() {
  local mid="$1" disp="$2" mlabel="$3" mcmd="$4" margs="$5"
  local mcap="$6" mcol="$7" mlast="$8"
  python3 - <<PY
import json
obj = {
    "id":            "$mid",
    "display_name":  "$disp",
    "model_label":   "$mlabel",
    "command":       "$mcmd",
    "args_template": "$margs",
    "color":         "$mcol",
    "last_file":     "$mlast",
}
cap = "$mcap"
if cap.strip().isdigit():
    obj["rate_limit_5h"] = int(cap)
print(json.dumps(obj, indent=2))
PY
}

run_model_wizard() {
  # Only run when at least one dispatch component was installed.
  if [ "${INSTALL_0:-0}" -eq 0 ] && [ "${INSTALL_1:-0}" -eq 0 ]; then
    return
  fi

  echo ""
  echo "─────────────────────────────────────────"
  echo "Model registry: $HOME/.claude/orchestrator-models.json"
  echo "─────────────────────────────────────────"
  echo "Models the statusline + /dispatch will know about."
  echo "Press Enter to accept defaults. Leave a field blank to skip a model."
  echo ""

  REGISTRY_FILE="$HOME/.claude/orchestrator-models.json"
  MODELS_TMP="$(mktemp /tmp/orchestrator-models-XXXXXX.txt)"
  trap 'rm -f "$MODELS_TMP"' EXIT

  # Back up existing registry if present
  if [ -f "$REGISTRY_FILE" ]; then
    local bk_dir="$BACKUP_DIR"
    mkdir -p "$bk_dir"
    cp "$REGISTRY_FILE" "$bk_dir/orchestrator-models.json"
    echo "info: backed up existing registry to $bk_dir/orchestrator-models.json"
  fi

  # ── Codex ────────────────────────────────────────────────────────────────
  codex_default_bin="$(_autodetect_bin codex)"
  local add_codex
  printf "Add codex? [Y/n]: "; read -r add_codex </dev/tty
  case "${add_codex:-y}" in
    [Yy]*)
      _prompt_field "  Path to codex binary" "${codex_default_bin:-codex}" codex_bin
      _prompt_field "  Display name"         "codex plus"                   codex_disp
      _prompt_field "  Model label"          "gpt-5.4"                      codex_mlabel
      _prompt_field "  5h rate limit"        "50"                           codex_cap
      _emit_model_json \
        "codex" "$codex_disp" "$codex_mlabel" \
        "$codex_bin" \
        "exec --dangerously-bypass-approvals-and-sandbox" \
        "$codex_cap" "#10a37f" "~/.claude/codex-last.json" \
        >> "$MODELS_TMP"
      ;;
  esac

  # ── Gemini ───────────────────────────────────────────────────────────────
  gemini_default_bin="$(_autodetect_bin gemini)"
  local add_gemini
  printf "Add gemini? [Y/n]: "; read -r add_gemini </dev/tty
  case "${add_gemini:-y}" in
    [Yy]*)
      _prompt_field "  Path to gemini binary" "${gemini_default_bin:-gemini}" gemini_bin
      _prompt_field "  Display name"          "gemini pro"                    gemini_disp
      _prompt_field "  Model label"           "3.1-pro-preview"               gemini_mlabel
      _prompt_field "  5h rate limit"         "100"                           gemini_cap
      _emit_model_json \
        "gemini" "$gemini_disp" "$gemini_mlabel" \
        "$gemini_bin" \
        "--yolo -m gemini-3.1-pro-preview -p \"\$(cat {prompt_file})\"" \
        "$gemini_cap" "#9c5df7" "~/.claude/gemini-last.json" \
        >> "$MODELS_TMP"
      ;;
  esac

  # ── Additional models loop ───────────────────────────────────────────────
  while true; do
    local add_more
    printf "Add another model? [y/N]: "; read -r add_more </dev/tty
    case "${add_more:-n}" in
      [Yy]*) ;;
      *) break ;;
    esac

    local xid xdisp xlabel xcmd xargs xcap xcol xlast
    _prompt_field "  Model ID (e.g. qwen, ollama, llm)" "" xid
    [ -z "$xid" ] && echo "  (skipped — no ID given)" && continue

    xbin_default="$(_autodetect_bin "$xid")"
    _prompt_field "  Path to binary" "${xbin_default:-$xid}" xcmd
    _prompt_field "  Display name"   "$xid"                   xdisp
    _prompt_field "  Model label"    ""                        xlabel
    echo "  Args template — use {prompt_file} for the prompt path."
    echo "  Example for 'llm': run {prompt_file}"
    echo "  Example for 'ollama': run llama3 -f {prompt_file}"
    _prompt_field "  Args template" "{prompt_file}" xargs
    _prompt_field "  5h rate limit (blank = no bar)" "" xcap
    _prompt_field "  Color (#rrggbb, blank = white)"  "" xcol
    [ -z "$xcol" ] && xcol="#e6e6e6"
    xlast="~/.claude/${xid}-last.json"
    _emit_model_json \
      "$xid" "$xdisp" "$xlabel" "$xcmd" "$xargs" "$xcap" "$xcol" "$xlast" \
      >> "$MODELS_TMP"
  done

  # ── Merge fragments into final registry ─────────────────────────────────
  if [ -s "$MODELS_TMP" ]; then
    # Wrap each top-level JSON object in an array, deduplicate by id (last wins),
    # then emit the registry structure.
    jq -s 'map(.) | unique_by(.id) | {version: 1, models: .}' "$MODELS_TMP" \
      > "$REGISTRY_FILE"
    echo ""
    echo "-> Wrote model registry: $REGISTRY_FILE"
    jq -r '.models[] | "   \(.id)  \(.command)"' "$REGISTRY_FILE" 2>/dev/null || true
  else
    echo "-> No models added; skipping registry write."
  fi

  rm -f "$MODELS_TMP"
}

# ---------------------------------------------------------------------------
# Settings hint — only print blocks for what was actually installed.
# ---------------------------------------------------------------------------
print_settings_hint() {
  cat <<'HEADER'

----------------------------------------------------------------
Next step: merge this into ~/.claude/settings.json
----------------------------------------------------------------

Statusline (always):
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh",
    "padding": 2,
    "refreshInterval": 10
  }
HEADER

  # Collect hook lines for components that were installed.
  local user_prompt_hooks=""
  local session_start_hooks=""
  local pre_tool_hooks=""

  if [ "${INSTALL_2:-0}" -eq 1 ]; then
    user_prompt_hooks='          { "type": "command", "command": "node ~/.claude/hooks/auto-budget-check.js" }'
  fi
  if [ "${INSTALL_5:-0}" -eq 1 ]; then
    session_start_hooks='          { "type": "command", "command": "node ~/.claude/hooks/weekly-maintenance.js" }'
  fi
  if [ "${INSTALL_4:-0}" -eq 1 ]; then
    pre_tool_hooks='          { "type": "command", "command": "node ~/.claude/hooks/ruflo-model-enforcer.js" }'
  fi

  # Only print the hooks block if at least one hook was installed.
  local has_hooks=0
  [ -n "$user_prompt_hooks" ]  && has_hooks=1
  [ -n "$session_start_hooks" ] && has_hooks=1
  [ -n "$pre_tool_hooks" ]     && has_hooks=1

  if [ "$has_hooks" -eq 1 ]; then
    echo ""
    echo "Hooks (merge into existing \"hooks\" section if present):"
    echo "  \"hooks\": {"

    if [ -n "$user_prompt_hooks" ]; then
      cat <<BLOCK
    "UserPromptSubmit": [
      {
        "hooks": [
$user_prompt_hooks
        ]
      }
    ],
BLOCK
    fi

    if [ -n "$pre_tool_hooks" ]; then
      cat <<BLOCK
    "PreToolUse": [
      {
        "matcher": "Agent",
        "hooks": [
$pre_tool_hooks
        ]
      }
    ],
BLOCK
    fi

    if [ -n "$session_start_hooks" ]; then
      cat <<BLOCK
    "SessionStart": [
      {
        "hooks": [
$session_start_hooks
        ]
      }
    ]
BLOCK
    fi

    echo "  }"
  fi

  cat <<'FOOTER'

See examples/settings.json for a complete snippet.

If Claude Code is already running, restart it to pick up the new statusline
and hook registrations.
----------------------------------------------------------------
FOOTER
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "$MODE" in
  symlink|copy)
    check_deps

    echo ""
    echo "LLM Orchestrator + Status Line installer"
    echo "The statusline is always installed. Choose which optional components to add."
    echo ""

    decide_components
    build_files_list
    install_files
    run_model_wizard
    print_settings_hint
    echo ""
    echo "Install complete."
    ;;
  uninstall)
    uninstall_files
    echo ""
    echo "Uninstall complete. Don't forget to remove the statusLine / hooks"
    echo "sections from ~/.claude/settings.json."
    ;;
esac
