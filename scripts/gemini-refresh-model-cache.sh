#!/usr/bin/env bash
# Refresh the cached Gemini active model identifier.
#
# Gemini CLI does not print its active model to stdout on normal runs, so
# the only reliable way to know which model is in use is to ask it directly.
# That round-trip takes ~9 seconds — far too slow to run on every statusline
# render. Instead we cache the result and refresh on a long interval (daily)
# or on demand.
#
# Writes: ~/.claude/gemini-model-cache.txt  (single line, full model ID)
#
# Exit codes:
#   0 = cache refreshed
#   1 = gemini CLI unavailable or probe failed
#
# Usage: gemini-refresh-model-cache.sh [--quiet]

set -uo pipefail

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

CACHE_FILE="$HOME/.claude/gemini-model-cache.txt"

if ! command -v gemini >/dev/null 2>&1; then
  [ "$QUIET" -eq 0 ] && echo "error: gemini CLI not found" >&2
  exit 1
fi

# The cache reflects the model we're configured to DISPATCH with, not what
# Gemini self-reports. (Self-reporting is unreliable — when you force
# gemini-2.5-pro with -m, the model will still sometimes claim to be
# gemini-1.5-pro-001 because of its training.) What matters for the statusline
# is what we're actually requesting via dispatch.
GEMINI_DISPATCH_MODEL="${GEMINI_DISPATCH_MODEL:-gemini-3.1-pro-preview}"

# Verify the model actually works on this account before caching. A quick
# 1-token probe — 404 means the account doesn't have access.
PROBE_ERR="$(gemini --yolo -m "$GEMINI_DISPATCH_MODEL" -p "ok" 2>&1 | grep -E 'code: 4[0-9]{2}' | head -1)"
if [ -n "$PROBE_ERR" ]; then
  [ "$QUIET" -eq 0 ] && echo "error: model $GEMINI_DISPATCH_MODEL rejected ($PROBE_ERR)" >&2
  exit 1
fi

printf "%s\n" "$GEMINI_DISPATCH_MODEL" > "$CACHE_FILE"
[ "$QUIET" -eq 0 ] && echo "cached: $GEMINI_DISPATCH_MODEL -> $CACHE_FILE"
exit 0
