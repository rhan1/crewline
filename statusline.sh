#!/usr/bin/env bash
# Claude Code status line — ~/.claude/statusline.sh

input=$(cat)

# ── Cross-session rate-limit reconciliation (per-session files) ──────────────
# Rate limits are account-wide, but Claude Code hands each session ONLY its own
# last-API-response snapshot via stdin — an idle session shows a frozen, often
# PREVIOUS-window number while a busy one shows the live window, so raw stdin %s
# disagree across sessions. There is no local API for true account usage.
#
# FIX (race-free): each session writes ITS snapshot to ~/.claude/.rl/<ppid>.json
# (own file — no shared read-modify-write race), and the DISPLAY reduces across
# ALL live session files: current window = the MAX resets_at seen; usage = MAX %
# among sessions IN that window (usage only rises within a window). Older-window
# (stale) sessions are excluded by the max-reset filter, so a session idle since
# a past window can't drag the number to its stale value. An earlier shared-cache
# design oscillated because concurrent read-modify-writes let a stale session
# re-assert its old window; per-session files remove the shared write entirely.
SESSION_STATE="$HOME/.claude/.session-state.json"
RL_DIR="$HOME/.claude/.rl"
mkdir -p "$RL_DIR" 2>/dev/null
now_epoch=$(date -u +%s)

# this session's stdin snapshot (percentages rounded to int; empty -> JSON null)
in5p=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty'); [ -n "$in5p" ] && in5p=$(printf '%.0f' "$in5p" 2>/dev/null)
in5r=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
in7p=$(echo "$input" | jq -r '.rate_limits.weekly.used_percentage // .rate_limits.seven_day.used_percentage // empty'); [ -n "$in7p" ] && in7p=$(printf '%.0f' "$in7p" 2>/dev/null)
in7r=$(echo "$input" | jq -r '.rate_limits.weekly.resets_at // .rate_limits.seven_day.resets_at // empty')

# write own file ATOMICALLY (temp + mv) so readers never see a partial file
rl_tmp="$RL_DIR/.$PPID.tmp"
printf '{"ts":%s,"five_pct":%s,"five_reset":%s,"seven_pct":%s,"seven_reset":%s}\n' \
  "$now_epoch" "${in5p:-null}" "${in5r:-null}" "${in7p:-null}" "${in7r:-null}" \
  > "$rl_tmp" 2>/dev/null && mv -f "$rl_tmp" "$RL_DIR/$PPID.json" 2>/dev/null || true
# drop dead sessions' files (untouched 6h) so they can't skew the reduce / grow unbounded
find "$RL_DIR" -name '*.json' -mmin +360 -delete 2>/dev/null || true

