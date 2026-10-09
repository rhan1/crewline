#!/usr/bin/env bash
# tests/test-routing.sh — the enforced routing stack, end to end, in a sandbox.
#
# Installs this checkout (copy mode, every component) into a throwaway HOME and
# exercises route-resolver / route-chain / ruflo-model-enforcer / agy-worker-audit,
# the dispatch wrappers' quota floor gate + reserved-tier guard, quota-balance's
# staleness / IDLE / Codex-weekly rows, and install.sh's settings snippet for every
# combination of the routing-relevant components.
#
# No network, no real quota caches, no real codex/agy: capacity comes from fixtures
# via ROUTE_CAPACITY_JSON / DISPATCH_GATE_JSON, and stub CLIs sit first on PATH.
#
# Usage: bash tests/test-routing.sh      (exits non-zero on any FAIL)

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FX="$REPO/tests/fixtures"
ORIG_HOME="$HOME"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/crewline-test.XXXXXX")" || { echo "cannot create sandbox" >&2; exit 2; }
cleanup() { case "$SANDBOX" in */crewline-test.*) rm -rf "$SANDBOX" ;; esac; }
trap cleanup EXIT

export HOME="$SANDBOX/home"
mkdir -p "$HOME" "$SANDBOX/bin"
# Never inherit the caller's routing/dispatch knobs.
unset ROUTE_ENFORCE ROUTE_RESOLVER_OFF ROUTE_CAPACITY_JSON DISPATCH_FORCE DISPATCH_GATE_JSON \
      CODEX_TIER CODEX_ALLOW_RESERVED CODEX_SERVICE_TIER CODEX_ROUTER FABLE_INHERIT_FALLBACK \
      AGY_MODEL AGY_EFFORT CREWLINE_COMPONENTS

# Stub CLIs: any call is recorded and fails, so a test that reaches a real dispatch shows up.
for b in codex agy ruflo; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/stub-calls.log"\nexit 99\n' "$b" "$SANDBOX" > "$SANDBOX/bin/$b"
  chmod +x "$SANDBOX/bin/$b"
done
export PATH="$SANDBOX/bin:$PATH"

