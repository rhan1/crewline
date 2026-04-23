#!/usr/bin/env bash
# Claude Code status line — shows Claude context/rate-limits, Codex, and
# Gemini dispatch activity on up to three rows. Writes a session-state cache
# to ~/.claude/.session-state.json that the /budget-check and /execute-at-reset
# slash commands and the auto-budget-check hook read.

input=$(cat)

# ── Write session state cache so slash commands can read current rate-limit
# state without re-plumbing Claude Code's internal session info. Statusline
# already gets this every ~10s via stdin, so it's the cheapest capture point.
SESSION_STATE="$HOME/.claude/.session-state.json"
echo "$input" | jq --arg ts "$(date -u +%s)" '{
  timestamp: ($ts | tonumber),
  model: (.model.display_name // null),
  context_window: (.context_window // {}),
  rate_limits: (.rate_limits // {}),
  cost: (.cost // {}),
  cwd: (.workspace.current_dir // .cwd // null)
}' > "$SESSION_STATE" 2>/dev/null || true

# ── Colors (truecolor — bypasses terminal theme remapping) ────────────────────
RESET='\033[0m'
DIM='\033[2m'
BOLD='\033[1m'
GRAY='\033[38;2;110;120;130m'
WHITE='\033[38;2;230;230;230m'
CYAN='\033[38;2;100;210;230m'
GREEN='\033[38;2;80;220;120m'
YELLOW='\033[38;2;240;200;80m'
RED='\033[38;2;230;90;90m'
ORANGE='\033[38;2;230;150;60m'
SILVER='\033[38;2;200;210;220m'
CODEX_GREEN='\033[38;2;16;163;127m'
GEMINI_PURPLE='\033[38;2;156;93;247m'

SEP="${GRAY} | ${RESET}"

# ── Helpers ───────────────────────────────────────────────────────────────────
pct_color() {
  local p=$1
  [ "$p" -lt 0 ] && p=0
  [ "$p" -gt 100 ] && p=100
  # Smooth RGB gradient: green (80,220,120) → yellow (240,200,80) → red (230,90,90)
  local r g b
  if [ "$p" -le 50 ]; then
    r=$(awk "BEGIN{printf \"%d\", 80  + ($p/50)*(240-80)  + 0.5}")
    g=$(awk "BEGIN{printf \"%d\", 220 + ($p/50)*(200-220) + 0.5}")
    b=$(awk "BEGIN{printf \"%d\", 120 + ($p/50)*(80-120)  + 0.5}")
  else
    local x=$((p - 50))
    r=$(awk "BEGIN{printf \"%d\", 240 + ($x/50)*(230-240) + 0.5}")
    g=$(awk "BEGIN{printf \"%d\", 200 + ($x/50)*(90-200)  + 0.5}")
    b=$(awk "BEGIN{printf \"%d\", 80  + ($x/50)*(90-80)   + 0.5}")
  fi
  echo "\033[38;2;${r};${g};${b}m"
}

# make_bar <percent 0-100> [width=10] — gradient bar with 1/8th resolution
make_bar() {
  local pct=$1
  local width=${2:-10}
  local max_eighths=$((width * 8))
  local total_eighths
  total_eighths=$(awk "BEGIN{printf \"%d\", ($pct/100)*$max_eighths + 0.5}")
  [ "$total_eighths" -lt 0 ] && total_eighths=0
  [ "$total_eighths" -gt "$max_eighths" ] && total_eighths=$max_eighths
  [ "$pct" -gt 0 ] && [ "$total_eighths" -eq 0 ] && total_eighths=1

  local full=$((total_eighths / 8))
  local rem=$((total_eighths % 8))
  local empty=$((width - full))
  [ "$rem" -gt 0 ] && empty=$((empty - 1))

  local partials=("" "▏" "▎" "▍" "▌" "▋" "▊" "▉")
  local color
  color=$(pct_color "$pct")

  local bar=""
  local i
  for ((i=0; i<full; i++));  do bar+="█"; done
  [ "$rem" -gt 0 ] && bar+="${partials[$rem]}"
  for ((i=0; i<empty; i++)); do bar+="░"; done
  printf "${GRAY}[${color}%s${GRAY}]${RESET}" "$bar"
}

# Format time until a reset target as e.g. "1h 49m". Accepts either a Unix
# epoch integer (what Claude Code sends via stdin) or an ISO-8601 string.
# Optional 2nd arg: window seconds. If the target is in the past, advance
# it by the window size until it's in the future. This handles CC's staleness
# where resets_at lags ~minutes behind when the rolling window actually rolls.
time_until() {
  local v=$1
  local window=${2:-0}
  [ -z "$v" ] || [ "$v" = "null" ] && return
  local target_sec
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    target_sec=$v
  else
    local clean="$v"
    case "$clean" in
      *.*Z)  clean="${clean%.*}Z" ;;
      *.*)   clean="${clean%.*}Z" ;;
      *Z)    : ;;
      *)     clean="${clean}Z" ;;
    esac
    target_sec=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$clean" +%s 2>/dev/null)
    [ -z "$target_sec" ] && return
  fi
  local now_sec diff_sec
  now_sec=$(date -u +%s)
  diff_sec=$((target_sec - now_sec))
  if [ "$diff_sec" -le 0 ] && [ "$window" -gt 0 ]; then
    while [ "$diff_sec" -le 0 ]; do
      target_sec=$((target_sec + window))
      diff_sec=$((target_sec - now_sec))
    done
  fi
  [ "$diff_sec" -le 0 ] && return
  local d=$((diff_sec / 86400))
  local h=$(((diff_sec % 86400) / 3600))
  local m=$(((diff_sec % 3600) / 60))
  local s=$((diff_sec % 60))
  if   [ "$d" -gt 0 ]; then printf "%dd %dh" "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf "%dh %dm" "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf "%dm" "$m"
  else printf "%ds" "$s"
  fi
}

