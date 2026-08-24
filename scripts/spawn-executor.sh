#!/bin/zsh
# spawn-executor.sh — open a named Warp tab running an executor session.
#
# The manager session writes a self-contained handoff spec to disk, then calls
# this to open a dedicated tab that executes it. The manager stays free for
# planning, review and orchestration instead of being blocked on the build.
#
# Usage: spawn-executor.sh <task-slug> [spec-file] [cwd] [model]
#   task-slug : tab + session name, e.g. "scraper-api-build"
#   spec-file : handoff spec (default: ~/.claude/handoffs/<slug>.md, must exist)
#   cwd       : working dir for the executor (default: $HOME)
#   model      : a Claude tier ('opus', 'opus[1m]', 'sonnet', 'haiku', ...) OR
#                'codex' / 'agy' to run that CLI instead of Claude.
#                Default: $EXECUTOR_MODEL, else 'opus'.
#
# Env:
#   EXECUTOR_MODEL   default model when the 4th arg is omitted (default: opus)
#   EXECUTOR_EFFORT  --effort passed to Claude engines (default: high)
#
# Requires: Warp (macOS) for the tab mechanism; node for trust pre-seeding.
# The 'codex' and 'agy' engines are OPTIONAL — they need those CLIs on $PATH.
set -euo pipefail

SLUG="${1:?usage: spawn-executor.sh <task-slug> [spec-file] [cwd] [model]}"
SPEC="${2:-$HOME/.claude/handoffs/$SLUG.md}"
DIR="${3:-$HOME}"
MODEL="${4:-${EXECUTOR_MODEL:-opus}}"
EFFORT="${EXECUTOR_EFFORT:-high}"

[[ -f "$SPEC" ]] || { echo "spec not found: $SPEC" >&2; exit 1; }
[[ -d "$DIR" ]]  || { echo "cwd not found: $DIR" >&2; exit 1; }

WARP_TABS="$HOME/.warp/tab_configs"
if [[ ! -d "$HOME/.warp" ]]; then
  echo "error: $HOME/.warp not found — this script drives Warp tabs." >&2
  echo "  Install Warp (https://warp.dev) and launch it once, or run the spec" >&2
  echo "  directly:  claude --model $MODEL \"Read $SPEC and execute it fully\"" >&2
  exit 1
fi
mkdir -p "$WARP_TABS"

case "$MODEL" in
  codex|agy)
    command -v "$MODEL" >/dev/null 2>&1 || {
      echo "error: '$MODEL' CLI not found on \$PATH — that engine is optional." >&2
      exit 1
    }
    ;;
esac

# Pre-seed workspace trust for the executor cwd so the session never blocks
# on the "Do you trust this folder?" dialog (atomic temp+rename write).
if [[ -f "$HOME/.claude.json" ]] && command -v node >/dev/null 2>&1; then
  node -e '
const fs=require("fs"),os=require("os");
const f=os.homedir()+"/.claude.json";
let j;
try { j=JSON.parse(fs.readFileSync(f,"utf8")); } catch(e) { process.exit(0); }
j.projects=j.projects||{};
const dir=process.argv[1];
j.projects[dir]=j.projects[dir]||{};
if(!j.projects[dir].hasTrustDialogAccepted){
  j.projects[dir].hasTrustDialogAccepted=true;
  j.projects[dir].hasCompletedProjectOnboarding=true;
  const t=f+".tmp-spawn-"+process.pid;
  fs.writeFileSync(t,JSON.stringify(j,null,2));
  fs.renameSync(t,f);
  console.log("trust seeded for "+dir);
}
' "$DIR"
fi

# printf, not echo: echo's trailing newline is non-alphanumeric and tr would
# turn it into a stray trailing underscore in the tab-config filename.
STEM="exec_$(printf '%s' "$SLUG" | tr -c 'a-zA-Z0-9' '_')"
RUNNER="$HOME/.claude/handoffs/$SLUG.run.sh"
mkdir -p "$(dirname "$RUNNER")"

case "$MODEL" in
  codex)
    # codex/agy get the spec at boot and cannot be steered afterwards.
    EXEC_LINE="codex exec --dangerously-bypass-approvals-and-sandbox \"\$(cat '$SPEC')\""
    ;;
  agy)
    EXEC_LINE="agy --dangerously-skip-permissions -p \"\$(cat '$SPEC')\""
    ;;
  *)
    # Claude engines boot interactive and are kicked off by the manager over
    # SendMessage, so the only seeded input is the purple-prompt convention.
    EXEC_LINE="exec claude --model '$MODEL' --effort '$EFFORT' -n '$SLUG' \"/color purple\""
    ;;
esac

cat > "$RUNNER" <<EOF
#!/bin/zsh
print -P "%F{magenta}\\u2588\\u2588 EXECUTOR \\u00b7 $SLUG \\u00b7 $MODEL \\u00b7 spawned by manager session \\u2588\\u2588%f"
cd "$DIR"
$EXEC_LINE
rc=\$?
print -P "%F{magenta}\\u2588\\u2588 EXECUTOR DONE \\u00b7 $SLUG \\u00b7 exit \$rc \\u00b7 tab stays open for inspection \\u2588\\u2588%f"
exec zsh
EOF
chmod +x "$RUNNER"

cat > "$WARP_TABS/$STEM.toml" <<EOF
name = "$SLUG"
title = "$SLUG"
color = "magenta"

[[panes]]
id = "executor"
type = "terminal"
commands = ["exec '$RUNNER'"]
is_focused = true
EOF

open "warp://tab_config/$STEM"
echo "spawned: tab '$SLUG' (model $MODEL, cwd $DIR, spec $SPEC)"