TOTAL=0; PASSED=0; FAILED=0
pass() { TOTAL=$((TOTAL+1)); PASSED=$((PASSED+1)); echo "PASS $1"; }
fail() { TOTAL=$((TOTAL+1)); FAILED=$((FAILED+1)); echo "FAIL $1${2:+ — $2}"; }
check() { # check "label" <condition command...>
  local label="$1"; shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

# Size of a file (0 if missing) — used for isolation and log-growth checks.
fsize() { [ -f "$1" ] && wc -c < "$1" | tr -d ' ' || echo 0; }
REAL_DECISIONS_BEFORE="$(fsize "$ORIG_HOME/.claude/route-decisions.jsonl")"
REAL_VIOLATIONS_BEFORE="$(fsize "$ORIG_HOME/.claude/route-violations.jsonl")"

# ── Install into the sandbox ──────────────────────────────────────────────────
if ! CREWLINE_COMPONENTS="0,1,2,3,4,5,6,7,8,9" bash "$REPO/install.sh" --copy </dev/null >"$SANDBOX/install.log" 2>&1; then
  echo "install.sh failed:"; cat "$SANDBOX/install.log"; exit 2
fi
H="$HOME/.claude/hooks"
S="$HOME/.claude/scripts"

resolver() { node "$H/route-resolver.js" < "$1"; }      # env passed by caller
ctx()      { jq -r '.hookSpecificOutput.additionalContext // ""'; }
rewritten_to() { jq -r '.hookSpecificOutput.updatedInput.subagent_type // "none"'; }

# ── 1. Resolver rewrites under enforce ────────────────────────────────────────
out="$(ROUTE_ENFORCE=1 ROUTE_CAPACITY_JSON="$FX/cap-agy-spend.json" resolver "$FX/agent-explore.json")"
check "1 resolver rewrites eligible call to agy-worker under ROUTE_ENFORCE=1" \
  test "$(printf '%s' "$out" | rewritten_to)" = "agy-worker"

# ── 2. Blocker wins ───────────────────────────────────────────────────────────
out="$(ROUTE_ENFORCE=1 ROUTE_CAPACITY_JSON="$FX/cap-agy-spend.json" resolver "$FX/agent-browser.json")"
c="$(printf '%s' "$out" | ctx)"
if [ "$(printf '%s' "$out" | rewritten_to)" = "none" ] && [[ "$c" == *"blocker:browser"* ]]; then
  pass "2 browser blocker keeps the call on Claude (blocker:browser, no updatedInput)"
else fail "2 browser blocker keeps the call on Claude" "$c"; fi

# ── 3. Negated browser is not a blocker ───────────────────────────────────────
out="$(ROUTE_ENFORCE=1 ROUTE_CAPACITY_JSON="$FX/cap-agy-spend.json" resolver "$FX/agent-nobrowser.json")"
check "3 'no browser needed' is not a blocker — rewritten to agy-worker" \
  test "$(printf '%s' "$out" | rewritten_to)" = "agy-worker"

# ── 4. Floor wins ─────────────────────────────────────────────────────────────
out="$(ROUTE_ENFORCE=1 ROUTE_CAPACITY_JSON="$FX/cap-agy-floor.json" resolver "$FX/agent-explore.json")"
c="$(printf '%s' "$out" | ctx)"
if [ "$(printf '%s' "$out" | rewritten_to)" = "none" ] && [[ "$c" == *"agy floor"* ]]; then
  pass "4 agy floor breach keeps the call on Claude (agy floor)"
else fail "4 agy floor breach keeps the call on Claude" "$c"; fi

# ── 5. Use-or-lose tie-break ──────────────────────────────────────────────────
out="$(ROUTE_ENFORCE=1 ROUTE_CAPACITY_JSON="$FX/cap-claude-spend.json" resolver "$FX/agent-explore.json")"
c="$(printf '%s' "$out" | ctx)"
if [ "$(printf '%s' "$out" | rewritten_to)" = "none" ] && [[ "$c" == *"7d use-or-lose"* ]]; then
  pass "5a Claude 7d SPEND +45 vs agy ON PACE +5 — stays on Claude (7d use-or-lose)"
else fail "5a Claude 7d SPEND vs agy ON PACE stays on Claude" "$c"; fi
out="$(ROUTE_ENFORCE=1 ROUTE_CAPACITY_JSON="$FX/cap-agy-idle.json" resolver "$FX/agent-explore.json")"
check "5b same Claude SPEND but agy weekly IDLE — rewritten to agy-worker" \
  test "$(printf '%s' "$out" | rewritten_to)" = "agy-worker"

# ── 6. Advisory without enforce ───────────────────────────────────────────────
out="$(ROUTE_CAPACITY_JSON="$FX/cap-agy-spend.json" resolver "$FX/agent-explore.json")"
c="$(printf '%s' "$out" | ctx)"
if [ "$(printf '%s' "$out" | rewritten_to)" = "none" ] && [[ "$c" == *"agy-worker"* ]]; then
  pass "6 ROUTE_ENFORCE unset — advisory line names agy-worker, no rewrite"
else fail "6 ROUTE_ENFORCE unset — advisory only" "$c"; fi

# ── 7. Explicit-model judgment passthrough ────────────────────────────────────
out="$(ROUTE_ENFORCE=1 ROUTE_CAPACITY_JSON="$FX/cap-agy-spend.json" resolver "$FX/agent-judgment.json")"
c="$(printf '%s' "$out" | ctx)"
if [ "$(printf '%s' "$out" | rewritten_to)" = "none" ] && [[ "$c" == *"blocker:explicit-judgment"* ]]; then
  pass "7 model:opus + 'Adversarial review' — not rewritten (blocker:explicit-judgment)"
else fail "7 explicit-model judgment passthrough" "$c"; fi

# ── 8. route-chain falls through to the tier enforcer ─────────────────────────
log_before="$(grep -c 'FIRED' "$H/ruflo-enforcer.log" 2>/dev/null || true)"; log_before="${log_before:-0}"
out="$(ROUTE_ENFORCE=1 ROUTE_CAPACITY_JSON="$FX/cap-agy-spend.json" node "$H/route-chain.js" < "$FX/agent-browser.json")"
log_after="$(grep -c 'FIRED' "$H/ruflo-enforcer.log" 2>/dev/null || true)"; log_after="${log_after:-0}"
c="$(printf '%s' "$out" | ctx)"
if [ "$log_after" -gt "$log_before" ] && [[ "$c" == *"[route]"*"blocker:browser"* ]]; then
  pass "8a route-chain ran the RuFlo enforcer (FIRED ${log_before}→${log_after}) and kept the resolver's advisory line"
else fail "8a route-chain → enforcer with advisory carried" "fired ${log_before}→${log_after} ctx=$c"; fi
mv "$H/ruflo-model-enforcer.js" "$SANDBOX/enforcer.bak"
out="$(ROUTE_ENFORCE=1 ROUTE_CAPACITY_JSON="$FX/cap-agy-spend.json" node "$H/route-chain.js" < "$FX/agent-browser.json")"
direct="$(ROUTE_ENFORCE=1 ROUTE_CAPACITY_JSON="$FX/cap-agy-spend.json" resolver "$FX/agent-browser.json")"
if [ "$out" != "{}" ] && [ "$(printf '%s' "$out" | jq -S .)" = "$(printf '%s' "$direct" | jq -S .)" ]; then
  pass "8b enforcer absent — route-chain returns the resolver's advisory JSON, not {}"
else fail "8b enforcer absent — resolver output passed through" "$out"; fi
mv "$SANDBOX/enforcer.bak" "$H/ruflo-model-enforcer.js"

# ── 9. Agent pin passthrough ──────────────────────────────────────────────────
pinned="$(grep -m1 '^model:' "$HOME/.claude/agents/agy-worker.md" | awk '{print $2}')"
out="$(node "$H/ruflo-model-enforcer.js" < "$FX/agent-agyworker.json")"
m="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.model // "none"')"
mv "$HOME/.claude/agents/agy-worker.md" "$SANDBOX/agy-worker.md.bak"
m_unpinned="$(node "$H/ruflo-model-enforcer.js" < "$FX/agent-agyworker.json" | jq -r '.hookSpecificOutput.updatedInput.model // "none"')"
mv "$SANDBOX/agy-worker.md.bak" "$HOME/.claude/agents/agy-worker.md"
if [ "$pinned" = "haiku" ] && [ "$m" = "none" ] && [ "$m_unpinned" != "none" ]; then
  pass "9 agy-worker pinned to haiku — enforcer leaves model alone (control without the pin: rewritten to $m_unpinned)"
else fail "9 agent pin passthrough" "pin=$pinned model=$m unpinned=$m_unpinned"; fi

# ── 10. dc_quota_gate ─────────────────────────────────────────────────────────
logs_count() { ls -1 "$HOME/.claude/logs" 2>/dev/null | wc -l | tr -d ' '; }
before="$(logs_count)"
DISPATCH_GATE_JSON="$FX/gate-codex-exhausted.json" bash "$S/codex-dispatch.sh" "$FX/spec.txt" gatetest >/dev/null 2>"$SANDBOX/gate.err"; rc=$?
after="$(logs_count)"
if [ "$rc" -eq 3 ] && [ "$before" = "$after" ] && grep -q 'REFUSED' "$SANDBOX/gate.err"; then
  pass "10a Codex EXHAUSTED — codex-dispatch.sh exits 3 before writing any log (${before}→${after} files)"
else fail "10a Codex EXHAUSTED refuses" "rc=$rc logs ${before}→${after}"; fi
gate() { ( source "$S/dispatch-common.sh"; dc_quota_gate '^Codex( weekly)?$' "" ) 2>/dev/null; }
DISPATCH_GATE_JSON="$FX/gate-codex-exhausted.json" gate; rc=$?
check "10b dc_quota_gate on the EXHAUSTED fixture returns 3 (rc=$rc)" test "$rc" -eq 3
DISPATCH_GATE_JSON="$FX/gate-codex-onpace.json" gate; rc=$?
check "10c dc_quota_gate on ON PACE / no floor breach returns 0 (rc=$rc)" test "$rc" -eq 0
DISPATCH_GATE_JSON="$SANDBOX/does-not-exist.json" gate; rc=$?
check "10d dc_quota_gate with a missing fixture fails OPEN (rc=$rc)" test "$rc" -eq 0
DISPATCH_FORCE=1 DISPATCH_GATE_JSON="$FX/gate-codex-exhausted.json" gate; rc=$?
check "10e DISPATCH_FORCE=1 bypasses the EXHAUSTED refusal (rc=$rc)" test "$rc" -eq 0

# ── 11. Reserved tier ─────────────────────────────────────────────────────────
CODEX_TIER=max DISPATCH_GATE_JSON="$FX/gate-codex-exhausted.json" bash "$S/codex-dispatch.sh" "$FX/spec.txt" tiertest >/dev/null 2>"$SANDBOX/tier.err"; rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ] && grep -q 'reserved' "$SANDBOX/tier.err"; then
  pass "11a CODEX_TIER=max without CODEX_ALLOW_RESERVED=1 refused (rc=$rc, 'reserved')"
