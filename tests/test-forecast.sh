#!/bin/bash
# test-forecast.sh — RED/GREEN proof for the usage forecast + admission (scripts/quota-forecast.mjs).
# Everything runs in sandbox HOMEs under /tmp with a fixed clock; nothing touches the live ~/.claude state.
# Each case prints "PASS|FAIL <name> | got: <verdict line>" plus, where it applies, what TODAY'S rule (floor gate
# only: refuse at 100 %/exhausted) would have done. Last line: "GREEN n pass, m fail | RED old rule wrong on k".
# Usage: bash tests/test-forecast.sh   (from the repo root or anywhere)
set -u
REAL="$(cd "$(dirname "$0")/../scripts" && pwd)"
ENG=$REAL/quota-forecast.mjs
SEED="$(cd "$(dirname "$0")" && pwd)/fixtures/forecast-model.json"
PAIRS="$(cd "$(dirname "$0")" && pwd)/fixtures/forecast-budget-pairs.json"
T=$(mktemp -d /tmp/fc-test-XXXX)
SLEEPERS=()
cleanup() { [ ${#SLEEPERS[@]} -gt 0 ] && kill "${SLEEPERS[@]}" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
NOW=1792870000
pass=0; fail=0; oldwrong=0
sleep 900 & LIVE=$!; SLEEPERS+=("$LIVE")

home() { # new sandbox HOME
  H=$T/h$RANDOM$RANDOM; mkdir -p "$H/.claude/run-status/dispatch-running" "$H/.claude/run-status/dispatch-queue" "$H/.codex" "$H/.codex-work" "$H/.claude/scripts"
  cp "$SEED" "$H/.claude/quota-cost-model.json"
}
iso() { python3 -c "import datetime,sys;print(datetime.datetime.fromtimestamp(float(sys.argv[1]),datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z'))" "$1"; }
cx() { # p_used p_resets_in w_used w_resets_in [fetched_age]
  printf '{"fetched_at":"%s","profile_name":"personal","profiles":[{"name":"personal","rate_limits":{"primary":{"used_percent":%s,"resets_at":%s},"secondary":{"used_percent":10},"reached_type":null}},{"name":"work","rate_limits":{"primary":{"used_percent":%s,"resets_at":%s},"secondary":{"used_percent":10},"reached_type":null}}]}\n' \
    "$(iso $((NOW - ${5:-30})))" "$1" $((NOW + $2)) "$3" $((NOW + $4)) > "$H/.claude/codex-rate-limits.json"
}
ag() { # used resets_in
  printf '{"fetched_at":%s,"source":"test","groups":{"gemini":{"five_hour":{"used_percent":%s,"resets_at":%s},"weekly":{"used_percent":10,"resets_at":%s}},"gemini_argon":{"weekly":{"used_percent":0,"resets_at":%s}}}}\n' \
    $((NOW - 30)) "$1" $((NOW + $2)) $((NOW + 400000)) $((NOW + 400000)) > "$H/.claude/agy-quota.json"
}
lane() { # name executor task tier profile started_ago pid project est [log]
  printf '{"executor":"%s","task":"%s","model":"m","tier":"%s","started":%s,"pid":%s,"log":"%s","parent_pid":null,"spec":"","profile":"%s","project":"%s","est_pct":%s}\n' \
    "$2" "$3" "$4" $((NOW - $6)) "$7" "${10:-}" "$5" "$8" "$9" > "$H/.claude/run-status/dispatch-running/$1.json"
}
qent() { # key project task window est created_ago expires_in priority
  printf '{"key":"%s","project":"%s","task":"%s","window":"%s","est":%s,"created":%s,"updated":%s,"expires":%s,"pid":null,"priority":"%s"}\n' \
    "$1" "$2" "$3" "$4" "$5" $((NOW - $6)) "$NOW" $((NOW + $7)) "$8" > "$H/.claude/run-status/dispatch-queue/$1.json"
}
adm() { HOME=$H FORECAST_NOW=$NOW FORECAST_NO_SNAPSHOT=1 CODEX_PERSONAL_HOME=$H/.codex CODEX_WORK_HOME=$H/.codex-work \
        FORECAST_WORK_POLICY="${POL:-ALLOW 100 test}" node "$ENG" --admit "$@"; }
check() { # name expect_regex got [old_verdict expected_verdict_word]
  local name=$1 exp=$2 got=$3 old=${4:-}
  if printf '%s' "$got" | grep -qE "$exp"; then pass=$((pass+1)); r=PASS; else fail=$((fail+1)); r=FAIL; fi
  local note=""
  if [ -n "$old" ]; then note="  | old rule: $old"; [ "$old" != "${got%% *}" ] && oldwrong=$((oldwrong+1)); fi
  printf '%s %-58s | got: %s%s\n' "$r" "$name" "$got" "$note"
}

# 1 empty machine
home; cx 10 14400 0 30000; check "1 quiet machine: Codex M lane admitted on personal" '^ADMIT codex_personal_5h' "$(adm --provider codex --tier high --size M --task a-x --project a)"

# 2 last night 18:30Z: personal 81 % with project B's 3 L jobs 22 min in; project A's attempt
home; cx 81 16700 19 14000
for i in 1 2 3; do lane beta$i codex beta-rv$i high "$H/.codex" 1320 "$LIVE" beta 27.8; done
check "2 18:30Z collision: project A moves to the work login" '^REROUTE codex_work_5h' "$(adm --provider codex --tier high --size M --task alpha-v61-m1 --project alpha)" ADMIT
POL="DENY work login denied" check "2b same, work login not allowed -> waits for personal" '^QUEUE codex_personal_5h .* [0-9]{10} ' "$(POL="DENY work login denied" adm --provider codex --tier high --size M --task alpha-v61-m1 --project alpha)" ADMIT

# 3 agy fan-out: 70 % used, 5 project B lanes each already past their estimate (13 % measured from their logs)
home; ag 70 13000
for i in 1 2 3 4 5; do
  printf '{"type":"step_update","usage":{"input_tokens":4000000,"output_tokens":290000,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":4290000}}\n' > "$H/agy$i.log"
  lane agy$i agy beta-$i flash "" 960 "$LIVE" beta 8.3 "$H/agy$i.log"
done
check "3 agy fan-out: a new Flash lane waits for the reset" '^QUEUE agy_5h .* [0-9]{10} ' "$(adm --provider agy --tier flash --size M --task alpha-notch --project alpha)" ADMIT
rm -f "$H"/.claude/run-status/dispatch-running/agy*.json
check "3b control: same window without those lanes -> admitted" '^ADMIT agy_5h' "$(adm --provider agy --tier flash --size M --task alpha-notch2 --project alpha)"

# 4 fair share: personal 10 %, project B running, project A waiting since 5 min
home; cx 10 14400 100 14400
for i in 1 2; do lane m$i codex beta-$i high "$H/.codex" 0 "$LIVE" beta 12; done
qent alpha.alpha-v61 alpha alpha-v61 codex_personal_5h 12 300 600 normal
check "4 fair share: project B 3rd lane fits its half" '^ADMIT codex_personal_5h' "$(adm --provider codex --tier high --size M --task beta-3 --project beta --login personal)"
lane m3 codex beta-3 high "$H/.codex" 0 "$LIVE" beta 12
check "4b fair share: project B 4th lane waits (project A waiting)" '^QUEUE .*fair share' "$(adm --provider codex --tier high --size M --task beta-4 --project beta --login personal)" ADMIT
rm -f "$H/.claude/run-status/dispatch-queue/alpha.alpha-v61.json"
check "4c control: nobody waiting -> the 4th lane is admitted" '^ADMIT codex_personal_5h' "$(adm --provider codex --tier high --size M --task beta-4 --project beta --login personal)"

# 5 first come: project A queued first claims its share of the room
home; cx 50 14400 100 14400; qent alpha.big alpha big codex_personal_5h 30 300 600 normal
check "5 first come: a later lane waits behind project A's claim" '^QUEUE .*waiting first' "$(adm --provider codex --tier high --size M --task beta-x --project beta --login personal)" ADMIT
check "6 pinned lane goes ahead of the queue" '^ADMIT codex_personal_5h' "$(adm --provider codex --tier high --size M --task beta-x --project beta --login personal --priority pin)"
rm -f "$H"/.claude/run-status/dispatch-queue/*.json
check "5b control: no claim -> admitted" '^ADMIT codex_personal_5h' "$(adm --provider codex --tier high --size M --task beta-y --project beta --login personal)"

# 7 ceiling: 85 % normally, 100 % in the window's last hour
home; cx 80 1800 100 14400
check "7 last hour: 80 % + 12 % admitted (ceiling 100)" '^ADMIT .* 100 0 ' "$(adm --provider codex --tier high --size M --task t7 --project p --login personal)"
home; cx 80 7200 100 14400
check "7b two hours left: same lane waits (ceiling 85)" '^QUEUE codex_personal_5h .* [0-9]{10} ' "$(adm --provider codex --tier high --size M --task t7 --project p --login personal)" ADMIT

# 9 stale cache fails open
home; cx 99 7200 99 7200 25200
check "9 7-hour-old reading: fails open" '^ADMIT .*FAILOPEN' "$(adm --provider codex --tier high --size M --task t9 --project p --login personal)"

# 10 a dead job's marker does not hold capacity
home; cx 70 14400 100 14400; lane dead codex old high "$H/.codex" 60 999999 q 30
check "10 dead pid marker ignored -> admitted" '^ADMIT codex_personal_5h' "$(adm --provider codex --tier high --size M --task t10 --project p --login personal)"
lane dead codex old high "$H/.codex" 60 "$LIVE" q 30
check "10b control: same marker, live pid -> waits" '^QUEUE' "$(adm --provider codex --tier high --size M --task t10 --project p --login personal)" ADMIT

# 11 an expired queue entry holds nothing
home; cx 50 14400 100 14400; qent q.old q old codex_personal_5h 30 900 -10 normal
check "11 expired waiting entry ignored -> admitted" '^ADMIT codex_personal_5h' "$(adm --provider codex --tier high --size M --task t11 --project p --login personal)"
qent q.old q old codex_personal_5h 30 900 600 normal
check "11b control: live entry -> waits" '^QUEUE' "$(adm --provider codex --tier high --size M --task t11 --project p --login personal)"

# 12 size from the spec: 7 deliverables -> XL (55 % on personal) does not fit at 40 %
home; cx 40 14400 100 14400; S=$T/spec-xl.md; for i in 1 2 3 4 5 6 7; do printf '## D%s — part %s\nwork\n' $i $i; done > "$S"
check "12 spec with 7 deliverables sized XL -> waits at 40 %" '^QUEUE .* XL ' "$(adm --provider codex --tier high --spec "$S" --task t12 --project p --login personal)" ADMIT
check "12b managed attempt admitted at size M (cap-killed later)" '^ADMIT .* M ' "$(adm --provider codex --tier high --spec "$S" --admit-size M --task t12 --project p --login personal --managed --ceiling 100)"

# 13 cost model against measured windows
G=$(FORECAST_MODEL=$SEED node "$ENG" --check-budget "$PAIRS" | grep -c PASS)
R=$(FORECAST_MODEL=$SEED node "$ENG" --check-budget "$PAIRS" --weight 0 | grep -c FAIL)
check "13 cost model: 6/6 measured windows within tolerance" '^6$' "$G"
check "13b control: cache weight 0 fails the agy windows" '^[1-9]' "$R"

# R — cases from the Codex review (2026-10-25), each with its control
sleep 900 & LIVE2=$!; SLEEPERS+=("$LIVE2")
home; cx 70 14400 100 14400
check "R1 race: first of two simultaneous 12% lanes at 70% admitted" '^ADMIT' "$(adm --provider codex --tier high --size M --task r1a --project a --login personal --pid $LIVE)"
check "R1b race: the second sees the first's claim and waits" '^QUEUE' "$(adm --provider codex --tier high --size M --task r1b --project b --login personal --pid $LIVE2)" ADMIT
lane r1a codex r1a high "$H/.codex" 0 "$LIVE" a 12.3
check "R1c claim replaced by the running marker, not counted twice" '^QUEUE .* 82.3 85 ' "$(adm --provider codex --tier high --size M --task r1c --project c --login personal --dry-run)"
home; cx 0 14400 100 14400; qent b.codex.big b big codex_personal_5h 55.5 120 600 normal; qent a.codex.big a big codex_personal_5h 55.5 60 600 normal
check "R2 two 55% waiters on an idle window: the older one starts" '^ADMIT' "$(adm --provider codex --tier high --size XL --task big --project b --login personal --pid $LIVE)"
check "R2b ... and the younger one waits behind it (first come)" '^QUEUE' "$(adm --provider codex --tier high --size XL --task big --project a --login personal --dry-run)"
home; cx 0 14400 100 14400; python3 - "$H/.claude/codex-rate-limits.json" <<'PYX'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["profiles"]=[x for x in d["profiles"] if x["name"]!="personal"]; json.dump(d,open(p,"w"))
PYX
check "R3 no personal reading + work denied -> fail open, not queue" '^ADMIT codex_personal_5h .*FAILOPEN' "$(POL='DENY denied' adm --provider codex --tier high --size M --task r3 --project a)"
home; cx 0 14400 100 14400; sed -i '' 's/"used_percent":0,/"used_percent":"broken",/' "$H/.claude/codex-rate-limits.json"
check "R4 corrupt usage value -> fail open" '^ADMIT .*FAILOPEN' "$(adm --provider codex --tier high --size M --task r4 --project a --login personal)"
home; cx 0 14400 100 14400; qent q.bad q bad codex_personal_5h '"broken"' 60 600 normal
check "R4b corrupt queue estimate ignored" '^ADMIT .*fits' "$(adm --provider codex --tier high --size M --task r4b --project a --login personal)"
home; cx 0 14400 100 14400
adm --provider codex --tier high --size M --task same --project a --login personal --pid "$LIVE" --wait >/dev/null; mv "$H/.claude/run-status/dispatch-queue/admitted.$LIVE.json" "$T/x.json"
cx 95 14400 100 14400
adm --provider codex --tier high --size M --task t-m1 --project a --login personal --pid "$LIVE" --wait >/dev/null
adm --provider agy --tier flash --size M --task t-m1 --project a --pid "$LIVE2" --wait >/dev/null 2>&1; ag 95 14400
adm --provider agy --tier flash --size M --task t-m1 --project a --pid "$LIVE2" --wait >/dev/null
check "R5 two waiters of one project keep separate entries" '^2$' "$(ls "$H/.claude/run-status/dispatch-queue" | grep -c 'waiting\|^a\.')"
home; cx 70 14400 100 14400
printf '{"key":"q.dead","state":"waiting","project":"q","task":"x","window":"codex_personal_5h","est":30,"created":%s,"updated":%s,"expires":%s,"pid":999999,"priority":"normal"}\n' $NOW $NOW $((NOW+300)) > "$H/.claude/run-status/dispatch-queue/q.dead.json"
check "R7 waiting entry whose process died holds nothing" '^ADMIT' "$(adm --provider codex --tier high --size M --task r7 --project a --login personal)"
home; cx 60 14400 100 14400; D=$H/.codex/sessions/$(date -r $NOW +%Y/%m/%d); mkdir -p "$D"
ts() { python3 -c "import datetime,sys;print(datetime.datetime.fromtimestamp(float(sys.argv[1]),datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z'))" "$1"; }
printf '{"timestamp":"%s","type":"session_meta","payload":{"originator":"codex_tui"}}\n{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":360000,"cached_input_tokens":0,"output_tokens":0}}}}\n' "$(ts $((NOW-10)))" "$(ts $NOW)" > "$D/rollout-interactive.jsonl"
printf '{"timestamp":"%s","type":"session_meta","payload":{"originator":"codex_exec"}}\n' "$(ts $NOW)" > "$D/rollout-dispatch.jsonl"
touch "$D"/rollout-*.jsonl
lane r8 codex r8 high "$H/.codex" 0 "$LIVE" a 30
check "R8 interactive Codex rollout is not read as the dispatch's usage" '^QUEUE .* 90 85 ' "$(adm --provider codex --tier high --size M --task r8n --project b --login personal --dry-run)" ADMIT
home; NOWS=$NOW; printf '{"fetched_at":%s,"source":"t","groups":{"gemini":{"five_hour":{"used_percent":50,"resets_at":%s}}}}\n' $((NOW-300)) $((NOW+14000)) > "$H/.claude/agy-quota.json"
printf '{"type":"step_update","usage":{"input_tokens":9900000,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":9900000}}\n' > "$H/a9.log"
lane r9 agy r9 flash "" 200 "$LIVE" a 30 "$H/a9.log"
check "R9 spend since the cache reading counts (50 + 30 unreported + 9)" '^QUEUE agy_5h .* 89 85 ' "$(adm --provider agy --tier flash --size M --task r9n --project b --dry-run)" ADMIT
home; cx 0 14400 100 14400; lane r10 codex r10 high "$H/.codex" 7200 "$LIVE" a 24
check "R10 fair share ignores spend from before the window reset" '^ADMIT' "$(adm --provider codex --tier high --size M --task r10n --project a --login personal --dry-run)"
check "R11 a session title with spaces becomes one safe project token" '^ADMIT codex_personal_5h [0-9.]+ [0-9.]+ 85 0 my-project-name M ' "$(home; cx 0 14400 100 14400; adm --provider codex --tier high --size M --task r11 --project 'My Project Name' --login personal --dry-run)"

# 14 wrappers end to end (fake codex on PATH, sandbox HOME, real clock)
WR=$T/wrap; mkdir -p "$WR/bin"
cat > "$WR/bin/codex" <<'SHIM'
#!/usr/bin/env bash
echo "mock run complete"; echo "tokens used"; echo "1,234"; exit 0
SHIM
chmod +x "$WR/bin/codex"
printf 'Add a CSV export endpoint.\n' > "$WR/spec.md"
wrap_home() { NOW=$(date +%s); home; ln -s "$ENG" "$H/.claude/scripts/quota-forecast.mjs"; }
wrun() { env -u DISPATCH_FORCE -u DISPATCH_GATE_JSON -u CLAUDE_PID -u CODEX_FALLBACK -u CODEX_HOME -u CODEX_PROFILES -u DISPATCH_ADMIT -u DISPATCH_SIZE -u DISPATCH_PRIORITY HOME="$H" PATH="$WR/bin:$PATH" CODEX_PROFILE="$H/.codex" CODEX_TIER=high \
  CODEX_ROUTER=off LLM_LEDGER_SKIP=1 FORECAST_NO_SNAPSHOT=1 CODEX_TOKEN_LEDGER_FILE="$H/ledger.jsonl" "$@" </dev/null; }
wrap_home; cx 90 7200 100 7200
wrun DISPATCH_ADMIT_WAIT=0 bash "$REAL/codex-dispatch.sh" "$WR/spec.md" fc-wrap-a > "$WR/a.out" 2>&1; rc=$?
nlogs=$(ls "$H/.claude/logs" 2>/dev/null | grep -c '^codex-' || true)
check "14a codex-dispatch, personal full: exit 4, no run, no log" '^4 QUEUED 0$' "$rc $(grep -o 'QUEUED' "$WR/a.out" | head -1) $nlogs" 0
wrap_home; cx 10 7200 100 7200
wrun bash "$REAL/codex-dispatch.sh" "$WR/spec.md" fc-wrap-b > "$WR/b.out" 2>&1; rc=$?
check "14b codex-dispatch, room: runs, log + ledger carry the estimate" '^0 \[admission\] ADMIT codex_personal_5h .*"est_pct":12.3' "$rc $(grep -h '^\[admission\]' "$H"/.claude/logs/codex-*.log | head -1 | cut -c1-40) $(cat "$H/ledger.jsonl" 2>/dev/null)"
wrap_home; cx 90 7200 100 7200; echo "{" > "$H/.claude/quota-cost-model.json"   # unreadable (a missing one is re-created from the seed)
wrun bash "$REAL/codex-dispatch.sh" "$WR/spec.md" fc-wrap-c > "$WR/c.out" 2>&1; rc=$?
check "14c unreadable cost model: fails OPEN and runs" '^0 admission: unavailable — failing OPEN' "$rc $(grep -m1 '^admission: unavailable' "$WR/c.out" | cut -c1-40)"
wrap_home; cx 90 7200 100 7200
wrun DISPATCH_ADMIT_POLL=2 DISPATCH_ADMIT_MAX_WAIT=4 bash "$REAL/codex-dispatch.sh" "$WR/spec.md" fc-wrap-d > "$WR/d.out" 2>&1; rc=$?
check "14d waits in place, re-checks, gives up at the max wait" '^4 1 1$' "$rc $(grep -c 'waiting here' "$WR/d.out") $(grep -c 'Not started' "$WR/d.out")"
wrap_home; ag 90 7200
env -u DISPATCH_FORCE -u DISPATCH_GATE_JSON -u DISPATCH_ADMIT -u AGY_TIER -u AGY_MODEL HOME="$H" FORECAST_NO_SNAPSHOT=1 DISPATCH_ADMIT_WAIT=0 bash "$REAL/gemini-dispatch.sh" "$WR/spec.md" fc-wrap-e > "$WR/e.out" 2>&1 </dev/null; rc=$?
check "14e gemini-dispatch, agy full: exit 4 before any run" '^4 QUEUED$' "$rc $(grep -o 'QUEUED' "$WR/e.out" | head -1)" 0
wrap_home; cx 90 7200 100 7200
wrun DISPATCH_FORCE=1 bash "$REAL/codex-dispatch.sh" "$WR/spec.md" fc-wrap-f > "$WR/f.out" 2>&1; rc=$?
check "14f DISPATCH_FORCE=1 (tests, overrides) bypasses admission" '^0 1$' "$rc $(grep -c 'admission: bypassed by DISPATCH_FORCE=1' "$WR/f.out")"

# C Claude subagents (added 2026-10-25): a running agent's transcript is measured (each message counted once) and lands
#   in the Claude 5h projection; a transcript idle > 2 min is a finished agent and is not counted
cagent() { # name age_secs -> transcript with 2 messages, the first streamed twice (same id)
  local d=$H/.claude/projects/-p/sess-1/subagents; mkdir -p "$d"
  local u='"usage":{"input_tokens":1000,"cache_creation_input_tokens":9000,"output_tokens":1000,"cache_read_input_tokens":100000}'
  { printf '{"timestamp":"%s","type":"user","message":{"content":"x"}}\n' "$(iso $((NOW - 300)))"
    printf '{"type":"assistant","message":{"id":"m1","model":"claude-sonnet-5-5",%s}}\n' "$u"
    printf '{"type":"assistant","message":{"id":"m1","model":"claude-sonnet-5-5",%s}}\n' "$u"
    printf '{"type":"assistant","message":{"id":"m2","model":"claude-sonnet-5-5",%s}}\n' "$u"; } > "$d/agent-$1.jsonl"
  printf '{"description":"Fix the build","model":"sonnet"}\n' > "$d/agent-$1.meta.json"
  python3 -c "import os,sys;os.utime(sys.argv[1],(float(sys.argv[2]),)*2)" "$d/agent-$1.jsonl" $((NOW - $2))
}
cjson() { HOME=$H FORECAST_NOW=$NOW FORECAST_NO_SNAPSHOT=1 CODEX_PERSONAL_HOME=$H/.codex CODEX_WORK_HOME=$H/.codex-work node "$ENG" --json \
  | python3 -c "import json,sys;d=json.load(sys.stdin);l=[x for x in d['lanes'] if x['provider']=='claude'];print('claude_lanes=%d fresh=%s task=%s' % (len(l),[x['fresh'] for x in l],[x['task'] for x in l]))"; }
home; printf '{"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":%s}}}\n' $((NOW + 9000)) > "$H/.claude/.session-state.json"
cagent a1 30
check "C1 running Claude agent measured once per message (42000 fresh-eq)" "^claude_lanes=1 fresh=\\[42000(\\.0)?\\] task=\\['fix-the-build'\\]" "$(cjson)"
home; cagent a2 600
check "C2 control: an agent idle 10 min is finished, not counted" '^claude_lanes=0 ' "$(cjson)"

# F window-budget refit: per-period tokens ÷ % moved from Codex rollouts; applied only with >= 8 periods AND the measured
#   before/after pairs still passing
rollouts() { # n_periods tokens_per_period pct_per_period -> one rollout per period in the sandbox personal home
  python3 - "$H/.codex" "$NOW" "$1" "$2" "$3" <<'PY'
import json,os,sys,datetime
home,now,n,tok,pct=sys.argv[1],int(sys.argv[2]),int(sys.argv[3]),int(sys.argv[4]),float(sys.argv[5])
for i in range(n):
    start=now-(i+1)*20000; d=datetime.datetime.fromtimestamp(start); dd=os.path.join(home,'sessions',d.strftime('%Y'),d.strftime('%m'),d.strftime('%d')); os.makedirs(dd,exist_ok=True)
    f=os.path.join(dd,'rollout-%d.jsonl'%i)
    with open(f,'w') as fh:
        for k,(t,fr,u) in enumerate([(start,0,0),(start+600,tok//2,pct/2),(start+1200,tok,pct)]):
            ts=datetime.datetime.fromtimestamp(t,datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')
            fh.write(json.dumps({"timestamp":ts,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":fr,"cached_input_tokens":0,"output_tokens":0}},"rate_limits":{"primary":{"used_percent":u,"resets_at":start+18000}}}})+"\n")
    os.utime(f,(now-60,now-60))
PY
}
pairs() { printf '{"cases":[{"name":"t","window":"codex_personal_5h","provider":"codex","fresh":%s,"cache":0,"before":0,"after":%s,"tol":8}]}\n' "$1" "$2" > "$H/pairs.json"; }
refit() { HOME=$H FORECAST_NOW=$NOW CODEX_PERSONAL_HOME=$H/.codex CODEX_WORK_HOME=$H/.codex-work FORECAST_BUDGET_PAIRS=$H/pairs.json \
  FORECAST_CLAUDE_PROJECTS=$H/none node "$ENG" --refit-budgets $1 | grep '^codex_personal_5h'; }
home; rollouts 9 400000 40; pairs 500000 50
check "F1 9 windows at 1.0M agree with the measured pair -> applied" '^codex_personal_5h: applied — fit 1000000 \(-17 %\)' "$(refit --apply)"
check "F1b the model file now holds 1.0M" '^1000000$' "$(python3 -c "import json;print(json.load(open('$H/.claude/quota-cost-model.json'))['window_100']['codex_personal_5h'])")"
home; rollouts 9 400000 40; pairs 987064 81
check "F2 same history, measured pair says 1.2M -> kept" '^codex_personal_5h: kept — fit 1000000 contradicts' "$(refit --apply)"
home; rollouts 5 400000 40; pairs 500000 50
check "F3 only 5 windows -> kept" '^codex_personal_5h: kept — 5 usable windows, need 8' "$(refit --apply)"

# S single Codex login: the cache written by scripts/codex-rate-limits-refresh.mjs ({rate_limits:{primary:…}})
one() { printf '{"fetched_at":"%s","rate_limits":{"primary":{"used_percent":%s,"window_minutes":300,"resets_at":%s},"secondary":null,"reached_type":null}}\n' \
  "$(iso $((NOW - 30)))" "$1" $((NOW + 7200)) > "$H/.claude/codex-rate-limits.json"; }
home; one 90
check "S1 single-login cache at 90 %: a Codex job waits" '^QUEUE codex_personal_5h ' "$(adm --provider codex --tier high --size M --task s1 --project a --dry-run)" ADMIT
home; one 10
check "S1b control: same cache at 10 % -> admitted" '^ADMIT codex_personal_5h ' "$(adm --provider codex --tier high --size M --task s1 --project a --dry-run)"
home; one 10; rm -f "$H/.claude/quota-cost-model.json"; mkdir -p "$H/eng"; cp "$ENG" "$REAL/quota-cost-model.seed.json" "$H/eng/"
HOME=$H FORECAST_NOW=$NOW FORECAST_NO_SNAPSHOT=1 CODEX_PERSONAL_HOME=$H/.codex CODEX_WORK_HOME=$H/.codex-work node "$H/eng/quota-forecast.mjs" \
  --admit --provider codex --tier high --size M --task s2 --project a --dry-run > "$H/s2.out"
check "S2 first run: the cost model is created from the shipped seed" '^ADMIT codex_personal_5h .*fits.* crewline$' \
  "$(head -1 "$H/s2.out") $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["source"].split()[0])' "$H/.claude/quota-cost-model.json" 2>&1)"

echo "GREEN $pass pass, $fail fail | RED today's rule (floor gate only) would admit on $oldwrong cases where the forecast must not"
[ "$fail" -eq 0 ]