# Format a reset target as local HH:MM. Accepts the same input shapes as
# time_until (Unix epoch or ISO-8601). Rolls the target forward by `window`
# when the source timestamp is stale (Claude Code's resets_at can lag the
# actual rolling window).
reset_clock() {
  local v=$1
  local window=${2:-0}
  [ -z "$v" ] || [ "$v" = "null" ] && return
  local target_sec
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    target_sec=$v
  else
    local clean="$v"
    case "$clean" in
      *.*Z)  clean="${clean%.*}Z" ;;
      *.*)   clean="${clean%.*}Z" ;;
      *Z)    : ;;
      *)     clean="${clean}Z" ;;
    esac
    target_sec=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$clean" +%s 2>/dev/null)
    [ -z "$target_sec" ] && return
  fi
  local now_sec
  now_sec=$(date -u +%s)
  if [ "$((target_sec - now_sec))" -le 0 ] && [ "$window" -gt 0 ]; then
    while [ "$((target_sec - now_sec))" -le 0 ]; do
      target_sec=$((target_sec + window))
    done
  fi
  date -j -f "%s" "$target_sec" "+%H:%M" 2>/dev/null
}

# ── Model ─────────────────────────────────────────────────────────────────────
model_name=$(echo "$input" | jq -r '.model.display_name // "Unknown"')
model_part="${ORANGE}${BOLD}${model_name}${RESET}"

# ── Context usage + bar (+ auto-compact warning at 80%) ───────────────────────
ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
ctx_int=$(printf '%.0f' "$ctx_pct")
ctx_bar=$(make_bar "$ctx_int" 10)
ctx_color=$(pct_color "$ctx_int")
if [ "$ctx_int" -ge 80 ]; then
  ctx_part="${ctx_bar} ${ctx_color}${ctx_int}%${RESET} ${RED}${BOLD}⚠${RESET}"
else
  ctx_part="${ctx_bar} ${WHITE}${ctx_int}%${RESET}"
fi

# ── 5-hour rate limit + bar + reset countdown ─────────────────────────────────
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
if [ -n "$five_pct" ]; then
  five_int=$(printf '%.0f' "$five_pct")
  five_bar=$(make_bar "$five_int" 10)
  five_color=$(pct_color "$five_int")
  five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
  five_eta=$(time_until "$five_reset" 18000)
  five_part="${five_bar} ${DIM}5h:${RESET}${five_color}${five_int}%${RESET}"
  if [ -n "$five_eta" ]; then
    five_clock=$(reset_clock "$five_reset" 18000)
    if [ -n "$five_clock" ]; then
      five_part="${five_part} ${DIM}(${five_eta} - ${five_clock})${RESET}"
    else
      five_part="${five_part} ${DIM}(${five_eta})${RESET}"
    fi
  fi