else fail "11a reserved tier refused" "rc=$rc $(cat "$SANDBOX/tier.err")"; fi
# No CODEX_DRY_RUN exists: with the guard satisfied, the EXHAUSTED gate fixture stops the
# wrapper at the very next step (exit 3) — proof the reserved-tier guard was passed
# without ever reaching a real dispatch.
CODEX_TIER=max CODEX_ALLOW_RESERVED=1 DISPATCH_GATE_JSON="$FX/gate-codex-exhausted.json" bash "$S/codex-dispatch.sh" "$FX/spec.txt" tiertest >/dev/null 2>"$SANDBOX/tier2.err"; rc=$?
if [ "$rc" -eq 3 ] && ! grep -q 'reserved' "$SANDBOX/tier2.err"; then
  pass "11b CODEX_ALLOW_RESERVED=1 passes the guard (stopped next at the floor gate, rc=3)"
else fail "11b reserved tier allowed" "rc=$rc"; fi
CODEX_SERVICE_TIER=flex bash "$S/codex-dispatch.sh" "$FX/spec.txt" tiertest >/dev/null 2>"$SANDBOX/tier3.err"; rc=$?
if [ "$rc" -eq 2 ] && grep -q "only 'default'" "$SANDBOX/tier3.err"; then
  pass "11c CODEX_SERVICE_TIER=flex refused (rc=2)"
