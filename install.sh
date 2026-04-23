#!/usr/bin/env bash
# Installer for LLM Orchestrator + Status Line.
#
# Symlinks this repo's files into ~/.claude/ so `git pull` upgrades everything.
# Backs up any existing targets to ~/.claude/backups/pre-install-<ts>/ first.
#
# Usage:
#   ./install.sh              # symlink (recommended — git pull upgrades)
#   ./install.sh --copy       # copy files instead (no auto-upgrade)
#   ./install.sh --uninstall  # remove symlinks, restore backups if any

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
BACKUP_DIR="$CLAUDE_DIR/backups/pre-install-$(date +%Y%m%dT%H%M%S)"

MODE="symlink"
case "${1:-}" in
  --copy)      MODE="copy" ;;
  --uninstall) MODE="uninstall" ;;
  --symlink|"") MODE="symlink" ;;
  -h|--help)
    grep -E '^# ' "$0" | sed 's/^# //; s/^#$//'
    exit 0
    ;;
  *)
    echo "error: unknown flag: $1" >&2
    echo "usage: $0 [--symlink|--copy|--uninstall]" >&2
    exit 2
    ;;
esac

# Files we own (source path → target path relative to ~/.claude)
FILES=(
  "statusline.sh:statusline.sh"
  "scripts/codex-dispatch.sh:scripts/codex-dispatch.sh"
  "scripts/codex-refresh-auth-cache.sh:scripts/codex-refresh-auth-cache.sh"
  "scripts/gemini-dispatch.sh:scripts/gemini-dispatch.sh"
  "scripts/gemini-refresh-model-cache.sh:scripts/gemini-refresh-model-cache.sh"
  "scripts/rotate-logs.sh:scripts/rotate-logs.sh"
  "commands/dispatch-codex.md:commands/dispatch-codex.md"
  "commands/dispatch-gemini.md:commands/dispatch-gemini.md"
  "commands/budget-check.md:commands/budget-check.md"
  "commands/execute-at-reset.md:commands/execute-at-reset.md"
  "hooks/auto-budget-check.js:hooks/auto-budget-check.js"
  "hooks/weekly-maintenance.js:hooks/weekly-maintenance.js"
)

check_deps() {
  local missing=()
  command -v jq >/dev/null 2>&1 || missing+=("jq (brew install jq)")
  command -v node >/dev/null 2>&1 || missing+=("node (brew install node)")
  command -v python3 >/dev/null 2>&1 || missing+=("python3")
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "⚠️  Missing required dependencies:"
    for m in "${missing[@]}"; do echo "    - $m"; done
    echo "Install them and re-run ./install.sh"
    exit 1
  fi

  # Optional — informational only
  if ! command -v codex >/dev/null 2>&1; then
    echo "ℹ️  codex CLI not found — /dispatch-codex + Codex statusline row will be inactive."
    echo "   Install: brew install codex (requires ChatGPT Plus/Pro/Enterprise)"
  fi
  if ! command -v gemini >/dev/null 2>&1; then
    echo "ℹ️  gemini CLI not found — /dispatch-gemini + Gemini statusline row will be inactive."
    echo "   Install: npm install -g @google/gemini-cli, then run 'gemini' to OAuth"
  fi
}

install_files() {
  echo "→ Installing to $CLAUDE_DIR (mode: $MODE)"

  # Make sure parent dirs exist
  mkdir -p "$CLAUDE_DIR/scripts" "$CLAUDE_DIR/commands" "$CLAUDE_DIR/hooks"

  local backed_up=0
  for entry in "${FILES[@]}"; do
    local src="${entry%%:*}"
    local rel="${entry##*:}"
    local src_path="$REPO_DIR/$src"
    local tgt_path="$CLAUDE_DIR/$rel"

    # Back up if target exists and isn't already our symlink
    if [ -e "$tgt_path" ] || [ -L "$tgt_path" ]; then
      if [ -L "$tgt_path" ] && [ "$(readlink "$tgt_path")" = "$src_path" ]; then
        : # already our symlink, skip backup
      else
        if [ "$backed_up" -eq 0 ]; then
          mkdir -p "$BACKUP_DIR"
          echo "→ Backing up existing files to $BACKUP_DIR"
          backed_up=1
        fi
        local backup_target="$BACKUP_DIR/$rel"
        mkdir -p "$(dirname "$backup_target")"
        mv "$tgt_path" "$backup_target"
      fi
    fi

    # Install
    case "$MODE" in
      symlink) ln -sf "$src_path" "$tgt_path" ;;
      copy)    cp "$src_path" "$tgt_path" ;;
    esac
    echo "  ✓ $rel"
  done

  # Ensure shell scripts are executable
  chmod +x "$CLAUDE_DIR/statusline.sh" "$CLAUDE_DIR/scripts/"*.sh 2>/dev/null || true
}

uninstall_files() {
  echo "→ Uninstalling from $CLAUDE_DIR"
  for entry in "${FILES[@]}"; do
    local rel="${entry##*:}"
    local tgt_path="$CLAUDE_DIR/$rel"
    if [ -L "$tgt_path" ]; then
      rm "$tgt_path"
      echo "  ✓ removed symlink: $rel"
    fi
  done

  # Look for the most recent backup and offer to restore
  local latest
  latest="$(ls -1t "$CLAUDE_DIR/backups" 2>/dev/null | grep -m1 '^pre-install-' || true)"
  if [ -n "$latest" ]; then
    echo ""
    echo "ℹ️  Found backup: $CLAUDE_DIR/backups/$latest"
    echo "   Restore manually with: cp -R \"$CLAUDE_DIR/backups/$latest/\"* \"$CLAUDE_DIR/\""
  fi
}

print_settings_hint() {
  cat <<'HINT'

────────────────────────────────────────────────────────────────
Next step: merge this into ~/.claude/settings.json
────────────────────────────────────────────────────────────────

Statusline:
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh",
    "padding": 2,
    "refreshInterval": 10
  }

Hooks (merge into existing "hooks" section if present):
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          { "type": "command", "command": "node ~/.claude/hooks/auto-budget-check.js" }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "node ~/.claude/hooks/weekly-maintenance.js" }
        ]
      }
    ]
  }

See examples/settings.json for a complete snippet.

If Claude Code is already running, restart it to pick up the new statusline
and hook registrations.
────────────────────────────────────────────────────────────────
HINT
}

case "$MODE" in
  symlink|copy)
    check_deps
    install_files
    print_settings_hint
    echo ""
    echo "✅ Install complete."
    ;;
  uninstall)
    uninstall_files
    echo ""
    echo "✅ Uninstall complete. Don't forget to remove the statusLine / hooks"
    echo "   sections from ~/.claude/settings.json."
    ;;
esac