else
  five_part=""
fi

# ── Weekly rate limit + bar + reset countdown ────────────────────────────────
seven_pct=$(echo "$input" | jq -r '
  .rate_limits.weekly.used_percentage //
  .rate_limits.seven_day.used_percentage //
  empty
')
if [ -n "$seven_pct" ]; then
  seven_int=$(printf '%.0f' "$seven_pct")
  seven_bar=$(make_bar "$seven_int" 10)
  seven_color=$(pct_color "$seven_int")
  seven_reset=$(echo "$input" | jq -r '
    .rate_limits.weekly.resets_at //
    .rate_limits.seven_day.resets_at //
    empty
  ')
  seven_eta=$(time_until "$seven_reset" 604800)
  seven_part="${seven_bar} ${DIM}7d:${RESET}${seven_color}${seven_int}%${RESET}"
  if [ -n "$seven_eta" ]; then
    seven_clock=$(reset_clock "$seven_reset" 604800)
    if [ -n "$seven_clock" ]; then
      seven_part="${seven_part} ${DIM}(${seven_eta} - ${seven_clock})${RESET}"
    else
      seven_part="${seven_part} ${DIM}(${seven_eta})${RESET}"
    fi
  fi
else
  seven_part=""
fi

# ── Cache hit % + savings $ ──────────────────────────────────────────────────
cache_read=$(echo "$input" | jq -r '
  .context_window.cache_read_tokens //
  .context_window.cache_read_input_tokens //
  .usage.cache_read_input_tokens //
  0
')
input_total=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
cache_part=""
if [ "$input_total" -gt 0 ] && [ "$cache_read" -gt 0 ]; then
  cache_pct=$(awk "BEGIN{printf \"%d\", ($cache_read/$input_total)*100 + 0.5}")
  [ "$cache_pct" -gt 100 ] && cache_pct=100
  if   [ "$cache_pct" -ge 70 ]; then cache_color="${GREEN}"
  elif [ "$cache_pct" -ge 40 ]; then cache_color="${YELLOW}"
  else cache_color="${DIM}${WHITE}"
  fi
  # Savings: cache reads are ~90% cheaper than full input. Price by model tier:
  # Opus $15/1M input, Sonnet $3/1M, Haiku $0.80/1M → savings = cache * price * 0.9
  case "$model_name" in
    *[Oo]pus*)   in_price=15.00 ;;
    *[Ss]onnet*) in_price=3.00  ;;
    *[Hh]aiku*)  in_price=0.80  ;;
    *)           in_price=3.00  ;;
  esac
  saved=$(awk "BEGIN{printf \"%.2f\", ($cache_read/1000000)*$in_price*0.9}")
  cache_part="${DIM}cache:${RESET}${cache_color}${cache_pct}%${RESET} ${DIM}(saved \$${saved})${RESET}"
fi

# ── Cost ──────────────────────────────────────────────────────────────────────
cost_usd=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
cost=$(awk "BEGIN{printf \"%.2f\", $cost_usd}")
cost_part="${DIM}\$${cost}${RESET}"

