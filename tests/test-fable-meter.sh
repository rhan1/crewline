#!/usr/bin/env bash
# tests/test-fable-meter.sh — the Fable line on the 7d meter, end to end, in a sandbox.
#
# Installs this checkout (statusline only, copy mode) into a throwaway HOME, then renders row 1 of the
# statusline from fixture input and a fixture ~/.claude/fable-usage.json. The refresher is fed a saved usage
# response (FABLE_USAGE_FIXTURE), so there is no network call and no credential read — except one case that
# checks the credentials-file fallback with a fake token and `security` kept off PATH.
#
# Usage: bash tests/test-fable-meter.sh      (exits non-zero on any FAIL)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/crewline-test.XXXXXX")" || { echo "cannot create sandbox" >&2; exit 2; }
cleanup() { case "$SANDBOX" in */crewline-test.*) rm -rf "$SANDBOX" ;; esac; }
trap cleanup EXIT
NODE="$(command -v node)"; JQ_DIR="$(dirname "$(command -v jq)")"
export HOME="$SANDBOX/home"; mkdir -p "$HOME" "$SANDBOX/home2/.claude"
unset FABLE_USAGE_CACHE FABLE_USAGE_FIXTURE CREWLINE_COMPONENTS

TOTAL=0; PASSED=0; FAILED=0
pass() { TOTAL=$((TOTAL+1)); PASSED=$((PASSED+1)); echo "PASS $1"; }
fail() { TOTAL=$((TOTAL+1)); FAILED=$((FAILED+1)); echo "FAIL $1${2:+ — $2}"; }

if ! bash "$REPO/install.sh" --minimal --copy </dev/null >"$SANDBOX/install.log" 2>&1; then
  echo "install.sh failed:"; cat "$SANDBOX/install.log"; exit 2
fi
SL="$HOME/.claude/statusline.sh"; REFRESH="$HOME/.claude/scripts/fable-usage-refresh.mjs"
[ -x "$REFRESH" ] && pass "statusline-only install ships the refresher, executable" || fail "refresher not installed or not executable"

NOW=$(date +%s)
BASE='"session_id":"t","model":{"id":"claude-fable-5","display_name":"Fable 5"},"workspace":{"current_dir":"/tmp"},"cost":{"total_cost_usd":41.2,"total_duration_ms":18300000},"context_window":{"used_percentage":31,"context_window_size":1000000}'
IN="{$BASE,\"rate_limits\":{\"five_hour\":{\"used_percentage\":8,\"resets_at\":$((NOW+9000))},\"seven_day\":{\"used_percentage\":37,\"resets_at\":$((NOW+400000))}}}"
strip() { sed $'s/\x1b\\[[0-9;]*m//g'; }
# row1 <cache-path> [input] [home]
row1() { printf '%s' "${2:-$IN}" | HOME="${3:-$HOME}" COLUMNS=195 FABLE_USAGE_CACHE="$1" bash "$SL" 2>/dev/null | head -1 | strip; }
raw1() { printf '%s' "$IN" | COLUMNS=195 FABLE_USAGE_CACHE="$1" bash "$SL" 2>/dev/null | head -1; }
bar7() { printf '%s' "$1" | sed -E 's/.*\[([^]]*)\] 7d:.*/\1/'; }
C="$SANDBOX/fable.json"
cache() { echo "{\"fable_pct\":$1,\"fable_resets_at\":$((NOW+${2:-400000}))}" > "$C"; }
plain='\[[^]│]{10}\] 7d:37% \([^)]*\)'

# Control first: no figure -> the normal 7d meter.
r=$(row1 "$SANDBOX/none.json"); echo "CONTROL literal: $r"
{ echo "$r" | grep -Eq "$plain" && ! echo "$r" | grep -q fable; } && pass "no figure -> normal 7d meter (10 cells, no line, no Fable text)" || fail "no cache" "$r"

cache 11; r=$(row1 "$C"); echo "GREEN literal:   $r"
echo "$r" | grep -Eq '\| \[[^]]{11}\] 7d:37% · fable 11% \([^)]*\)' && pass "fresh figure -> one 7d meter reading '7d:37% · fable 11% (clock)'" || fail "merged meter" "$r"
[ "$(bar7 "$r")" = "█│██▊░░░░░░" ] && pass "weekly fill unchanged (37 % = 3 cells + 3/4); line after cell 1 for Fable 11 %" || fail "bar content" "$(bar7 "$r")"
echo "$r" | grep -q 'fable 7d:' && fail "separate Fable meter present" "$r" || pass "no separate Fable meter"