# reduce across live files: current window = max reset; % = max within 1h of it
# (resets within RL_TOL count as the same window — covers minor drift, << 5h/7d span)
RL_TOL=3600
IFS=$'\t' read -r m5_pct m5_reset m7_pct m7_reset <<< "$(jq -s -r \
  --argjson now "$now_epoch" --argjson tol "$RL_TOL" '
  [ .[] | select((($now - (.ts // 0)) <= 21600)) ] as $live |
  ($live | map(.five_reset  // empty) | max) as $r5 |
  ($live | map(.seven_reset // empty) | max) as $r7 |
  [ ( if $r5 == null then "" else ([ $live[] | select((.five_reset  // -1) >= ($r5 - $tol)) | .five_pct  // 0 ] | max // "") end ),
    ( $r5 // "" ),
    ( if $r7 == null then "" else ([ $live[] | select((.seven_reset // -1) >= ($r7 - $tol)) | .seven_pct // 0 ] | max // "") end ),
    ( $r7 // "" )
  ] | @tsv' "$RL_DIR"/*.json 2>/dev/null)"

# fallback: if the reduce produced nothing, degrade to this session's own snapshot
[ -z "$m5_pct" ] && [ -n "$in5p" ] && { m5_pct="$in5p"; m5_reset="$in5r"; }
[ -z "$m7_pct" ] && [ -n "$in7p" ] && { m7_pct="$in7p"; m7_reset="$in7r"; }

# persist reconciled values for /budget-check + slash commands
echo "$input" | jq \
  --arg ts "$now_epoch" \
  --argjson m5p "${m5_pct:-null}" --argjson m5r "${m5_reset:-null}" \
  --argjson m7p "${m7_pct:-null}" --argjson m7r "${m7_reset:-null}" '{
  timestamp: ($ts | tonumber),
  model: (.model.display_name // null),
  context_window: (.context_window // {}),
  rate_limits: { five_hour: {used_percentage: $m5p, resets_at: $m5r},
                 seven_day: {used_percentage: $m7p, resets_at: $m7r} },
  cost: (.cost // {}),
  cwd: (.workspace.current_dir // .cwd // null)
}' > "$SESSION_STATE" 2>/dev/null || true

# ── Colors (truecolor — bypasses Warp theme remapping) ────────────────────────
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

# ── Unified external-LLM ledger: 5h aggregation (single jq pass) ─────────────
# Direct agy/codex binary calls (via the ~/.claude/shims PATH shims) and headless
# claude -p calls (via llm-tick) append to ~/.claude/llm-calls.jsonl, so the
# statusline reflects offloaded work that bypassed the dispatch wrappers.
# Full-file read (weekly-maintenance prunes to 5000 lines, so it's bounded):
# a tail window could scroll past a tool's newest entry and re-stale `last:`.
# Malformed lines are skipped. Runs BEFORE row 1 so claude -p cost shows there.
led_codex_n=0; led_agy_n=0; led_cp_n=0; led_cp_cost=0
led_codex_last_ts=0; led_agy_last_ts=0   # newest ledger ts per tool (for `last:`)
LEDGER_FILE="$HOME/.claude/llm-calls.jsonl"
if [ -f "$LEDGER_FILE" ]; then
  led_cut=$(date -u -v-5H +%s 2>/dev/null)
  if [ -n "$led_cut" ]; then
    led_agg=$(jq -rRn --argjson cut "$led_cut" '
      [inputs | fromjson?] as $all |
      ($all | map(select(.ts >= $cut))) as $e |
      [ ($e | map(select(.tool=="codex"))    | length),
        ($e | map(select(.tool=="agy"))      | length),
        ($e | map(select(.tool=="claude-p")) | length),
        ($e | map(select(.tool=="claude-p") | .cost_usd) | add // 0),
        ($all | map(select(.tool=="codex") | .ts) | max // 0),
        ($all | map(select(.tool=="agy")   | .ts) | max // 0)
      ] | @tsv' "$LEDGER_FILE" 2>/dev/null)
    [ -n "$led_agg" ] && IFS=$'\t' read -r led_codex_n led_agy_n led_cp_n led_cp_cost led_codex_last_ts led_agy_last_ts <<< "$led_agg"
  fi
fi
# normalize (empty/non-numeric → 0) so arithmetic + tests can't error
[[ "$led_codex_n" =~ ^[0-9]+$ ]] || led_codex_n=0
[[ "$led_agy_n"   =~ ^[0-9]+$ ]] || led_agy_n=0
[[ "$led_cp_n"    =~ ^[0-9]+$ ]] || led_cp_n=0
[[ "$led_cp_cost" =~ ^[0-9]*\.?[0-9]+$ ]] || led_cp_cost=0
[[ "$led_codex_last_ts" =~ ^[0-9]+$ ]] || led_codex_last_ts=0
[[ "$led_agy_last_ts"   =~ ^[0-9]+$ ]] || led_agy_last_ts=0

# Compact claude -p 5h-cost segment for row 1 (only when there's headless spend).
cp_main_part=""
if [ "$led_cp_n" -gt 0 ]; then
  cp_main_disp=$(awk "BEGIN{printf \"%.2f\", $led_cp_cost}")
  cp_main_part="${YELLOW}cp:${RESET}${WHITE}\$${cp_main_disp}${RESET}"
fi

# Live counts of background executor processes (one read-only `ps` snapshot;
# bracket-trick `[x]` excludes the grep itself). The statusline otherwise shows
# only COMPLETED dispatches (a 5h count + a "last:" timestamp), so a long-running
# background job reads as dead — e.g. a Codex wrapper run only writes
# codex-last.json on COMPLETION, so its row shows a stale "last:" the whole time
# it's working. These live counts surface that the executors are actually alive.
PS_SNAP=$(ps -axo command 2>/dev/null)
# headless `claude -p` jobs (burn Claude budget but never refresh the 5h bar)
cp_running=$(printf '%s\n' "$PS_SNAP" | grep -cE '(^|/)[c]laude +(-p|--print)( |$)')
[[ "$cp_running" =~ ^[0-9]+$ ]] || cp_running=0
cp_run_part=""
[ "$cp_running" -gt 0 ] && cp_run_part="${CYAN}${BOLD}${cp_running} bg-claude${RESET}${DIM} running${RESET}"
# app-server excluded ANYWHERE in the line (not just adjacent `codex app-server`):
# ChatGPT.app runs an embedded `codex -c <flags> app-server` that otherwise
# lights `running now` permanently (caught 2026-07-22).
codex_live=$(printf '%s\n' "$PS_SNAP" | awk '/(^|\/)codex( |$)/ && $0 !~ /app-server/ { count++ } END { print count + 0 }')
[[ "$codex_live" =~ ^[0-9]+$ ]] || codex_live=0
agy_live=$(printf '%s\n' "$PS_SNAP" | grep -cE '(^|/)[a]gy ')
[[ "$agy_live" =~ ^[0-9]+$ ]] || agy_live=0

# ── RuFlo status (last routing decision within 10 min) ───────────────────────
# Computed before the model segment because it renders INSIDE it (subagent model
# sits next to the main model, mirroring the codex row's `codex plus · <model>`).
# State file format:  "<ISO_TS> <ACTION> <chosen>-><final> conf=<pct>"
#   ACTION = REWRITE (RuFlo changed the model) | AGREE (RuFlo confirmed) | PASSTHRU
ruflo_part=""
if command -v ruflo >/dev/null 2>&1; then
  ruflo_state="$HOME/.claude/hooks/ruflo-last-route.txt"
  if [ -f "$ruflo_state" ]; then
    line=$(tail -1 "$ruflo_state" 2>/dev/null)
    if [ -n "$line" ]; then
      ts=$(echo "$line" | awk '{print $1}' | sed 's/\..*//')
      action=$(echo "$line" | awk '{print $2}')
      route=$(echo "$line" | awk '{print $3}')  # chosen->final
      chosen=${route%%-*}
      final=${route##*>}
      ts_sec=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$ts" +%s 2>/dev/null)
      if [ -n "$ts_sec" ]; then
        now_sec=$(date -u +%s)
        age_sec=$((now_sec - ts_sec))
        if [ "$age_sec" -ge 0 ] && [ "$age_sec" -lt 600 ]; then
          if   [ "$age_sec" -lt 60 ]; then age_str="now"
          else age_str="$((age_sec / 60))m"
          fi
          case "$action" in
            REWRITE)
              # Rewrite: opus→sonnet in yellow
              ruflo_part="${YELLOW}${chosen}→${final}${RESET} ${DIM}${age_str}${RESET}"
              ;;
            AGREE)
              # Agree: just final model in cyan
              ruflo_part="${CYAN}${final}${RESET} ${DIM}${age_str}${RESET}"
              ;;
            # PASSTHRU: stays empty — nothing useful to display
          esac
        fi
      fi
    fi
  fi
fi

# ── Model ─────────────────────────────────────────────────────────────────────
model_name=$(echo "$input" | jq -r '.model.display_name // "Unknown"')
# Drop the "(1M context)" parenthetical — the context bar already shows this.
model_name=$(printf '%s' "$model_name" | sed -E 's/ *\([^)]*[Cc]ontext[^)]*\)//')
model_part="${ORANGE}${BOLD}${model_name}${RESET}"

# Subagent route rides next to the main model: "Opus 5 · sonnet 4m · xhigh"
[ -n "$ruflo_part" ] && model_part="${model_part} ${DIM}·${RESET} ${ruflo_part}"

# Effort pill — persisted effortLevel from settings.json (--effort/env can override
# per session; settings is the durable source). Warmer = higher spend.
effort=$(jq -r '.effortLevel // empty' "$HOME/.claude/settings.json" 2>/dev/null)
if [ -n "$effort" ] && [ "$effort" != "null" ]; then
  case "$effort" in
    max)   eff_col='\033[1m\033[38;2;255;140;90m' ;;  # bold warm-orange: max spend
    xhigh) eff_col="$ORANGE" ;;
    high)  eff_col="$YELLOW" ;;
    *)     eff_col="${DIM}${WHITE}" ;;
  esac
  model_part="${model_part} ${DIM}·${RESET} ${eff_col}${effort}${RESET}"
fi

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
# Renders the reconciled m5_* values (shared across sessions), NOT this session's
# raw stdin snapshot — that's what makes every window agree.
if [ -n "$m5_pct" ] && [ -n "$m5_reset" ]; then
  now5=$(date -u +%s)
  if [ "$now5" -ge "$m5_reset" ]; then
    five_int=0          # window elapsed & no session has a fresher reading -> reset
  else
    five_int=$m5_pct
  fi
  if [ "$five_int" -ge 100 ]; then
    # at/over budget: bar maxes out, real number in bold red. NOT a hard block —
    # the cap throttles/tolerates overage, so Claude often keeps operating.
    five_bar=$(make_bar 100 10); five_color="${BOLD}${RED}"
  else
    five_bar=$(make_bar "$five_int" 10); five_color=$(pct_color "$five_int")
  fi
  five_part="${five_bar} ${DIM}5h:${RESET}${five_color}${five_int}%${RESET}"
  five_eta=$(time_until "$m5_reset" 18000)
  if [ -n "$five_eta" ]; then
    five_clock=$(reset_clock "$m5_reset" 18000)
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
# Renders the reconciled m7_* values (shared across sessions).
if [ -n "$m7_pct" ] && [ -n "$m7_reset" ]; then
  now7=$(date -u +%s)
  if [ "$now7" -ge "$m7_reset" ]; then
    seven_int=0
  else
    seven_int=$m7_pct
  fi
  if [ "$seven_int" -ge 100 ]; then
    seven_bar=$(make_bar 100 10); seven_color="${BOLD}${RED}"
  else
    seven_bar=$(make_bar "$seven_int" 10); seven_color=$(pct_color "$seven_int")
  fi
  seven_part="${seven_bar} ${DIM}7d:${RESET}${seven_color}${seven_int}%${RESET}"
  seven_eta=$(time_until "$m7_reset" 604800)
  if [ -n "$seven_eta" ]; then
    seven_clock=$(reset_clock "$m7_reset" 604800)
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

# ── Cost + burn rate ──────────────────────────────────────────────────────────
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

# Burn rate ($/hr) — needs >=1 minute elapsed to be meaningful
if [ "$elapsed_min" -gt 0 ]; then
  burn=$(awk "BEGIN{printf \"%.2f\", ($cost_usd/$elapsed_min)*60}")
  burn_part="${DIM}\$${burn}/hr${RESET}"
else
  burn_part=""
fi

# ── Git branch (with dirty flag) or project basename fallback ─────────────────
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
branch=""
dirty=""
loc_part=""
if [ -n "$cwd" ]; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    # Parse GitHub owner from origin remote (disambiguates rhan1 vs razakhanLL)
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
# bg-claude sits right after the model/effort section (Raza 2026-08-04): it's
# "what the engine is doing", and putting it between the 5h and 7d bars split
# the two rate segments visually.
out="${model_part}"
[ -n "$cp_run_part" ] && out="${out}${SEP}${cp_run_part}"
out="${out}${SEP}${ctx_part}"
[ -n "$five_part" ]  && out="${out}${SEP}${five_part}"
[ -n "$seven_part" ] && out="${out}${SEP}${seven_part}"
[ -n "$cache_part" ] && out="${out}${SEP}${cache_part}"
out="${out}${SEP}${cost_part}"
[ -n "$cp_main_part" ] && out="${out}${SEP}${cp_main_part}"
[ -n "$loc_part" ]   && out="${out}${SEP}${loc_part}"

# ── Codex dispatch line (second row) ─────────────────────────────────────────
codex_line=""
codex_auth_cache="$HOME/.claude/codex-auth-cache.txt"
codex_last_json="$HOME/.claude/codex-last.json"
codex_auth_src="$HOME/.codex/auth.json"
codex_refresh="$HOME/.claude/scripts/codex-refresh-auth-cache.sh"
codex_limits_cache="$HOME/.claude/codex-rate-limits.json"
codex_limits_refresh="$HOME/.claude/scripts/codex-rate-limits-refresh.mjs"
codex_limits_fresh=0

if [ -f "$codex_limits_cache" ]; then
  codex_limits_mtime=$(stat -f "%m" "$codex_limits_cache" 2>/dev/null)
  if [[ "$codex_limits_mtime" =~ ^[0-9]+$ ]] && [ "$((now_epoch - codex_limits_mtime))" -lt 60 ]; then
    codex_limits_fresh=1
  fi
fi

if [ "$codex_limits_fresh" -eq 0 ] && [ -x "$codex_limits_refresh" ]; then
  nohup "$codex_limits_refresh" </dev/null >/dev/null 2>&1 &
fi

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
        # (activation indicator — same rule as RuFlo and age), dim otherwise.
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
  [[ "$codex_cap_5h" =~ ^[0-9]+$ ]] && [ "$codex_cap_5h" -ge 1 ] || codex_cap_5h=50   # 0/garbage → div-by-zero in awk
  dispatches_5h=0
  total_toks_5h=0
  codex_log_ts=0   # newest real-dispatch log mtime — ground truth for "last ran"
  if [ -d "$HOME/.claude/logs" ]; then
    cutoff_5h=$(date -u -v-5H +%s 2>/dev/null)
    if [ -n "$cutoff_5h" ]; then
      for f in "$HOME"/.claude/logs/codex-*.log; do
        [ -f "$f" ] || continue
        case "$f" in *codex-56-*) continue ;; esac   # skip the GPT-5.6 watcher's own logs
        m=$(stat -f "%m" "$f" 2>/dev/null)
        if [[ "$m" =~ ^[0-9]+$ ]] && [ "$m" -ge "$cutoff_5h" ]; then
          dispatches_5h=$((dispatches_5h+1))
          [ "$m" -gt "$codex_log_ts" ] && codex_log_ts=$m
          # -a: a codex log can contain binary bytes — without it grep emits
          # "Binary file … matches", which then lands in the arithmetic below and
          # aborts the whole codex block (row silently disappears).
          t=$(grep -a -oE 'tokens=[0-9]+' "$f" 2>/dev/null | tail -1 | cut -d= -f2)
          [[ "$t" =~ ^[0-9]+$ ]] && total_toks_5h=$((total_toks_5h + t))
        fi
      done
    fi
  fi
  dispatches_5h=$((dispatches_5h + led_codex_n))   # + direct `codex exec` via shim
  dispatch_pct=$(awk "BEGIN{printf \"%d\", ($dispatches_5h/$codex_cap_5h)*100 + 0.5}")
  [ "$dispatch_pct" -gt 100 ] && dispatch_pct=100
  dispatch_bar=$(make_bar "$dispatch_pct" 6)
  dispatch_color=$(pct_color "$dispatch_pct")
  if [ "$total_toks_5h" -ge 1000 ]; then
    toks_5h_disp=$(awk "BEGIN{printf \"%.1fk\", $total_toks_5h/1000}")
  else
    toks_5h_disp="$total_toks_5h"
  fi
  codex_limits_part=""
  if [ -f "$codex_limits_cache" ]; then
    while IFS=$'\t' read -r codex_limit_pct codex_limit_minutes codex_limit_reset; do
      [[ "$codex_limit_pct" =~ ^[0-9]+$ ]] || continue
      [[ "$codex_limit_minutes" =~ ^[0-9]+$ ]] || continue
      [[ "$codex_limit_reset" =~ ^[0-9]+$ ]] || continue
      if [ "$codex_limit_minutes" -ge 1440 ] && [ "$((codex_limit_minutes % 1440))" -eq 0 ]; then
        codex_limit_label="$((codex_limit_minutes / 1440))d"
      elif [ "$codex_limit_minutes" -ge 60 ] && [ "$((codex_limit_minutes % 60))" -eq 0 ]; then
        codex_limit_label="$((codex_limit_minutes / 60))h"
      else
        codex_limit_label="${codex_limit_minutes}m"
      fi
      codex_limit_window=$((codex_limit_minutes * 60))
      codex_limit_remaining=$(time_until "$codex_limit_reset" "$codex_limit_window")
      codex_limit_clock=$(reset_clock "$codex_limit_reset" "$codex_limit_window")
      # Match the main row's treatment (line ~314): dim label, gradient % only,
      # RESET before the dim parens — pct_color must NOT wrap the countdown, or
      # DIM just stacks faint-green on it instead of gray.
      codex_limit_text="${DIM}${codex_limit_label}:${RESET}$(pct_color "$codex_limit_pct")${codex_limit_pct}%${RESET}"
      if [ -n "$codex_limit_remaining" ] && [ -n "$codex_limit_clock" ]; then
        codex_limit_text="${codex_limit_text} ${DIM}(${codex_limit_remaining} - ${codex_limit_clock})${RESET}"
      fi
      # Width 10 to match row 1's rate bars (Raza 2026-08-04 — the 6-cell bar
      # read as tiny next to the main 5h/7d bars).
      codex_limit_segment="$(make_bar "$codex_limit_pct" 10) ${codex_limit_text}"
      if [ -n "$codex_limits_part" ]; then
        codex_limits_part="${codex_limits_part} ${DIM}·${RESET} "
      fi
      codex_limits_part="${codex_limits_part}${codex_limit_segment}"
    done < <(jq -r '(.rate_limits.primary, .rate_limits.secondary) | select(type == "object") | select((.used_percent | type) == "number" and (.window_duration_mins | type) == "number" and (.resets_at | type) == "number") | [.used_percent, .window_duration_mins, .resets_at] | @tsv' "$codex_limits_cache" 2>/dev/null)
  fi
  if [ -n "$codex_limits_part" ]; then
    codex_part="${codex_part}${SEP}${codex_limits_part}${SEP}${WHITE}${toks_5h_disp}${RESET}${DIM} toks (5h)${RESET}"
  else
    codex_part="${codex_part}${SEP}${dispatch_bar} ${dispatch_color}${dispatches_5h}${RESET}${DIM}/~${codex_cap_5h} · ${RESET}${WHITE}${toks_5h_disp}${RESET}${DIM} toks (5h)${RESET}"
  fi

  # `last:` reflects the FRESHEST codex signal: the rich wrapper json
  # (codex-last.json — has task/tokens) OR a bare `codex` call caught by the PATH
  # shim (ledger — no metadata). The live 5h count is driven by the shim, so
  # showing the wrapper's stale "4d ago" beside a count of 42 was contradictory.
  codex_json_ts_sec=0
  if [ -f "$codex_last_json" ]; then
    cjts=$(jq -r '.timestamp // empty' "$codex_last_json" 2>/dev/null)
    [ -n "$cjts" ] && codex_json_ts_sec=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$cjts" +%s 2>/dev/null)
    [[ "$codex_json_ts_sec" =~ ^[0-9]+$ ]] || codex_json_ts_sec=0
  fi
  codex_now_sec=$(date -u +%s)
  if [ "${codex_live:-0}" -gt 0 ]; then
    # a codex dispatch is running RIGHT NOW. The wrapper writes codex-last.json
    # only on COMPLETION, so "last:" would show a stale (even days-old) entry the
    # whole time it works — show that it's alive instead.
    codex_part="${codex_part}${SEP}${GREEN}${BOLD}running now${RESET}"
  elif [ "${codex_log_ts:-0}" -gt "$codex_json_ts_sec" ] && [ "${codex_log_ts:-0}" -gt "${led_codex_last_ts:-0}" ]; then
    # most recent codex run wrote only a dispatch log — it bypassed BOTH the
    # wrapper (which updates codex-last.json) and the shim ledger (e.g. invoked
    # by absolute path). Use the log mtime so a recent run isn't shown as a stale
    # days-old "last:".
    codex_age_sec=$((codex_now_sec - codex_log_ts))
    if   [ "$codex_age_sec" -lt 60 ];    then codex_age_str="${codex_age_sec}s ago"
    elif [ "$codex_age_sec" -lt 3600 ];  then codex_age_str="$((codex_age_sec / 60))m ago"
    elif [ "$codex_age_sec" -lt 86400 ]; then codex_age_str="$((codex_age_sec / 3600))h ago"
    else codex_age_str="$((codex_age_sec / 86400))d ago"
    fi
    codex_age_color="${DIM}"; [ "$codex_age_sec" -lt 600 ] && codex_age_color="${CYAN}"
    codex_part="${codex_part}${SEP}${DIM}last:${RESET} ${codex_age_color}${codex_age_str}${RESET}${DIM} · ran${RESET}"
  elif [ "$led_codex_last_ts" -gt "$codex_json_ts_sec" ]; then
    # freshest activity is a bare/direct `codex` call (no task/token metadata)
    codex_age_sec=$((codex_now_sec - led_codex_last_ts))
    if   [ "$codex_age_sec" -lt 60 ];    then codex_age_str="${codex_age_sec}s ago"
    elif [ "$codex_age_sec" -lt 3600 ];  then codex_age_str="$((codex_age_sec / 60))m ago"
    elif [ "$codex_age_sec" -lt 86400 ]; then codex_age_str="$((codex_age_sec / 3600))h ago"
    else codex_age_str="$((codex_age_sec / 86400))d ago"
    fi
    codex_age_color="${DIM}"; [ "$codex_age_sec" -lt 600 ] && codex_age_color="${CYAN}"
    codex_part="${codex_part}${SEP}${DIM}last:${RESET} ${codex_age_color}${codex_age_str}${RESET}${DIM} · direct call${RESET}"
  elif [ "$codex_json_ts_sec" -gt 0 ]; then
    codex_tokens=$(jq -r '.tokens // 0' "$codex_last_json" 2>/dev/null)
    codex_elapsed=$(jq -r '.elapsed_s // 0' "$codex_last_json" 2>/dev/null)
    codex_status=$(jq -r '.status // "unknown"' "$codex_last_json" 2>/dev/null)
    codex_task=$(jq -r '.task_name // empty' "$codex_last_json" 2>/dev/null)
    codex_age_sec=$((codex_now_sec - codex_json_ts_sec))
    if   [ "$codex_age_sec" -lt 60 ];    then codex_age_str="${codex_age_sec}s ago"
    elif [ "$codex_age_sec" -lt 3600 ];  then codex_age_str="$((codex_age_sec / 60))m ago"
    elif [ "$codex_age_sec" -lt 86400 ]; then codex_age_str="$((codex_age_sec / 3600))h ago"
    else codex_age_str="$((codex_age_sec / 86400))d ago"
    fi
    codex_age_color="${DIM}"; [ "$codex_age_sec" -lt 600 ] && codex_age_color="${CYAN}"
    if [ "$codex_tokens" -ge 1000 ]; then codex_tok_disp=$(awk "BEGIN{printf \"%.1fk\", $codex_tokens/1000}"); else codex_tok_disp="$codex_tokens"; fi
    codex_tok_color="${WHITE}"; [ "$codex_status" = "failed" ] && codex_tok_color="${RED}"
    codex_task_str=""; [ -n "$codex_task" ] && codex_task_str="${WHITE}${codex_task}${RESET}${DIM} · ${RESET}"
    codex_part="${codex_part}${SEP}${DIM}last:${RESET} ${codex_task_str}${codex_tok_color}${codex_tok_disp}${RESET} ${DIM}toks · ${RESET}${codex_age_color}${codex_age_str}${RESET}${DIM} · ${codex_elapsed}s${RESET}"
  else
    codex_part="${codex_part}${SEP}${DIM}no dispatches yet${RESET}"
  fi

  codex_line="$codex_part"
fi

[ -n "$codex_line" ] && out="${out}\n${codex_line}"

# ── agy (Antigravity) dispatch line (third row) ──────────────────────────────
# Antigravity CLI replaced Gemini CLI (cutover 2026-05-29). The dispatch wrapper
# still writes ~/.claude/gemini-last.json + logs/gemini-*.log (filenames kept),
# now with an `executor` field. Uses chars_out (agy print mode doesn't reliably
# emit token counts). Cap default 100 per 5h — override via GEMINI_DISPATCH_CAP_5H.
gemini_line=""
gemini_last_json="$HOME/.claude/gemini-last.json"
agy_bin="$(command -v agy 2>/dev/null || true)"
[ -z "$agy_bin" ] && [ -x "$HOME/.local/bin/agy" ] && agy_bin="$HOME/.local/bin/agy"

if [ -n "$agy_bin" ]; then
  # Label: "Antigravity" in bold Antigravity-purple (mirrors "codex" styling).
  gemini_part="${GEMINI_PURPLE}${BOLD}Antigravity${RESET}"

  # Append the active model agy is using, read from its settings — this is the pinned
  # DEFAULT (set via the interactive /model command and persisted here), so it stays
  # accurate as the pin changes. NOTE (2026-08-18): agy 1.1.13 DOES have `--model` and
  # `--effort` flags, so an individual dispatch can override this pin (AGY_MODEL /
  # AGY_EFFORT on gemini-dispatch.sh) and the row will still show the default. Earlier
  # comments here claiming "agy has no CLI model flag" were stale.
  # Cyan when a dispatch ran in the last 10 min, dim otherwise.
  agy_settings="$HOME/.gemini/antigravity-cli/settings.json"
  agy_model=""
  [ -f "$agy_settings" ] && agy_model=$(jq -r '.model // empty' "$agy_settings" 2>/dev/null)
  if [ -n "$agy_model" ]; then
    gemini_model_color="${DIM}"
    gt=$(jq -r '.timestamp // empty' "$gemini_last_json" 2>/dev/null)
    if [ -n "$gt" ]; then
      gts=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$gt" +%s 2>/dev/null)
      if [ -n "$gts" ] && [ "$(( $(date -u +%s) - gts ))" -lt 600 ]; then
        gemini_model_color="${CYAN}"
      fi
    fi
    gemini_part="${gemini_part} ${DIM}·${RESET} ${gemini_model_color}${agy_model}${RESET}"
  fi

  # Dispatches per rolling 5h window.
  # agy's REAL quota lives only in its in-memory quota_manager (investigated
  # 2026-07-22 — nothing numeric on disk; TUI /usage is the only view), so the
  # old `:-100` default was a fiction (rendered "470/~100" 2026-08-03). A cap
  # bar + denominator now renders ONLY when GEMINI_DISPATCH_CAP_5H pins a real
  # number; otherwise show the plain count and invent nothing.
  gemini_cap_5h="${GEMINI_DISPATCH_CAP_5H:-}"
  [[ "$gemini_cap_5h" =~ ^[0-9]+$ ]] && [ "$gemini_cap_5h" -ge 1 ] || gemini_cap_5h=""
  gemini_dispatches_5h=0
  gemini_chars_5h=0
  if [ -d "$HOME/.claude/logs" ]; then
    gemini_cutoff_5h=$(date -u -v-5H +%s 2>/dev/null)
    if [ -n "$gemini_cutoff_5h" ]; then
      for f in "$HOME"/.claude/logs/gemini-*.log; do
        [ -f "$f" ] || continue
        m=$(stat -f "%m" "$f" 2>/dev/null)
        if [[ "$m" =~ ^[0-9]+$ ]] && [ "$m" -ge "$gemini_cutoff_5h" ]; then
          gemini_dispatches_5h=$((gemini_dispatches_5h+1))
          c=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
          [ -n "$c" ] && gemini_chars_5h=$((gemini_chars_5h + c))
        fi
      done
    fi
  fi
  gemini_dispatches_5h=$((gemini_dispatches_5h + led_agy_n))   # + direct `agy -p` via shim
  if [ "$gemini_chars_5h" -ge 1000 ]; then
    gemini_chars_5h_disp=$(awk "BEGIN{printf \"%.1fk\", $gemini_chars_5h/1000}")
  else
    gemini_chars_5h_disp="$gemini_chars_5h"
  fi
  # ── Real quota bars (agy's own language-server RPC) ────────────────────────
  # ~/.claude/agy-quota.json holds the REAL 5h + weekly buckets (percent used),
  # refreshed by scripts/agy-quota-refresh.sh. agy quota is token-COST based,
  # not call-count, so these bars are the only honest capacity signal — the old
  # `N/~100` denominator was invented. Falls back to the plain call count when
  # the file is missing or stale.
  agy_quota_cache="$HOME/.claude/agy-quota.json"
  agy_quota_refresh="$HOME/.claude/scripts/agy-quota-refresh.sh"
  agy_quota_fresh=0
  if [ -f "$agy_quota_cache" ]; then
    agy_q_ts=$(jq -r '.fetched_at // empty' "$agy_quota_cache" 2>/dev/null)
    if [[ "$agy_q_ts" =~ ^[0-9]+$ ]] && [ "$((now_epoch - agy_q_ts))" -lt 900 ]; then
      agy_quota_fresh=1
    fi
  fi
  # Stale → kick a detached refresh (boots the LS for ~2s, spends no quota).
  if [ "$agy_quota_fresh" -eq 0 ] && [ -x "$agy_quota_refresh" ]; then
    nohup "$agy_quota_refresh" </dev/null >/dev/null 2>&1 &
  fi

  agy_quota_part=""
  if [ "$agy_quota_fresh" -eq 1 ]; then
    while IFS=$'\t' read -r q_label q_pct q_reset q_window; do
      [ -n "$q_pct" ] || continue
      q_int=$(printf '%.0f' "$q_pct" 2>/dev/null); [[ "$q_int" =~ ^[0-9]+$ ]] || continue
      [ "$q_int" -gt 100 ] && q_int=100
      q_remaining=$(time_until "$q_reset" "$q_window")
      q_clock=$(reset_clock "$q_reset" "$q_window")
      q_text="${DIM}${q_label}:${RESET}$(pct_color "$q_int")${q_int}%${RESET}"
      if [ -n "$q_remaining" ] && [ -n "$q_clock" ]; then
        q_text="${q_text} ${DIM}(${q_remaining} - ${q_clock})${RESET}"
      fi
      [ -n "$agy_quota_part" ] && agy_quota_part="${agy_quota_part}${SEP}"
      agy_quota_part="${agy_quota_part}$(make_bar "$q_int" 10) ${q_text}"
    done < <(jq -r '.groups.gemini | ["5h", (.five_hour.used_percent // empty), (.five_hour.resets_at // 0), 18000], ["7d", (.weekly.used_percent // empty), (.weekly.resets_at // 0), 604800] | @tsv' "$agy_quota_cache" 2>/dev/null)
  fi

  if [ -n "$agy_quota_part" ]; then
    gemini_part="${gemini_part}${SEP}${agy_quota_part}${SEP}${WHITE}${gemini_dispatches_5h}${RESET}${DIM} calls (5h)${RESET}"
  elif [ -n "$gemini_cap_5h" ]; then
    gemini_dispatch_pct=$(awk "BEGIN{printf \"%d\", ($gemini_dispatches_5h/$gemini_cap_5h)*100 + 0.5}")
    [ "$gemini_dispatch_pct" -gt 100 ] && gemini_dispatch_pct=100
    gemini_dispatch_bar=$(make_bar "$gemini_dispatch_pct" 10)
    gemini_dispatch_color=$(pct_color "$gemini_dispatch_pct")
    gemini_part="${gemini_part}${SEP}${gemini_dispatch_bar} ${gemini_dispatch_color}${gemini_dispatches_5h}${RESET}${DIM}/~${gemini_cap_5h} · ${RESET}${WHITE}${gemini_chars_5h_disp}${RESET}${DIM} chars (5h)${RESET}"
  else
    gemini_part="${gemini_part}${SEP}${WHITE}${gemini_dispatches_5h}${RESET}${DIM} calls · ${RESET}${WHITE}${gemini_chars_5h_disp}${RESET}${DIM} chars (5h)${RESET}"
  fi

  # `last:` reflects the freshest signal: rich wrapper json (gemini-last.json —
  # task/chars) OR a bare `agy` call caught by the shim (ledger — no metadata).
  gemini_json_ts_sec=0
  if [ -f "$gemini_last_json" ]; then
    gjts=$(jq -r '.timestamp // empty' "$gemini_last_json" 2>/dev/null)
    [ -n "$gjts" ] && gemini_json_ts_sec=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$gjts" +%s 2>/dev/null)
    [[ "$gemini_json_ts_sec" =~ ^[0-9]+$ ]] || gemini_json_ts_sec=0
  fi
  gemini_now_sec=$(date -u +%s)
  if [ "${agy_live:-0}" -gt 0 ]; then
    # an agy job is running RIGHT NOW — show it's alive (its stdout/last.json may
    # not land until it finishes, and headless agy can spin silently)
    gemini_part="${gemini_part}${SEP}${GREEN}${BOLD}running now${RESET}"
  elif [ "$led_agy_last_ts" -gt "$gemini_json_ts_sec" ]; then
    gemini_age_sec=$((gemini_now_sec - led_agy_last_ts))
    if   [ "$gemini_age_sec" -lt 60 ];    then gemini_age_str="${gemini_age_sec}s ago"
    elif [ "$gemini_age_sec" -lt 3600 ];  then gemini_age_str="$((gemini_age_sec / 60))m ago"
    elif [ "$gemini_age_sec" -lt 86400 ]; then gemini_age_str="$((gemini_age_sec / 3600))h ago"
    else gemini_age_str="$((gemini_age_sec / 86400))d ago"
    fi
    gemini_age_color="${DIM}"; [ "$gemini_age_sec" -lt 600 ] && gemini_age_color="${CYAN}"
    gemini_part="${gemini_part}${SEP}${DIM}last:${RESET} ${gemini_age_color}${gemini_age_str}${RESET}${DIM} · direct call${RESET}"
  elif [ "$gemini_json_ts_sec" -gt 0 ]; then
    gemini_chars=$(jq -r '.chars_out // 0' "$gemini_last_json" 2>/dev/null)
    gemini_elapsed=$(jq -r '.elapsed_s // 0' "$gemini_last_json" 2>/dev/null)
    gemini_status=$(jq -r '.status // "unknown"' "$gemini_last_json" 2>/dev/null)
    gemini_task=$(jq -r '.task_name // empty' "$gemini_last_json" 2>/dev/null)
    gemini_age_sec=$((gemini_now_sec - gemini_json_ts_sec))
    if   [ "$gemini_age_sec" -lt 60 ];    then gemini_age_str="${gemini_age_sec}s ago"
    elif [ "$gemini_age_sec" -lt 3600 ];  then gemini_age_str="$((gemini_age_sec / 60))m ago"
    elif [ "$gemini_age_sec" -lt 86400 ]; then gemini_age_str="$((gemini_age_sec / 3600))h ago"
    else gemini_age_str="$((gemini_age_sec / 86400))d ago"
    fi
    gemini_age_color="${DIM}"; [ "$gemini_age_sec" -lt 600 ] && gemini_age_color="${CYAN}"
    if [ "$gemini_chars" -ge 1000 ]; then gemini_char_disp=$(awk "BEGIN{printf \"%.1fk\", $gemini_chars/1000}"); else gemini_char_disp="$gemini_chars"; fi
    gemini_char_color="${WHITE}"; [ "$gemini_status" = "failed" ] && gemini_char_color="${RED}"
    gemini_task_str=""; [ -n "$gemini_task" ] && gemini_task_str="${WHITE}${gemini_task}${RESET}${DIM} · ${RESET}"
    gemini_part="${gemini_part}${SEP}${DIM}last:${RESET} ${gemini_task_str}${gemini_char_color}${gemini_char_disp}${RESET} ${DIM}chars · ${RESET}${gemini_age_color}${gemini_age_str}${RESET}${DIM} · ${gemini_elapsed}s${RESET}"
  else
    gemini_part="${gemini_part}${SEP}${DIM}no dispatches yet${RESET}"
  fi

  gemini_line="$gemini_part"
fi

[ -n "$gemini_line" ] && out="${out}\n${gemini_line}"

# ── claude -p headless line (fourth row) ─────────────────────────────────────
# High-volume `claude -p` calls (e.g. Haiku extraction in scrapers) are the real
# Claude burn but otherwise never surface here. Logged via llm-tick; shown only
# when >0 in the rolling 5h window. Cost is summed from ledger cost_usd.
if [ "$led_cp_n" -gt 0 ]; then
  cp_cost_disp=$(awk "BEGIN{printf \"%.2f\", $led_cp_cost}")
  cp_part="${YELLOW}${BOLD}claude -p${RESET}${SEP}${WHITE}${led_cp_n}${RESET}${DIM} calls (5h)${RESET}${SEP}${WHITE}\$${cp_cost_disp}${RESET}${DIM} est${RESET}"
  out="${out}\n${cp_part}"
fi

printf "%b" "$out"
