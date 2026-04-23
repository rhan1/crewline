#!/usr/bin/env bash
# Delete dispatch logs older than 30 days. Keeps ~/.claude/logs/ from
# growing without bound as Codex and Gemini dispatches pile up.
#
# Usage: rotate-logs.sh [--days N] [--quiet]
#
# Exit 0 always (non-critical maintenance — don't fail session start).

LOG_DIR="$HOME/.claude/logs"
DAYS=30
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    *) shift ;;
  esac
done

[ -d "$LOG_DIR" ] || exit 0

# Count then delete. Patterns scope the deletion to dispatch logs only —
# no unrelated files get touched.
COUNT=0
for pattern in 'codex-*.log' 'gemini-*.log'; do
  while IFS= read -r f; do
    [ -n "$f" ] && rm -f "$f" && COUNT=$((COUNT + 1))
  done < <(find "$LOG_DIR" -maxdepth 1 -name "$pattern" -mtime "+${DAYS}" -type f 2>/dev/null)
done

if [ "$QUIET" -eq 0 ] && [ "$COUNT" -gt 0 ]; then
  echo "rotated: $COUNT log(s) older than ${DAYS}d deleted from $LOG_DIR"
fi

exit 0