for f in 0 4 5 40 70 96 100; do cache "$f"; b=$(bar7 "$(row1 "$C")")
  k=$(( (f + 5) / 10 )); pre=${b%%│*}; got=$(printf '%s' "$pre" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')
  lines=$(printf '%s' "$b" | LC_ALL=en_US.UTF-8 grep -o '│' | wc -l | tr -d ' ')
  { [ "$got" = "$k" ] && [ "$lines" = 1 ]; } && pass "Fable $f % -> exactly one line, after cell $k" || fail "line position for $f" "$b"
done

cache 11; touch -t "$(date -v-31M +%Y%m%d%H%M.%S 2>/dev/null || date -d '31 minutes ago' +%Y%m%d%H%M.%S)" "$C"
r=$(row1 "$C"); { echo "$r" | grep -Eq "$plain" && ! echo "$r" | grep -q fable; } && pass "figure older than 30 min -> normal 7d meter" || fail "stale cache" "$r"
echo 'not json' > "$C"; r=$(row1 "$C"); { echo "$r" | grep -Eq "$plain" && ! echo "$r" | grep -q fable; } && pass "garbage cache -> normal 7d meter" || fail "garbage cache" "$r"
echo '{"fable_resets_at":'$((NOW+400000))'}' > "$C"; r=$(row1 "$C"); echo "$r" | grep -q fable && fail "cache without a percent shown" "$r" || pass "cache without a percent -> normal 7d meter"
cache 112; r=$(row1 "$C"); x=$(raw1 "$C")
{ echo "$r" | grep -q '· fable 112%' && printf '%s' "$x" | grep -q $'\x1b\\[1m\x1b\\[[0-9;]*m112%'; } && pass "over the allowance -> real number (112%) in bold" || fail "over 100" "$r"
cache 64 -60; r=$(row1 "$C"); { echo "$r" | grep -q '· fable 0%' && [ "$(bar7 "$r" | cut -c1)" = "│" ]; } && pass "past the reset time -> fable 0%, line at the far left" || fail "past reset" "$r"
cache 11; r=$(row1 "$C" "{$BASE}" "$SANDBOX/home2")
{ echo "$r" | grep -q '\] fable 7d:11%' && ! echo "$r" | grep -q '7d:37%'; } && pass "no weekly figure at all -> separate Fable bar as the fallback" || fail "no weekly fallback" "$r"

# Refresher
F="$SANDBOX/resp.json"; O="$SANDBOX/out.json"
cat > "$F" <<'JSON'
{"five_hour":{"utilization":7.0},"limits":[
 {"kind":"session","percent":7,"resets_at":"2026-11-23T22:50:00.073562+00:00","scope":null},
 {"kind":"weekly_all","percent":8,"resets_at":"2026-11-29T09:00:00.073581+00:00","scope":null},
 {"kind":"weekly_scoped","percent":11,"resets_at":"2026-11-29T09:00:00.073719+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}],
 "weekly_scoped_shares":[{"limit_index":2,"used_percent_of_weekly":6,"allowance_percent_of_weekly":50}]}
JSON
FABLE_USAGE_FIXTURE="$F" FABLE_USAGE_CACHE="$O" node "$REFRESH"
[ "$(jq -r '"\(.fable_pct)|\(.fable_resets_at)|\(.fable_allowance_pct_of_week)|\(.week_all_pct)"' "$O" 2>/dev/null)" = "11|1795942800|50|8" ] && pass "refresher extracts percent / reset / allowance / week from the usage response" || fail "refresher parse" "$(cat "$O" 2>/dev/null)"
r=$(row1 "$O"); echo "$r" | grep -q '· fable 11%' && pass "statusline reads the refresher's own output" || fail "end to end" "$r"
echo '{"limits":[{"kind":"weekly_all","percent":8,"resets_at":"2026-11-29T09:00:00+00:00","scope":null},{"kind":"weekly_scoped","percent":40,"resets_at":"2026-11-29T09:00:00+00:00","scope":{"model":{"display_name":"Opus"}}}]}' > "$F"
before=$(cat "$O"); FABLE_USAGE_FIXTURE="$F" FABLE_USAGE_CACHE="$O" node "$REFRESH"
{ [ "$(cat "$O")" = "$before" ] && grep -q 'no Fable weekly row' "$O.err"; } && pass "no Fable row -> last good cache kept, reason noted (an Opus row is not taken for Fable)" || fail "no fable row" "$(cat "$O.err" 2>/dev/null)"
echo 'broken' > "$F"; FABLE_USAGE_FIXTURE="$F" FABLE_USAGE_CACHE="$O" node "$REFRESH"; rc=$?
{ [ $rc -eq 0 ] && [ "$(cat "$O")" = "$before" ]; } && pass "unreadable response -> exit 0, last good cache kept" || fail "broken response" "rc=$rc"
# credentials-file fallback: fake token in the sandbox HOME, `security` not on PATH
echo '{"claudeAiOauth":{"accessToken":"test-token-not-real","expiresAt":1}}' > "$HOME/.claude/.credentials.json"
tok=$(PATH="$SANDBOX/nobin" "$NODE" --input-type=module -e "const m = await import('file://$REFRESH'); process.stdout.write(String(m.readOauth().accessToken))" 2>/dev/null)
[ "$tok" = "test-token-not-real" ] && pass "login token is read from ~/.claude/.credentials.json when the Keychain is unavailable" || fail "credentials fallback" "$tok"
rm -f "$HOME/.claude/.credentials.json"

# Default (symlink) install: the refresher must still run when reached through the symlink, and uninstall removes it.
export HOME="$SANDBOX/home3"; mkdir -p "$HOME"
bash "$REPO/install.sh" --minimal </dev/null >"$SANDBOX/install3.log" 2>&1
L="$HOME/.claude/scripts/fable-usage-refresh.mjs"
[ -L "$L" ] && pass "default install symlinks the refresher" || fail "refresher is not a symlink in the default install"
printf '%s' '{"limits":[{"kind":"weekly_scoped","percent":23,"resets_at":"2026-11-29T09:00:00+00:00","scope":{"model":{"display_name":"Fable"}}}]}' > "$F"
FABLE_USAGE_FIXTURE="$F" FABLE_USAGE_CACHE="$SANDBOX/out3.json" "$L"
[ "$(jq -r .fable_pct "$SANDBOX/out3.json" 2>/dev/null)" = 23 ] && pass "refresher works when run through the install symlink" || fail "refresher did nothing through the symlink"
bash "$REPO/install.sh" --uninstall </dev/null >"$SANDBOX/uninstall.log" 2>&1
{ [ ! -e "$L" ] && [ ! -e "$HOME/.claude/statusline.sh" ]; } && pass "uninstall removes the statusline and the refresher" || fail "uninstall left files" "$(ls "$HOME/.claude/scripts" 2>/dev/null | tr '\n' ' ')"

echo; echo "RESULT: $PASSED/$TOTAL passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