else fail "11c service tier guard" "rc=$rc"; fi

# ── 12. quota-balance: staleness, IDLE, Codex weekly ──────────────────────────
now="$(date +%s)"
qb() { node "$S/quota-balance.mjs" --json; }
jq -n --argjson f "$((now - 7*3600))" --argjson r "$((now + 3*86400))" \
  '{fetched_at:$f, groups:{gemini:{weekly:{used_percent:20,resets_at:$r},five_hour:{used_percent:10,resets_at:($r - 200000)}}}}' \
  > "$HOME/.claude/agy-quota.json"
out="$(qb)"
if [ "$(printf '%s' "$out" | jq '[.rows[] | select(.label|startswith("agy"))] | length')" = "0" ] \
   && printf '%s' "$out" | jq -e '.stale | map(select(test("agy"))) | length > 0' >/dev/null; then
  pass "12a agy cache fetched 7h ago — no agy rows, listed under .stale"
else fail "12a stale agy cache dropped" "$out"; fi
jq -n --argjson f "$now" --argjson r "$((now + 7*86400))" \
  '{fetched_at:$f, groups:{gemini:{weekly:{used_percent:0,resets_at:$r}}}}' > "$HOME/.claude/agy-quota.json"
st="$(qb | jq -r '.rows[] | select(.label=="agy weekly") | .state')"
check "12b fresh untouched agy weekly (0% used, resets in 7d) reads IDLE (got '$st')" test "$st" = "IDLE"
jq -n --argjson f "$now" --argjson r5 "$((now + 2*3600))" --argjson rw "$((now + 4*86400))" \
  '{fetched_at:$f, rate_limits:{primary:{used_percent:30,resets_at:$r5,window_duration_mins:300},secondary:{used_percent:40,resets_at:$rw,window_duration_mins:10080}}}' \
  > "$HOME/.claude/codex-rate-limits.json"
labels="$(qb | jq -r '[.rows[] | select(.label|startswith("Codex")) | .label] | sort | join(",")')"
check "12c Codex primary + secondary → rows 'Codex' and 'Codex weekly' (got '$labels')" test "$labels" = "Codex,Codex weekly"
rm -f "$HOME/.claude/agy-quota.json" "$HOME/.claude/codex-rate-limits.json"

# ── 13. agy-worker-audit ──────────────────────────────────────────────────────
mkdir -p "$HOME/.claude/logs"
printf '{"ts":%s,"event":"start","agent_id":"a-bad","agent_type":"agy-worker"}\n{"ts":%s,"event":"start","agent_id":"a-good","agent_type":"agy-worker"}\n' \
  "$((now - 60))" "$((now - 60))" >> "$HOME/.claude/agent-activity.jsonl"