# ── Session elapsed minutes ───────────────────────────────────────────────────
elapsed_ms=$(echo "$input" | jq -r '
  .cost.total_duration_ms //
  .session.duration_ms //
  .session_duration_ms //
  0
')
elapsed_min=$(awk "BEGIN{printf \"%d\", $elapsed_ms/60000}")
elapsed_part="${DIM}${elapsed_min}m${RESET}"

# ── Git branch (with dirty flag) or project basename fallback ─────────────────
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
branch=""
dirty=""
loc_part=""
if [ -n "$cwd" ]; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    # Parse GitHub owner from origin remote (disambiguates multiple git accounts)
    remote_url=$(git -C "$cwd" --no-optional-locks config --get remote.origin.url 2>/dev/null)
    owner=""
    if [ -n "$remote_url" ]; then
      url="${remote_url%.git}"
      parent="${url%/*}"
      owner="${parent##*/}"
      owner="${owner##*:}"
    fi

    if [ -n "$owner" ]; then
      # Color by sync state:
      #   green  = clean + synced     yellow = dirty (uncommitted)
      #   orange = ahead (push)       cyan   = behind (pull)
      #   red    = diverged
      # Suffix: +N (ahead) / -N (behind) / +N/-N (diverged). No suffix when synced.
      git_dirty=$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)
      ahead=0; behind=0
      if upstream=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
        counts=$(git -C "$cwd" --no-optional-locks rev-list --left-right --count "HEAD...${upstream}" 2>/dev/null)
        ahead=$(echo "$counts" | awk '{print $1+0}')
        behind=$(echo "$counts" | awk '{print $2+0}')
      fi
      if [ -n "$git_dirty" ]; then
        owner_color="$YELLOW"
      elif [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
        owner_color="$RED"
      elif [ "$ahead" -gt 0 ]; then
        owner_color="$ORANGE"
      elif [ "$behind" -gt 0 ]; then
        owner_color="$CYAN"
      else
        owner_color="$GREEN"
      fi
      # Build sync suffix
      sync_suffix=""
      if [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
        sync_suffix="${DIM} +${ahead}/-${behind}${RESET}"
      elif [ "$ahead" -gt 0 ]; then
        sync_suffix="${DIM} +${ahead}${RESET}"
      elif [ "$behind" -gt 0 ]; then
        sync_suffix="${DIM} -${behind}${RESET}"
      fi
      loc_part="${owner_color}@${owner}${RESET}${sync_suffix}"
    else
      # No remote — fall back to branch name
      [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ] && dirty="${YELLOW}*${RESET}"
      loc_part="${CYAN}${branch}${RESET}${dirty}"
    fi
  else
    base=$(basename "$cwd")
    [ -n "$base" ] && loc_part="${DIM}${base}${RESET}"
  fi
fi

# ── Assemble ──────────────────────────────────────────────────────────────────
out="${model_part}${SEP}${ctx_part}"
[ -n "$five_part" ]  && out="${out}${SEP}${five_part}"
[ -n "$seven_part" ] && out="${out}${SEP}${seven_part}"
[ -n "$cache_part" ] && out="${out}${SEP}${cache_part}"
out="${out}${SEP}${cost_part}"
out="${out}${SEP}${elapsed_part}"
[ -n "$loc_part" ]   && out="${out}${SEP}${loc_part}"

# ── Codex dispatch line (second row) ─────────────────────────────────────────
codex_line=""
codex_auth_cache="$HOME/.claude/codex-auth-cache.txt"
codex_last_json="$HOME/.claude/codex-last.json"
codex_auth_src="$HOME/.codex/auth.json"
codex_refresh="$HOME/.claude/scripts/codex-refresh-auth-cache.sh"

# Lazy refresh: regenerate cache when auth.json is newer or cache missing.
if [ -f "$codex_auth_src" ] && [ -x "$codex_refresh" ]; then
  if [ ! -f "$codex_auth_cache" ] || [ "$codex_auth_src" -nt "$codex_auth_cache" ]; then
    "$codex_refresh" >/dev/null 2>&1 || true
  fi
fi

if [ -f "$codex_auth_cache" ]; then
  codex_email=""; codex_plan=""; codex_org=""
  IFS='|' read -r codex_email codex_plan codex_org < "$codex_auth_cache" || true

  case "$codex_email" in
    ""|unknown|missing|error)
      # Only surface identity when something is wrong
      codex_part="${CODEX_GREEN}${BOLD}codex${RESET}${SEP}${RED}✗ not logged in${RESET}"
      ;;
    *)
      # Authed state — codex + plan rendered as single bold teal blob.
      codex_part="${CODEX_GREEN}${BOLD}codex${RESET}"
      if [ -n "$codex_plan" ] && [ "$codex_plan" != "unknown" ] && [ "$codex_plan" != "none" ]; then
        codex_part="${CODEX_GREEN}${BOLD}codex ${codex_plan}${RESET}"
      fi

      # Append active model. Prefer the model recorded on the last dispatch
      # (captures overrides); fall back to config.toml default.
      codex_model=""
      if [ -f "$codex_last_json" ]; then
        codex_model=$(jq -r '.model // empty' "$codex_last_json" 2>/dev/null)
      fi
      if [ -z "$codex_model" ] || [ "$codex_model" = "unknown" ]; then
        codex_model=$(grep -m1 -E '^model[[:space:]]*=' "$HOME/.codex/config.toml" 2>/dev/null | sed 's/.*= *"//; s/".*//')
      fi
      if [ -n "$codex_model" ]; then
        # Color the model cyan when a dispatch ran in the last 10 min
        # (activation indicator — same rule as age), dim otherwise.
        codex_model_color="${DIM}"
        if [ -f "$codex_last_json" ]; then
          ct=$(jq -r '.timestamp // empty' "$codex_last_json" 2>/dev/null)
          if [ -n "$ct" ]; then
            cts=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ct" +%s 2>/dev/null)
            if [ -n "$cts" ] && [ "$(( $(date -u +%s) - cts ))" -lt 600 ]; then
              codex_model_color="${CYAN}"
            fi
          fi
        fi
        codex_part="${codex_part} ${DIM}·${RESET} ${codex_model_color}${codex_model}${RESET}"

        # Reasoning-effort indicator — only when elevated (skip "none" default).
        # Colored yellow to signal "this run used extra compute."
        if [ -f "$codex_last_json" ]; then
          codex_reasoning=$(jq -r '.reasoning_effort // "none"' "$codex_last_json" 2>/dev/null)
          if [ -n "$codex_reasoning" ] && [ "$codex_reasoning" != "none" ] && [ "$codex_reasoning" != "null" ]; then
            codex_part="${codex_part} ${YELLOW}r:${codex_reasoning}${RESET}"
          fi
        fi
      fi
      ;;
  esac

  # Dispatches per rolling 5h window (ChatGPT Plus limits usage by messages,
  # not tokens — Plus = 20–100/5h on GPT-5.4. Default cap=50 (midpoint);
  # override via CODEX_DISPATCH_CAP_5H env var.
  codex_cap_5h="${CODEX_DISPATCH_CAP_5H:-50}"
  dispatches_5h=0
  total_toks_5h=0
  if [ -d "$HOME/.claude/logs" ]; then
    cutoff_5h=$(date -u -v-5H +%s 2>/dev/null)
    if [ -n "$cutoff_5h" ]; then
      for f in "$HOME"/.claude/logs/codex-*.log; do
        [ -f "$f" ] || continue
        m=$(stat -f "%m" "$f" 2>/dev/null)
        if [ -n "$m" ] && [ "$m" -ge "$cutoff_5h" ]; then
          dispatches_5h=$((dispatches_5h+1))
          t=$(grep -oE 'tokens=[0-9]+' "$f" 2>/dev/null | tail -1 | cut -d= -f2)
          [ -n "$t" ] && total_toks_5h=$((total_toks_5h + t))
        fi
      done
    fi
  fi
  dispatch_pct=$(awk "BEGIN{printf \"%d\", ($dispatches_5h/$codex_cap_5h)*100 + 0.5}")
  [ "$dispatch_pct" -gt 100 ] && dispatch_pct=100
  dispatch_bar=$(make_bar "$dispatch_pct" 6)
  dispatch_color=$(pct_color "$dispatch_pct")
  if [ "$total_toks_5h" -ge 1000 ]; then
    toks_5h_disp=$(awk "BEGIN{printf \"%.1fk\", $total_toks_5h/1000}")
  else
    toks_5h_disp="$total_toks_5h"
  fi
  codex_part="${codex_part}${SEP}${dispatch_bar} ${dispatch_color}${dispatches_5h}${RESET}${DIM}/~${codex_cap_5h} · ${RESET}${WHITE}${toks_5h_disp}${RESET}${DIM} toks (5h)${RESET}"

  if [ -f "$codex_last_json" ]; then
    codex_ts=$(jq -r '.timestamp // empty' "$codex_last_json" 2>/dev/null)
    codex_tokens=$(jq -r '.tokens // 0' "$codex_last_json" 2>/dev/null)
    codex_elapsed=$(jq -r '.elapsed_s // 0' "$codex_last_json" 2>/dev/null)
    codex_status=$(jq -r '.status // "unknown"' "$codex_last_json" 2>/dev/null)
    codex_task=$(jq -r '.task_name // empty' "$codex_last_json" 2>/dev/null)

    if [ -n "$codex_ts" ]; then
      codex_ts_sec=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$codex_ts" +%s 2>/dev/null)
      if [ -n "$codex_ts_sec" ]; then
        codex_now_sec=$(date -u +%s)
        codex_age_sec=$((codex_now_sec - codex_ts_sec))
        if   [ "$codex_age_sec" -lt 60 ];    then codex_age_str="${codex_age_sec}s ago"
        elif [ "$codex_age_sec" -lt 3600 ];  then codex_age_str="$((codex_age_sec / 60))m ago"
        elif [ "$codex_age_sec" -lt 86400 ]; then codex_age_str="$((codex_age_sec / 3600))h ago"
        else codex_age_str="$((codex_age_sec / 86400))d ago"
        fi

        if [ "$codex_age_sec" -lt 600 ]; then codex_age_color="${CYAN}"
        else codex_age_color="${DIM}"
        fi

        if [ "$codex_tokens" -ge 1000 ]; then
          codex_tok_disp=$(awk "BEGIN{printf \"%.1fk\", $codex_tokens/1000}")
        else
          codex_tok_disp="$codex_tokens"
        fi

        # Color failed runs red; successful runs render in normal text.
        codex_tok_color="${WHITE}"
        [ "$codex_status" = "failed" ] && codex_tok_color="${RED}"

        # Prefix task name if present.
        codex_task_str=""
        [ -n "$codex_task" ] && codex_task_str="${WHITE}${codex_task}${RESET}${DIM} · ${RESET}"

        codex_part="${codex_part}${SEP}${DIM}last:${RESET} ${codex_task_str}${codex_tok_color}${codex_tok_disp}${RESET} ${DIM}toks · ${RESET}${codex_age_color}${codex_age_str}${RESET}${DIM} · ${codex_elapsed}s${RESET}"
      fi
    fi
  else
    codex_part="${codex_part}${SEP}${DIM}no dispatches yet${RESET}"
  fi

  codex_line="$codex_part"
fi

[ -n "$codex_line" ] && out="${out}\n${codex_line}"

# ── Gemini dispatch line (third row) ─────────────────────────────────────────
# Mirrors Codex block but uses chars_out instead of tokens (Gemini CLI does not
# consistently print token counts to stdout on free/OAuth tier). Cap default
# 100 per 5h — override via GEMINI_DISPATCH_CAP_5H env var.
gemini_line=""
gemini_last_json="$HOME/.claude/gemini-last.json"
gemini_creds="$HOME/.gemini/oauth_creds.json"

if command -v gemini >/dev/null 2>&1 && [ -f "$gemini_creds" ]; then
  # Label reflects known Pro-tier configuration — no introspection of actual
  # plan. Edit this literal if you're on the free tier.
  gemini_part="${GEMINI_PURPLE}${BOLD}gemini pro${RESET}"

  # Append active model from cache file. The CLI does not print its model to
  # stdout, so we rely on ~/.claude/gemini-model-cache.txt populated by
  # ~/.claude/scripts/gemini-refresh-model-cache.sh. Cyan when recent dispatch
  # (activation indicator), dim otherwise.
  gemini_model_cache="$HOME/.claude/gemini-model-cache.txt"
  if [ -f "$gemini_model_cache" ]; then
    gemini_model=$(head -1 "$gemini_model_cache" | tr -d '[:space:]')
    # Strip the "gemini-" prefix for display brevity (e.g. "2.0-flash")
    gemini_model_short="${gemini_model#gemini-}"
    gemini_model_color="${DIM}"
    if [ -f "$gemini_last_json" ]; then
      gt=$(jq -r '.timestamp // empty' "$gemini_last_json" 2>/dev/null)
      if [ -n "$gt" ]; then
        gts=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$gt" +%s 2>/dev/null)
        if [ -n "$gts" ] && [ "$(( $(date -u +%s) - gts ))" -lt 600 ]; then
          gemini_model_color="${CYAN}"
        fi
      fi
    fi
    [ -n "$gemini_model_short" ] && gemini_part="${gemini_part} ${DIM}·${RESET} ${gemini_model_color}${gemini_model_short}${RESET}"
  fi

  # Dispatches per rolling 5h window
  gemini_cap_5h="${GEMINI_DISPATCH_CAP_5H:-100}"
  gemini_dispatches_5h=0
  gemini_chars_5h=0
  if [ -d "$HOME/.claude/logs" ]; then
    gemini_cutoff_5h=$(date -u -v-5H +%s 2>/dev/null)
    if [ -n "$gemini_cutoff_5h" ]; then
      for f in "$HOME"/.claude/logs/gemini-*.log; do
        [ -f "$f" ] || continue
        m=$(stat -f "%m" "$f" 2>/dev/null)
        if [ -n "$m" ] && [ "$m" -ge "$gemini_cutoff_5h" ]; then
          gemini_dispatches_5h=$((gemini_dispatches_5h+1))
          c=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
          [ -n "$c" ] && gemini_chars_5h=$((gemini_chars_5h + c))
        fi
      done
    fi
  fi
  gemini_dispatch_pct=$(awk "BEGIN{printf \"%d\", ($gemini_dispatches_5h/$gemini_cap_5h)*100 + 0.5}")
  [ "$gemini_dispatch_pct" -gt 100 ] && gemini_dispatch_pct=100
  gemini_dispatch_bar=$(make_bar "$gemini_dispatch_pct" 6)
  gemini_dispatch_color=$(pct_color "$gemini_dispatch_pct")
  if [ "$gemini_chars_5h" -ge 1000 ]; then
    gemini_chars_5h_disp=$(awk "BEGIN{printf \"%.1fk\", $gemini_chars_5h/1000}")
  else
    gemini_chars_5h_disp="$gemini_chars_5h"
  fi
  gemini_part="${gemini_part}${SEP}${gemini_dispatch_bar} ${gemini_dispatch_color}${gemini_dispatches_5h}${RESET}${DIM}/~${gemini_cap_5h} · ${RESET}${WHITE}${gemini_chars_5h_disp}${RESET}${DIM} chars (5h)${RESET}"

  if [ -f "$gemini_last_json" ]; then
    gemini_ts=$(jq -r '.timestamp // empty' "$gemini_last_json" 2>/dev/null)
    gemini_chars=$(jq -r '.chars_out // 0' "$gemini_last_json" 2>/dev/null)
    gemini_elapsed=$(jq -r '.elapsed_s // 0' "$gemini_last_json" 2>/dev/null)
    gemini_status=$(jq -r '.status // "unknown"' "$gemini_last_json" 2>/dev/null)
    gemini_task=$(jq -r '.task_name // empty' "$gemini_last_json" 2>/dev/null)

    if [ -n "$gemini_ts" ]; then
      gemini_ts_sec=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$gemini_ts" +%s 2>/dev/null)
      if [ -n "$gemini_ts_sec" ]; then
        gemini_now_sec=$(date -u +%s)
        gemini_age_sec=$((gemini_now_sec - gemini_ts_sec))
        if   [ "$gemini_age_sec" -lt 60 ];    then gemini_age_str="${gemini_age_sec}s ago"
        elif [ "$gemini_age_sec" -lt 3600 ];  then gemini_age_str="$((gemini_age_sec / 60))m ago"
        elif [ "$gemini_age_sec" -lt 86400 ]; then gemini_age_str="$((gemini_age_sec / 3600))h ago"
        else gemini_age_str="$((gemini_age_sec / 86400))d ago"
        fi

        if [ "$gemini_age_sec" -lt 600 ]; then gemini_age_color="${CYAN}"
        else gemini_age_color="${DIM}"
        fi

        if [ "$gemini_chars" -ge 1000 ]; then
          gemini_char_disp=$(awk "BEGIN{printf \"%.1fk\", $gemini_chars/1000}")
        else
          gemini_char_disp="$gemini_chars"
        fi

        gemini_char_color="${WHITE}"
        [ "$gemini_status" = "failed" ] && gemini_char_color="${RED}"

        # Prefix task name if present.
        gemini_task_str=""
        [ -n "$gemini_task" ] && gemini_task_str="${WHITE}${gemini_task}${RESET}${DIM} · ${RESET}"

        gemini_part="${gemini_part}${SEP}${DIM}last:${RESET} ${gemini_task_str}${gemini_char_color}${gemini_char_disp}${RESET} ${DIM}chars · ${RESET}${gemini_age_color}${gemini_age_str}${RESET}${DIM} · ${gemini_elapsed}s${RESET}"
      fi
    fi
  else
    gemini_part="${gemini_part}${SEP}${DIM}no dispatches yet${RESET}"
  fi

  gemini_line="$gemini_part"
fi

[ -n "$gemini_line" ] && out="${out}\n${gemini_line}"

printf "%b" "$out"