jq -nc '{timestamp:"2026-01-01T00:00:00Z",message:{content:[{type:"tool_use",id:"t1",name:"Bash",input:{command:"cat src/index.js # gemini-dispatch.sh"}}]}}' > "$SANDBOX/t-bad.jsonl"
jq -nc '{message:{content:[{type:"tool_result",tool_use_id:"t1",is_error:false,content:"..."}]}}' >> "$SANDBOX/t-bad.jsonl"
jq -nc '{timestamp:"2026-01-01T00:00:00Z",message:{content:[{type:"tool_use",id:"t1",name:"Bash",input:{command:"AGY_EFFORT=high ~/.claude/scripts/gemini-dispatch.sh /tmp/agy-spec-x.txt x"}}]}}' > "$SANDBOX/t-good.jsonl"
jq -nc '{message:{content:[{type:"tool_result",tool_use_id:"t1",is_error:false,content:"done"}]}}' >> "$SANDBOX/t-good.jsonl"
audit() { jq -nc --arg id "$1" --arg tp "$2" '{hook_event_name:"SubagentStop",agent_type:"agy-worker",agent_id:$id,session_id:"s",agent_transcript_path:$tp}' | node "$H/agy-worker-audit.js" 2>/dev/null; }
out="$(audit a-bad "$SANDBOX/t-bad.jsonl")"
check "13a agy-worker with no real gemini-dispatch.sh call → VIOLATION" grep -q 'VIOLATION' <<<"$out"
touch "$HOME/.claude/logs/gemini-$(date -u +%Y%m%dT%H%M%SZ).log"
out="$(audit a-good "$SANDBOX/t-good.jsonl")"
if ! grep -q 'VIOLATION' <<<"$out"; then
  pass "13b agy-worker that invoked gemini-dispatch.sh with a fresh gemini log → no VIOLATION"
else fail "13b dispatched agy-worker passes audit" "$out"; fi

# ── 14. install.sh settings snippet — every combo of {4,6,7,8} ────────────────
snippet() { sed -n '/BEGIN crewline settings snippet/,/END crewline settings snippet/p' | sed '1d;$d'; }
if printf '{"a":1,}' | jq . >/dev/null 2>&1; then
  fail "14 control: the jq validator rejects a trailing comma"
else pass "14 control: the jq validator rejects a trailing comma"; fi
for mask in $(seq 0 15); do
  c4=$(( mask & 1 )); c6=$(( (mask >> 1) & 1 )); c7=$(( (mask >> 2) & 1 )); c8=$(( (mask >> 3) & 1 ))
  comps="0,1,2,3,5,9"
  [ "$c4" = 1 ] && comps="$comps,4"; [ "$c6" = 1 ] && comps="$comps,6"
  [ "$c7" = 1 ] && comps="$comps,7"; [ "$c8" = 1 ] && comps="$comps,8"
  ih="$SANDBOX/inst-$mask"; mkdir -p "$ih"
  snip="$(HOME="$ih" CREWLINE_COMPONENTS="$comps" bash "$REPO/install.sh" --copy </dev/null 2>&1 | snippet)"
  label="14 snippet 4=$c4 6=$c6 7=$c7 8=$c8"
  if ! printf '%s' "$snip" | jq -e . >/dev/null 2>&1; then fail "$label" "invalid JSON"; continue; fi
  pre="$(printf '%s' "$snip" | jq -r '[.hooks.PreToolUse[]?.hooks[].command] | join(" ")')"
  stop="$(printf '%s' "$snip" | jq -r '[.hooks.SubagentStop[]?.hooks[].command] | join(" ")')"
  env="$(printf '%s' "$snip" | jq -r '.env.ROUTE_ENFORCE // "unset"')"
  ok=1
  if [ "$c8" = 1 ]; then
    [[ "$pre" == *route-chain.js* ]] || ok=0
    [[ "$pre" == *ruflo-model-enforcer.js* ]] && ok=0
    [[ "$stop" == *agy-worker-audit.js* ]] || ok=0
    [ "$env" = "1" ] || ok=0
  else
    [[ "$pre" == *route-chain.js* ]] && ok=0
    [ "$env" = "unset" ] || ok=0
    if [ "$c4" = 1 ]; then [[ "$pre" == *ruflo-model-enforcer.js* ]] || ok=0; fi
  fi
  if [ "$c6" = 1 ]; then [[ "$stop" == *agent-activity-log.js* ]] || ok=0; fi
  if [ "$ok" = 1 ]; then pass "$label — valid JSON, wiring correct"; else fail "$label" "pre=[$pre] stop=[$stop] env=$env"; fi
done

# ── 15. Isolation ─────────────────────────────────────────────────────────────
stub_calls="$(cat "$SANDBOX/stub-calls.log" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$(fsize "$ORIG_HOME/.claude/route-decisions.jsonl")" = "$REAL_DECISIONS_BEFORE" ] \
   && [ "$(fsize "$ORIG_HOME/.claude/route-violations.jsonl")" = "$REAL_VIOLATIONS_BEFORE" ] \
   && [ "$stub_calls" = "0" ] && [ -s "$HOME/.claude/route-decisions.jsonl" ]; then
  pass "15 sandbox isolation — decisions logged only in the sandbox HOME, no codex/agy CLI invoked"
else fail "15 sandbox isolation" "stub calls=$stub_calls"; fi

echo ""
echo "Test run with $TOTAL tests in 1 suites — passed $PASSED, failed $FAILED"
[ "$FAILED" -eq 0 ]
