#!/usr/bin/env bash
# Tests for bin/gpu-run that need no graphics card: argument parsing, the off switch, the token
# pool, admission, the log line (with a fake sampler, event query and idle check) and the report
# from a fixture. Every job is a dummy command; the locks are files in a temporary folder.
# Run: bin/gpu-run.test.sh
set -euo pipefail
run="$(cd "$(dirname "$0")" && pwd)/gpu-run"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GPU_RUN_STATE="$tmp/state" GPU_RUN_LOCK="$tmp/card-{n}.lock"
unset TEST_NO_GPU TEST_GPU_JOBS TEST_GPU_SLOT_HELD TEST_GPU_TOKENS
slot() { echo "$tmp/card-$1.lock"; }
log="$GPU_RUN_STATE/jobs.jsonl"
GiB=1073741824
# Admission reads the last few load readings before a job starts (ADMIT_WINDOW_S at the
# sampler's interval); the fakes give that many calm ones first, so the job starts on them.
calm_n="$(awk -v w="$(grep -oP '^ADMIT_WINDOW_S = \K\d+' "$run")" -v i="$(grep -oP '^INTERVAL = \K[\d.]+' "$run")" \
  'BEGIN { n = w / i; print (n == int(n)) ? n : int(n) + 1 }')"
calm() { # calm temp: the readings admission looks at, on a cool, quiet card
  local i
  for i in $(seq "$calm_n"); do
    echo "echo '{\"t\":1,\"load\":0,\"types\":{},\"used\":$((4 * GiB)),\"top\":[[\"dwm\",$((2 * GiB))]],\"cpu\":1.0,\"temp\":$1,\"fan\":800}'"
  done
}

# A fake sampler: a first sample, calm ones, a pause (so the job starts after them), then busier samples.
cat >"$tmp/sampler" <<EOF
#!/bin/sh
echo '{"t":1,"load":null,"types":{},"used":$((4 * GiB)),"top":[["dwm",$((2 * GiB))]],"cpu":1.0,"adapter":"Test Card","total":$((16 * GiB)),"temp":45.5,"fan":800}'
$(calm 45.5)
sleep 1
while :; do
  echo '{"t":2,"load":50.5,"types":{"3d":50.5,"compute 0":12},"used":$((7 * GiB)),"top":[["blender",$((3 * GiB))],["dwm",$((2 * GiB))]],"cpu":1.5,"temp":61,"fan":1450}'
  sleep 0.1
done
EOF
# A card that is too hot, and one whose temperature cannot be read (older driver).
cat >"$tmp/hot" <<EOF
#!/bin/sh
while :; do echo '{"t":1,"load":0,"types":{},"used":$GiB,"top":[],"cpu":1,"adapter":"Test Card","total":$((16 * GiB)),"temp":88.2,"fan":2600}'; sleep 0.1; done
EOF
cat >"$tmp/no-temp" <<EOF
#!/bin/sh
while :; do echo '{"t":1,"load":0,"types":{},"used":$GiB,"top":[],"cpu":1,"adapter":"Test Card","total":$((16 * GiB))}'; sleep 0.1; done
EOF
# A card that heats up once the job starts, one with a single hot reading, and one whose
# temperature can no longer be read after the start.
cat >"$tmp/heats-up" <<EOF
#!/bin/sh
echo '{"t":1,"load":0,"types":{},"used":$GiB,"top":[],"cpu":1,"adapter":"Test Card","total":$((16 * GiB)),"temp":50}'
$(calm 50)
sleep 1
while :; do echo '{"t":2,"load":90,"types":{},"used":$GiB,"top":[],"cpu":1,"temp":95.5}'; sleep 0.1; done
EOF
cat >"$tmp/one-spike" <<EOF
#!/bin/sh
echo '{"t":1,"load":0,"types":{},"used":$GiB,"top":[],"cpu":1,"adapter":"Test Card","total":$((16 * GiB)),"temp":50}'
$(calm 50)
sleep 1
echo '{"t":2,"load":90,"types":{},"used":$GiB,"top":[],"cpu":1,"temp":95.5}'
while :; do echo '{"t":3,"load":90,"types":{},"used":$GiB,"top":[],"cpu":1,"temp":60}'; sleep 0.1; done
EOF
cat >"$tmp/loses-temp" <<EOF
#!/bin/sh
echo '{"t":1,"load":0,"types":{},"used":$GiB,"top":[],"cpu":1,"adapter":"Test Card","total":$((16 * GiB)),"temp":50}'
$(calm 50)
sleep 1
while :; do echo '{"t":2,"load":90,"types":{},"used":$GiB,"top":[],"cpu":1}'; sleep 0.1; done
EOF
# Admission: a card that stays busy, full or warm, and one whose load is read from a file (so a
# test can let it settle while a job waits).
for fake in "busy 90 $GiB 50" "full 5 $((15 * GiB)) 50" "warm 5 $GiB 82"; do
  set -- $fake
  printf '#!/bin/sh\nwhile :; do echo %s; sleep 0.05; done\n' \
    "'{\"t\":1,\"load\":$2,\"types\":{},\"used\":$3,\"top\":[],\"cpu\":1,\"adapter\":\"Test Card\",\"total\":$((16 * GiB)),\"temp\":$4}'" >"$tmp/$1"
done
echo 90 >"$tmp/load"
cat >"$tmp/settles" <<EOF
#!/bin/sh
while :; do echo "{\"t\":1,\"load\":\$(cat "$tmp/load"),\"types\":{},\"used\":$GiB,\"top\":[],\"cpu\":1,\"adapter\":\"Test Card\",\"total\":$((16 * GiB)),\"temp\":50}"; sleep 0.05; done
EOF
chmod +x "$tmp"/hot "$tmp"/no-temp "$tmp"/heats-up "$tmp"/one-spike "$tmp"/loses-temp "$tmp"/busy "$tmp"/full "$tmp"/warm "$tmp"/settles
printf '#!/bin/sh\necho "[]"\n' >"$tmp/no-events"
# The event query gets the window's start and end (Unix seconds) as its last two arguments.
printf '#!/bin/sh\necho %s\n' "'{\"time\":\"2026-11-01T20:36:35-08:00\",\"log\":\"Application\",\"provider\":\"Windows Error Reporting\",\"id\":1001,\"text\":\"LiveKernelEvent 141\"}'" >"$tmp/one-event"
# Driver reports some minutes before now, for admission's look-back only (a job's own window gets
# none): one line per report in $EVENTS_AGO, "<minutes ago> plain|processed". A processed report
# carries a fault bucket, as Windows files it later for the same timeout.
cat >"$tmp/events-ago" <<'EOF'
#!/bin/sh
[ $(($2 - $1)) -ge 600 ] || { echo "[]"; exit 0; }
sep=""; printf '['
while read -r ago kind; do
  [ -n "$ago" ] || continue
  bucket=""; [ "$kind" = processed ] && bucket="LKD_0x141_Tdr:C_IMAGE_amdkmdag.sys"
  printf '%s{"time":"%s","log":"Application","provider":"Windows Error Reporting","id":1001,"text":"Fault bucket %s, type 0 Event Name: LiveKernelEvent P1: 141"}' \
    "$sep" "$(date -d "@$(($2 - ago * 60))" +%Y-%m-%dT%H:%M:%S%:z)" "$bucket"
  sep=","
done <"$EVENTS_AGO"
echo ']'
EOF
# An event during the job itself: only a window shorter than the admission look-back gets it.
cat >"$tmp/job-event" <<'EOF'
#!/bin/sh
[ $(($2 - $1)) -lt 600 ] || { echo "[]"; exit 0; }
echo "{\"time\":\"$(date -d "@$1" +%Y-%m-%dT%H:%M:%S%:z)\",\"log\":\"Application\",\"provider\":\"Windows Error Reporting\",\"id\":1001,\"text\":\"LiveKernelEvent 141\"}"
EOF
chmod +x "$tmp/events-ago" "$tmp/job-event"
printf '#!/bin/sh\necho %s\n' "'{\"idle_min\":2,\"state\":5}'" >"$tmp/idle-2"
printf '#!/bin/sh\necho %s\n' "'{\"idle_min\":60,\"state\":3}'" >"$tmp/fullscreen"
chmod +x "$tmp"/sampler "$tmp"/no-events "$tmp"/one-event "$tmp"/idle-2 "$tmp"/fullscreen
export GPU_RUN_SAMPLER="$tmp/sampler" GPU_RUN_EVENTS="$tmp/no-events"

fail=0 n=0
ok() { # VERBOSE=1 also prints the last output of a failing check
  n=$((n + 1))
  if ! eval "$2"; then
    fail=$((fail + 1)); echo "FAIL: $1"
    [ -z "${VERBOSE:-}" ] || printf '%s\n' "${out:-}" | tail -n 6 | sed 's/^/  | /'
  fi
}
last() { tail -n 1 "$log" | jq -r "$1"; }

# Arguments.
rc=0; "$run" >/dev/null 2>&1 || rc=$?
ok "no arguments is a usage error" '[ "$rc" = 2 ]'
rc=0; "$run" -- true >/dev/null 2>&1 || rc=$?
ok "a job needs a label" '[ "$rc" = 2 ]'
rc=0; "$run" --label x --kind nonsense -- true >/dev/null 2>&1 || rc=$?
ok "an unknown kind is refused" '[ "$rc" = 2 ]'
rc=0; "$run" --watch 1 -- true >/dev/null 2>&1 || rc=$?
ok "--watch takes no command" '[ "$rc" = 2 ]'
rc=0; "$run" --report --since yesterday >/dev/null 2>&1 || rc=$?
ok "a bad --since date is refused" '[ "$rc" != 0 ]'
rc=0; "$run" --label x --tokens 0 -- touch "$tmp/ran-tokens" >/dev/null 2>&1 || rc=$?
ok "--tokens 0 is a usage error" '[ "$rc" = 2 ] && [ ! -e "$tmp/ran-tokens" ]'
for bad in -1 nan inf; do
  rc=0; "$run" --label x --admit-wait "$bad" -- touch "$tmp/ran-admit" >/dev/null 2>&1 || rc=$?
  ok "--admit-wait $bad is a usage error" '[ "$rc" = 2 ] && [ ! -e "$tmp/ran-admit" ]'
done

# A job: exit code, log line, card figures, no environment, home shortened.
out="$(SECRET_MARKER=hunter2 "$run" --label "probe" --kind browser-test -- sh -c 'sleep 1.5; exit 7' "$HOME/x" 2>&1)" && rc=0 || rc=$?
ok "the command's exit code comes back" '[ "$rc" = 7 ]'
ok "one JSON line per job" '[ "$(wc -l <"$log")" = 1 ] && jq -e . "$log" >/dev/null'
ok "label, kind and exit are logged" '[ "$(last "[.label,.kind,.exit,.cpu_run,.lock] | @tsv")" = "$(printf "probe\tbrowser-test\t7\tfalse\theld")" ]'
ok "the home path is shortened" '[[ "$(last .cmd)" == *"~/x"* ]] && ! grep -q "$HOME" "$log"'
ok "no environment in the log" '! grep -q hunter2 "$log"'
ok "peak load from the samples" '[ "$(last .gpu.load_peak)" = 50.5 ]'
ok "peak video memory" '[ "$(last ".gpu.vram_used_peak_gb == 7")" = true ]'
ok "free video memory before the job" '[ "$(last ".gpu.vram_free_before_gb == 12")" = true ]'
ok "top processes by video memory" '[ "$(last ".gpu.top_vram_gb[0][0]")" = blender ]'
ok "wall time is measured" '[ "$(last ".wall_s >= 1.4")" = true ]'
ok "load average is logged" '[ "$(last ".loadavg_start | length")" = 3 ]'
ok "no driver events" '[ "$(last ".driver_events | length")" = 0 ]'
ok "a three-line summary" '[ "$(wc -l <<<"$out")" = 3 ] && [[ "$out" == *"Test Card load peak 50.5%"* ]]'
ok "temperature at the start, at the peak and at the end" '[ "$(last "[.gpu.temp_c_start,.gpu.temp_c_peak,.gpu.temp_c_end] | @tsv")" = "$(printf "45.5\t61\t61")" ]'
ok "peak fan speed" '[ "$(last .gpu.fan_rpm_peak)" = 1450 ]'
ok "a job record has no temperature trace" '[ "$(last ".gpu | has(\"temp_c_trace\")")" = false ]'
ok "the summary shows the temperature" '[[ "$out" == *"45.5 C at the start, peak 61 C, fan peak 1450 rpm"* ]]'

# --max-temp.
lines="$(wc -l <"$log")"
rc=0; out="$(GPU_RUN_SAMPLER="$tmp/hot" "$run" --max-temp 85 --label hot -- touch "$tmp/ran-hot" 2>&1)" || rc=$?
ok "--max-temp refuses while the card is too hot" '[ "$rc" = 5 ] && [[ "$out" == *"88.2 C (wanted at most 85 C)"* ]] && [ ! -e "$tmp/ran-hot" ] && [ "$(wc -l <"$log")" = "$lines" ]'
rc=0; out="$(GPU_RUN_SAMPLER="$tmp/no-temp" "$run" --max-temp 85 --label unknown -- touch "$tmp/ran-unknown" 2>&1)" || rc=$?
ok "--max-temp refuses when the temperature cannot be read" '[ "$rc" = 5 ] && [[ "$out" == *"could not be read"* ]] && [ ! -e "$tmp/ran-unknown" ]'
rc=0; "$run" --max-temp 85 --label cool -- true >/dev/null || rc=$?
ok "--max-temp runs a job on a cool card" '[ "$rc" = 0 ]'
rc=0; out="$(GPU_RUN_SAMPLER="$tmp/no-temp" "$run" --label unknown -- true)" || rc=$?
ok "without --max-temp an unreadable temperature is left out" '[ "$rc" = 0 ] && [ "$(last ".gpu | has(\"temp_c_peak\")")" = false ] && [[ "$out" != *" C at the start"* ]]'
for bad in nan -5 0 111; do
  rc=0; "$run" --max-temp "$bad" --label bad -- touch "$tmp/ran-bad" >/dev/null 2>&1 || rc=$?
  ok "--max-temp $bad is a usage error" '[ "$rc" = 2 ] && [ ! -e "$tmp/ran-bad" ]'
done

# --max-temp during the job.
t0=$SECONDS
rc=0; out="$(GPU_RUN_SAMPLER="$tmp/heats-up" "$run" --max-temp 85 --label heat -- sh -c 'sleep 30 & sleep 30; touch "$1"' sh "$tmp/finished-heat" 2>&1)" || rc=$?
ok "three hot readings stop the job with exit 5" '[ "$rc" = 5 ] && [ ! -e "$tmp/finished-heat" ] && [ $((SECONDS - t0)) -lt 15 ]'
ok "the stop says why in one line" '[ "$(grep -c "stopping the job" <<<"$out")" = 1 ] && [[ "$out" == *"above 85 C for 3 readings (peak 95.5 C)"* ]]'
ok "the stop is logged with the peak, and nothing is left running" '[ "$(last ".stopped_for_heat and .heat_peak_c == 95.5 and .max_temp_c == 85 and .left_running == []")" = true ]'
rc=0; GPU_RUN_SAMPLER="$tmp/one-spike" "$run" --max-temp 85 --label spike -- sleep 1.5 >/dev/null || rc=$?
ok "one hot reading does not stop the job" '[ "$rc" = 0 ] && [ "$(last ".stopped_for_heat,.gpu.temp_c_peak" | tr "\n" " ")" = "false 95.5 " ]'
rc=0; GPU_RUN_SAMPLER="$tmp/heats-up" "$run" --label no-limit -- sleep 1.5 >/dev/null || rc=$?
ok "without --max-temp a hot card does not stop the job" '[ "$rc" = 0 ] && [ "$(last "has(\"stopped_for_heat\")")" = false ]'
rc=0; GPU_RUN_SAMPLER="$tmp/loses-temp" "$run" --max-temp 85 --label lost -- sleep 1.5 >/dev/null || rc=$?
ok "readings missing mid-job do not stop it and are counted" '[ "$rc" = 0 ] && [ "$(last ".stopped_for_heat,(.temp_readings_missing > 0)" | tr "\n" " ")" = "false true " ]'

# CPU time counts orphaned grandchildren too.
"$run" --label busy -- sh -c 'python3 -c "import time
t = time.process_time()
while time.process_time() - t < 0.6: pass" & exit 0' >/dev/null
ok "CPU time includes an orphaned grandchild" '[ "$(last ".cpu_s >= 0.5")" = true ] && [ "$(last .cpu_complete)" = true ]'

# The token pool: a job takes one token, or --tokens N, waits while too few are free, and holds
# them while it runs; a heavy job takes every token. The command draws only on what its job
# holds (TEST_GPU_TOKENS), and the old test helper still finds a file of its own (the shim).
default_slots="$(grep -oP '^DEFAULT_SLOTS = \K\d+' "$run")"
"$run" --label held -- sh -c '! flock -n "$(echo "$GPU_RUN_LOCK" | sed "s/{n}/1/")" true && [ "$TEST_GPU_TOKENS" = "'"$(slot 1)"'" ] && [ "$TEST_GPU_JOBS" = '"$((default_slots + 1))"' ] && [ "$TEST_GPU_SLOT_HELD" = 1 ]' >/dev/null
ok "a job holds token 1 while it runs and passes it down; an old helper gets one more file than the pool" '[ "$(last ".exit,.slots[0],.tokens,.lock" | tr "\n" " ")" = "0 1 1 held " ]'
ok "the pool holds $default_slots tokens by default" '[ "$default_slots" = 3 ]'
export TEST_GPU_JOBS=2
flock "$(slot 1)" sleep 1.5 &
holder=$!
sleep 0.3
"$run" --label second -- sh -c '! flock -n "'"$(slot 2)"'" true && [ "$TEST_GPU_JOBS" = 3 ] && [ "$TEST_GPU_TOKENS" = "'"$(slot 2)"'" ]' >/dev/null
wait "$holder"
ok "with token 1 in use a job takes token 2 at once" '[ "$(last ".exit,.slots[0]" | tr "\n" " ")" = "0 2 " ] && [ "$(last ".lock_wait_s < 1")" = true ]'
flock "$(slot 1)" sleep 2 &
h1=$!
flock "$(slot 2)" sleep 2 &
h2=$!
sleep 0.3
out="$("$run" --label wait -- true 2>&1)"
wait "$h1" "$h2"
ok "a job waits while every token is in use, and says so" '[[ "$out" == *"needs 1 of the card'"'"'s 2 tokens (one per browser drawing at once), and too few are free"* ]] && [ "$(last ".lock_wait_s >= 1")" = true ]'
"$run" --label render --kind blender -- sh -c '! flock -n "'"$(slot 1)"'" true && ! flock -n "'"$(slot 2)"'" true && [ "$TEST_GPU_TOKENS" = "'"$(slot 1):$(slot 2)"'" ]' >/dev/null
ok "a heavy job holds every token" '[ "$(last ".exit,(.slots | length)" | tr "\n" " ")" = "0 2 " ]'
flock "$(slot 2)" sleep 1.5 &
holder=$!
sleep 0.3
out="$("$run" --label render --kind image -- true 2>&1)"
wait "$holder"
ok "a heavy job waits for a test job on any token" '[[ "$out" == *"needs 2 of the card'"'"'s 2 tokens"* ]] && [ "$(last ".lock_wait_s >= 1")" = true ]'
flock "$(slot 2)" sleep 1.5 &
holder=$!
sleep 0.3
"$run" --label render --kind model -- sh -c '! flock -n "'"$(slot 1)"'" true' >/dev/null 2>&1
wait "$holder"
ok "a heavy job does not sit on a free token while it waits for the rest" '[ "$(last ".exit,(.slots | length)" | tr "\n" " ")" = "0 2 " ]'
export TEST_GPU_JOBS=3
"$run" --label gate --tokens 2 -- sh -c '! flock -n "'"$(slot 1)"'" true && ! flock -n "'"$(slot 2)"'" true && flock -n "'"$(slot 3)"'" true && [ "$TEST_GPU_TOKENS" = "'"$(slot 1):$(slot 2)"'" ]' >/dev/null
ok "--tokens 2 holds two tokens and leaves the third free" '[ "$(last ".exit,.tokens,(.slots | join(\",\"))" | tr "\n" " ")" = "0 2 1,2 " ]'
out="$("$run" --label greedy --tokens 5 -- true 2>&1)"
ok "--tokens above the pool takes the whole pool, and says so" '[[ "$out" == *"--tokens 5 is more than the 3 there are"* ]] && [ "$(last ".exit,.tokens" | tr "\n" " ")" = "0 3 " ]'
flock "$(slot 2)" sleep 1.5 &
holder=$!
sleep 0.3
"$run" --label one -- true >/dev/null
wait "$holder"
ok "a one-token job takes a free token beside a held one" '[ "$(last ".exit,.slots[0],(.lock_wait_s < 1)" | tr "\n" " ")" = "0 1 true " ]'

# Inside a job, gpu-run and the commands it runs draw only on the job's tokens: three inner jobs
# under a two-token job run two at a time and never take the pool's third token.
mkdir -p "$tmp/active"
cat >"$tmp/inner" <<EOF
#!/bin/sh
# One inner job: notes how many inner jobs are running with it, and whether pool token 3 is free.
touch "$tmp/active/\$\$"
ls "$tmp/active" | wc -l >>"$tmp/peaks"
flock -s -n "$(slot 3)" true && echo free >>"$tmp/third" || echo taken >>"$tmp/third"  # shared: siblings do not collide
sleep 1
rm -f "$tmp/active/\$\$"
EOF
chmod +x "$tmp/inner"
lines="$(wc -l <"$log")"
t0=$SECONDS
"$run" --label outer --tokens 2 -- sh -c '
  for i in 1 2 3; do "$1" --label "inner $i" -- "$2" & done
  wait' sh "$run" "$tmp/inner" >/dev/null 2>"$tmp/inner.err"
ok "inner jobs under a two-token job never run more than two at once" '[ "$(sort -n "$tmp/peaks" | tail -n 1)" = 2 ] && [ $((SECONDS - t0)) -ge 2 ]'
ok "inner jobs never take a token of their own from the pool" '! grep -q taken "$tmp/third" && [ "$(wc -l <"$tmp/third")" = 3 ]'
ok "inner jobs are logged as using inherited tokens, and skip admission" \
  '[ "$(tail -n +$((lines + 1)) "$log" | jq -sr "map(select(.label | startswith(\"inner\"))) | map(.lock == \"inherited\" and .tokens == 1 and .admit_wait_s == 0) | all")" = true ]'
ok "the third inner job waited for a sibling, and said so" '[[ "$(cat "$tmp/inner.err")" == *"needs 1 of this job'"'"'s 2 tokens"* ]]'
ok "the pool's own tokens are untouched by the claims" '[ ! -e "$(slot 3).use" ] && [ -e "$(slot 1).use" ]'
# The slip this fixes: the command of every job used to compete for one shared extra slot, so of
# two admitted one-token jobs only one could draw. Now each draws on its own token at once.
: >"$tmp/peaks"
export TEST_GPU_JOBS=2
for i in 1 2; do "$run" --label "job $i" -- "$run" --label "drawing $i" -- "$tmp/inner" >/dev/null 2>&1 & done
wait
unset TEST_GPU_JOBS
ok "two one-token jobs draw at once, each on its own token" '[ "$(sort -n "$tmp/peaks" | tail -n 1)" = 2 ] && [ "$(last ".lock")" = held ]'

# A job killed outright frees its tokens: the kernel drops a dead process's flocks.
"$run" --label doomed --tokens 3 -- sh -c 'echo $$ >"$1"; exec sleep 30' sh "$tmp/doomed.pid" >/dev/null 2>&1 &
doomed=$!
for _ in $(seq 100); do [ -s "$tmp/doomed.pid" ] && break; sleep 0.1; done
kill -9 "$doomed"
wait "$doomed" 2>/dev/null || true
kill "$(cat "$tmp/doomed.pid")" 2>/dev/null || true
rc=0; "$run" --label after-kill --tokens 3 -- true >/dev/null 2>&1 || rc=$?
ok "a killed holder frees its tokens at once" '[ "$rc" = 0 ] && [ "$(last ".label,(.lock_wait_s < 1)" | tr "\n" " ")" = "after-kill true " ]'

# Killing gpu-run alone does not free the token while what draws under it still runs: a gpu-run
# inside the job (or the party-games test helper) holds the card token itself.
: >"$tmp/victim.pid"
"$run" --label victim -- "$run" --label drawing -- sh -c 'echo $$ >"$1"; exec sleep 30' sh "$tmp/victim.pid" >/dev/null 2>&1 &
victim=$!
for _ in $(seq 100); do [ -s "$tmp/victim.pid" ] && break; sleep 0.1; done
kill -9 "$victim"
wait "$victim" 2>/dev/null || true
sleep 0.3
ok "a token stays taken while the command of a killed gpu-run still runs" '! flock -n "$(slot 1)" true'
kill "$(cat "$tmp/victim.pid")" 2>/dev/null || true
for _ in $(seq 50); do flock -n "$(slot 1)" true && break; sleep 0.1; done
ok "and is free once the command has gone too" 'flock -n "$(slot 1)" true'

# What a job leaves running keeps no token unless it can draw. A plain background process (a dev
# server started with &) holds none once gpu-run has gone; a gpu-run left in the background does,
# and the job says so loudly, logs it, and a waiting job names it from /proc/locks.
export TEST_GPU_JOBS=1
: >"$tmp/bg.pid"
"$run" --label leaves-a-server -- sh -c 'sleep 30 & echo $! >"$1"' sh "$tmp/bg.pid" >/dev/null 2>&1
ok "a background process left by the command holds no token" 'kill -0 "$(cat "$tmp/bg.pid")" && flock -n "$(slot 1)" true'
kill "$(cat "$tmp/bg.pid")" 2>/dev/null || true
out="$("$run" --label leaves-a-job -- sh -c '"$1" --label inner-left -- sleep 6 >/dev/null 2>&1 & sleep 1.5' sh "$run" 2>&1)"
ok "a leftover that holds a token is named loudly when the job ends" \
  '[[ "$out" == *"LEFT RUNNING AND HOLDING A CARD TOKEN: pid "*"--label inner-left"*" holds "*"card-1.lock; it counts against the card'"'"'s tokens until it ends"* ]]'
ok "and logged with the job" '[ "$(last ".label,(.left_holding | length > 0)" | tr "\n" " ")" = "leaves-a-job true " ]'
out="$(GPU_RUN_WAIT_REPORT_S=1 "$run" --label after-leftover -- true 2>&1)"
ok "a waiting job names a leftover holder it learns from /proc/locks" '[[ "$out" == *"held now: "*"card-1.lock: pid "*"--label inner-left"*") for "* ]]'
# The party-games test helper holds its locks as below (HOLD_LOCK in lobby/test/browser.mjs): the
# flock utility locks a descriptor of the shell, which then becomes `cat`, so /proc/locks names
# the flock process, long gone. The holder is still found (through its open descriptor) and named.
cat >"$tmp/helper-hold" <<'EOF'
#!/bin/sh
# A test script under the job: holds its job's card token shared, as the helper's claim does.
sleep 8 2>/dev/null | sh -c 'exec 9<>"$1" || exit 1
flock -n -s 9 || exit 1
echo held
exec cat >/dev/null' hold-lock "$TEST_GPU_TOKENS" >/dev/null 2>&1 &
EOF
chmod +x "$tmp/helper-hold"
out="$("$run" --label leaves-a-helper -- sh -c '"$1"; sleep 1.5' sh "$tmp/helper-hold" 2>&1)"
ok "a leftover helper-style holder is named loudly when the job ends" \
  '[[ "$out" == *"LEFT RUNNING AND HOLDING A CARD TOKEN: pid "*"(cat under "*" holds "*"card-1.lock"* ]] && [ "$(last ".label,(.left_holding | length > 0)" | tr "\n" " ")" = "leaves-a-helper true " ]'
out="$(GPU_RUN_WAIT_REPORT_S=1 "$run" --label after-helper -- true 2>&1)"
ok "a waiting job names a helper-style holder, not \"no details\"" '[[ "$out" == *"held now: "*"card-1.lock: pid "*"(cat under "*") for "* ]] && [[ "$out" != *"no details"* ]]'
unset TEST_GPU_JOBS

# A long holder of one token and a job that needs them all do not freeze one-token jobs: the
# waiting job lets the gate go after GATE_PRIORITY_S (2 s here), and a one-token job takes a free
# token then. A job that waits long says who holds the tokens.
flock -o "$(slot 1)" sleep 30 &  # -o: the lock is flock's own, so killing flock frees it
long=$!
sleep 0.3
GPU_RUN_GATE_PRIORITY_S=2 "$run" --label render --kind blender -- true >/dev/null 2>"$tmp/render.err" &
render=$!
for _ in $(seq 100); do grep -q waiting "$tmp/render.err" && break; sleep 0.1; done
t0=$SECONDS
rc=0; timeout 20 "$run" --label single -- true >/dev/null 2>&1 || rc=$?
ok "a one-token job gets a free token beside a long holder and a waiting heavy job" '[ "$rc" = 0 ] && [ $((SECONDS - t0)) -lt 15 ]'
ok "the heavy job says it let the gate go" 'grep -q "letting the gate go" "$tmp/render.err"'
kill "$long"
wait "$render"
ok "the heavy job runs once the long holder is gone" '[ "$(last ".label,(.slots | length)" | tr "\n" " ")" = "render 3 " ]'
"$run" --label holder-job -- sleep 3 >/dev/null 2>&1 &
holder=$!
sleep 1
out="$(TEST_GPU_JOBS=1 GPU_RUN_WAIT_REPORT_S=1 "$run" --label patient -- true 2>&1)"
wait "$holder"
ok "a job that waits long names who holds the tokens" '[[ "$out" == *"held now: "*"card-1.lock: gpu-run \"holder-job\" (pid "*") for "* ]]'
flock -o "$(slot gate)" sleep 30 &
hung=$!
sleep 0.3
rc=0; out="$(GPU_RUN_GATE_WAIT_MAX_S=2 timeout 20 "$run" --label past-the-gate -- true 2>&1)" || rc=$?
kill "$hung"
ok "a gate held too long is passed by, with a line saying so" '[ "$rc" = 0 ] && [[ "$out" == *"has been held for over 2 s"*"taking tokens without it"* ]]'

# No deadlock when a three-token job and one-token jobs interleave, and the three-token job is
# not overtaken by one-token jobs that come after it.
: >"$tmp/order"
for name in a b; do "$run" --label "$name" -- sh -c 'echo "$1" >>"$2"; sleep 2' sh "$name" "$tmp/order" >/dev/null 2>&1 & done
for _ in $(seq 100); do [ "$(wc -l <"$tmp/order")" = 2 ] && break; sleep 0.1; done
"$run" --label big --tokens 3 -- sh -c 'echo big >>"$1"; sleep 0.5' sh "$tmp/order" >/dev/null 2>"$tmp/big.err" &
for _ in $(seq 100); do grep -q waiting "$tmp/big.err" && break; sleep 0.1; done
for name in c d; do "$run" --label "$name" -- sh -c 'echo "$1" >>"$2"; sleep 0.5' sh "$name" "$tmp/order" >/dev/null 2>&1 & done
t0=$SECONDS
wait
ok "a three-token job and one-token jobs all finish (no deadlock)" '[ "$(sort "$tmp/order" | tr "\n" " ")" = "a b big c d " ] && [ $((SECONDS - t0)) -lt 30 ]'
ok "the three-token job goes before one-token jobs that came after it" '[ "$(sed -n 3p "$tmp/order")" = big ]'
unset TEST_GPU_JOBS
"$run" --no-lock --label free -- sh -c 'flock -n "'"$(slot 1)"'" true && [ -z "${TEST_GPU_JOBS:-}" ] && [ -z "${TEST_GPU_SLOT_HELD:-}" ] && [ -z "${TEST_GPU_TOKENS:-}" ]' >/dev/null
ok "--no-lock leaves the tokens and the environment alone" '[ "$(last ".exit,.lock" | tr "\n" " ")" = "0 none " ]'

# Admission: a job waits for a busy, full, warm or recently crashed card, says why, and fails
# with exit 6 after --admit-wait; it starts as soon as the card settles.
lines="$(wc -l <"$log")"
# Every job publishes its readings for others' admission; each fake card here is a different
# card, so a case starts with none published (fresh_card).
fresh_card() { rm -rf "$GPU_RUN_STATE/live"; }
for case in "busy|load averaged 90% over the last 10 s (wanted under 70%)" "full|1.0 GB of video memory free (wanted at least 2 GB)" "warm|the card is at 82 C (wanted under 80 C)"; do
  name="${case%%|*}" want="${case#*|}"
  fresh_card
  rc=0; out="$(GPU_RUN_SAMPLER="$tmp/$name" "$run" --admit-wait 0.5 --label "$name" -- touch "$tmp/ran-$name" 2>&1)" || rc=$?
  ok "admission refuses a $name card with exit 6, saying why" '[ "$rc" = 6 ] && [[ "$out" == *"waiting for the card to settle: "*"$want"* ]] && [[ "$out" == *"did not settle within 0.5 s"* ]] && [ ! -e "$tmp/ran-$name" ]'
done
export EVENTS_AGO="$tmp/ago"
echo "10 plain" >"$EVENTS_AGO"
t_before="$(date -d "@$(($(date +%s) + 20 * 60))" +%H:%M)"
rc=0; out="$(GPU_RUN_EVENTS="$tmp/events-ago" "$run" --admit-wait 0 --label crashed -- touch "$tmp/ran-crashed" 2>&1)" || rc=$?
t_after="$(date -d "@$(($(date +%s) + 20 * 60))" +%H:%M)"
ok "admission refuses after a driver event in the last 30 minutes, saying when the card takes jobs again" \
  '[ "$rc" = 6 ] && [[ "$out" == *"(Windows Error Reporting 1001); the card takes jobs again from about $t_before"* || "$out" == *"jobs again from about $t_after"* ]] && [ ! -e "$tmp/ran-crashed" ]'
printf '35 plain\n5 processed\n' >"$EVENTS_AGO"
rc=0; GPU_RUN_EVENTS="$tmp/events-ago" "$run" --admit-wait 0 --label late-report -- true >/dev/null 2>&1 || rc=$?
ok "a processed report filed late counts from the first report of its burst" '[ "$rc" = 0 ]'
echo "5 processed" >"$EVENTS_AGO"
rc=0; GPU_RUN_EVENTS="$tmp/events-ago" "$run" --admit-wait 0 --label lone-report -- true >/dev/null 2>&1 || rc=$?
ok "a processed report with no earlier one counts from its own time" '[ "$rc" = 6 ]'
unset EVENTS_AGO
rc=0; GPU_RUN_EVENTS="$tmp/one-event" "$run" --admit-wait 0 --label old-crash -- true >/dev/null 2>&1 || rc=$?
ok "an older driver event does not hold a job back" '[ "$rc" = 0 ]'
ok "a refused job leaves a record saying why, and the report lists it apart" \
  '[ "$(tail -n +$((lines + 1)) "$log" | jq -r "select(.refused) | .label" | tr "\n" " ")" = "busy full warm crashed lone-report " ] &&
   [ "$(tail -n +$((lines + 1)) "$log" | jq -r "select(.label == \"crashed\") | [.exit, (.refused | test(\"driver event\"))] | @tsv")" = "$(printf "6\ttrue")" ] &&
   rep="$("$run" --report)" && [[ "$rep" == *"## Turned away at admission (exit 6)"*"crashed (other) after "*" s: a display driver event"* ]]'
export TEST_GPU_JOBS=1
fresh_card
GPU_RUN_SAMPLER="$tmp/busy" "$run" --admit-wait 0 --label refused -- true >/dev/null 2>&1 || true
rc=0; "$run" --label next -- true >/dev/null 2>&1 || rc=$?
ok "a refused job lets its tokens go" '[ "$rc" = 0 ] && [ "$(last ".label,(.lock_wait_s < 1)" | tr "\n" " ")" = "next true " ]'
unset TEST_GPU_JOBS
echo 90 >"$tmp/load"
( sleep 1.5; echo 10 >"$tmp/load" ) &
fresh_card
rc=0; out="$(GPU_RUN_SAMPLER="$tmp/settles" "$run" --admit-wait 20 --label settles -- true 2>&1)" || rc=$?
ok "a waiting job starts once the card settles, and says so" '[ "$rc" = 0 ] && [[ "$out" == *"waiting for the card to settle: the card'"'"'s load averaged 90%"* ]] && [[ "$out" == *"has settled after"* ]] && [ "$(last ".admit_wait_s >= 1")" = true ]'
wait
fresh_card
rc=0; out="$(GPU_RUN_SAMPLER=false "$run" --label blind -- true 2>&1)" || rc=$?
ok "a sampler that gives nothing does not hold jobs back, and says admission was not checked" '[ "$rc" = 0 ] && [[ "$out" == *"admission: not checked"* ]]'
rc=0; TEST_GPU_TOKENS="$tmp/parent-token" GPU_RUN_SAMPLER="$tmp/busy" "$run" --admit-wait 0 --label child -- sh -c '[ "$TEST_GPU_TOKENS" = "'"$tmp/parent-token.use"'" ]' >/dev/null 2>&1 || rc=$?
ok "a job inside a job skips admission and passes its claim down" '[ "$rc" = 0 ] && [ "$(last ".lock,.slots" | tr "\n" " " | tr -d " ")" = "inherited[]" ]'
rc=0; GPU_RUN_SAMPLER="$tmp/busy" "$run" --cpu --admit-wait 0 --label cpu-busy -- true >/dev/null 2>&1 || rc=$?
ok "a --cpu run skips admission" '[ "$rc" = 0 ]'
fresh_card
rc=0; out="$(GPU_RUN_SAMPLER="$tmp/busy" "$run" --admit-wait 0.5 --admit-timeout-runs --label gate -- touch "$tmp/ran-anyway" 2>&1)" || rc=$?
ok "--admit-timeout-runs starts anyway after the wait, loudly, and logs it" \
  '[ "$rc" = 0 ] && [ -e "$tmp/ran-anyway" ] && [[ "$out" == *"STARTING ANYWAY (--admit-timeout-runs): the card did not settle within 0.5 s: the card'"'"'s load averaged 90%"* ]] && [ "$(last ".label,(.admit_timed_out | test(\"load\"))" | tr "\n" " ")" = "gate true " ]'
# A job waiting for the card to settle holds no token: another job takes it meanwhile.
export TEST_GPU_JOBS=1
echo 90 >"$tmp/load"
fresh_card
GPU_RUN_SAMPLER="$tmp/settles" "$run" --admit-wait 30 --label slow-to-settle -- true >/dev/null 2>"$tmp/slow.err" &
slow=$!
for _ in $(seq 100); do grep -q "waiting for the card to settle" "$tmp/slow.err" && break; sleep 0.1; done
rc=0; out="$(timeout 10 "$run" --label meanwhile -- true 2>&1)" || rc=$?
ok "a job waiting for admission holds no token" '[ "$rc" = 0 ] && [[ "$out" != *"waiting for the graphics card"* ]] && kill -0 "$slow"'
echo 10 >"$tmp/load"
wait "$slow"
unset TEST_GPU_JOBS
# Readings another job's sampler has published over the whole window decide at once: this job's
# own sampler ("slow-sampler") gives no load readings at all.
printf '#!/bin/sh\necho %s\nexec sleep 60\n' "'{\"t\":1,\"load\":null,\"types\":{},\"used\":$GiB,\"top\":[],\"cpu\":1,\"adapter\":\"Test Card\",\"total\":$((16 * GiB)),\"temp\":50}'" >"$tmp/slow-sampler"
chmod +x "$tmp/slow-sampler"
publish() { # publish load: another job's sampler that has read the card for the last 12 s
  local now i sep="" samples=""
  now="$(date +%s)"
  fresh_card
  for i in $(seq 12 -1 0); do samples="$samples$sep{\"at\":$((now - i)),\"load\":$1,\"used\":$GiB,\"temp\":50}"; sep=","; done
  mkdir -p "$GPU_RUN_STATE/live"
  echo "{\"since\":$((now - 12)),\"total\":$((16 * GiB)),\"samples\":[$samples]}" >"$GPU_RUN_STATE/live/999999.json"
}
publish 85
t0=$SECONDS
rc=0; out="$(GPU_RUN_SAMPLER="$tmp/slow-sampler" "$run" --admit-wait 0 --label shared-busy -- true 2>&1)" || rc=$?
ok "another sampler's busy readings refuse a job at once" '[ "$rc" = 6 ] && [[ "$out" == *"load averaged 85%"* ]] && [ $((SECONDS - t0)) -lt 5 ]'
publish 5
rc=0; GPU_RUN_SAMPLER="$tmp/slow-sampler" "$run" --admit-wait 0 --label shared-calm -- true >/dev/null 2>&1 || rc=$?
ok "another sampler's calm readings admit a job at once" '[ "$rc" = 0 ] && [ "$(last ".label,(.admit_wait_s < 1)" | tr "\n" " ")" = "shared-calm true " ]'
rm -f "$GPU_RUN_STATE/live/999999.json"
# A published file that is not what a sampler writes is skipped whole: no crash, and the job's own
# readings (a busy card here) decide. Readings dated an hour ahead (a clock step) do not count.
for case in nondict noat strload nan future; do
  fresh_card
  mkdir -p "$GPU_RUN_STATE/live"
  now="$(date +%s)"
  good="{\"at\":$((now - 1)),\"load\":5,\"used\":$GiB,\"temp\":50}"
  case "$case" in
    nondict) samples="\"junk\",$good" ;;
    noat) samples="{\"load\":5},$good" ;;
    strload) samples="{\"at\":$((now - 1)),\"load\":\"high\",\"used\":$GiB,\"temp\":50}" ;;
    nan) samples="{\"at\":$((now - 1)),\"load\":NaN,\"used\":$GiB,\"temp\":50}" ;;
    future) samples="{\"at\":$((now + 3600)),\"load\":5,\"used\":$GiB,\"temp\":50}" ;;
  esac
  echo "{\"since\":$((now - 60)),\"total\":$((16 * GiB)),\"samples\":[$samples]}" >"$GPU_RUN_STATE/live/999999.json"
  rc=0; out="$(GPU_RUN_SAMPLER="$tmp/busy" "$run" --admit-wait 0 --label "garbage-$case" -- true 2>&1)" || rc=$?
  ok "a published file with $case readings is skipped, not trusted and not a crash" '[ "$rc" = 6 ] && [[ "$out" != *Traceback* ]] && [[ "$out" == *"load averaged 90%"* ]]'
done
rm -f "$GPU_RUN_STATE/live/999999.json"
# One admission allowance across rounds: a job admitted after about 3 s, that then waits over
# ADMIT_WINDOW_S for its token while the card gets busy, has only the rest of --admit-wait left.
export TEST_GPU_JOBS=1
fresh_card
echo 90 >"$tmp/load"
flock -o "$(slot 1)" sleep 18 &
long=$!
sleep 0.3
( sleep 3; echo 10 >"$tmp/load"; sleep 5; echo 90 >"$tmp/load" ) &
flips=$!
t0=$SECONDS
rc=0; out="$(GPU_RUN_SAMPLER="$tmp/settles" "$run" --admit-wait 6 --label rounds -- true 2>&1)" || rc=$?
took=$((SECONDS - t0))
wait "$long" "$flips" 2>/dev/null || true
ok "admission time counts across rounds, so the job still ends after --admit-wait" \
  '[ "$rc" = 6 ] && [[ "$out" == *"got busy while this job waited for its tokens"* ]] && [ "$took" -lt 22 ]'
unset TEST_GPU_JOBS

# The off switch.
"$run" --off "driver error at 20:36" >/dev/null
lines="$(wc -l <"$log")"
rc=0; out="$("$run" --label blocked -- true 2>&1)" || rc=$?
ok "a job refuses while the card is off" '[ "$rc" = 3 ] && [[ "$out" == *"driver error at 20:36"* ]] && [ "$(wc -l <"$log")" = "$lines" ]'
"$run" --cpu --label probe -- sh -c '[ "$TEST_NO_GPU" = 1 ]' >/dev/null
ok "a --cpu run goes ahead with TEST_NO_GPU=1 and no lock" '[ "$(last ".exit,.cpu_run,.lock" | tr "\n" " ")" = "0 true none " ]'
"$run" --watch 1.5 --label rest >/dev/null
ok "--watch samples while the card is off" '[ "$(last ".kind,.cmd" | tr "\n" " ")" = "watch null " ] && [ "$(last .gpu.samples)" -ge 1 ]'
ok "--watch keeps every temperature reading" '[ "$(last ".gpu.temp_c_trace | length")" -ge 2 ] && [ "$(last ".gpu.temp_c_trace[0] | length")" = 2 ]'
"$run" --on >/dev/null
rc=0; TEST_NO_GPU=1 "$run" --label envoff -- true >/dev/null 2>&1 || rc=$?
ok "TEST_NO_GPU=1 also refuses" '[ "$rc" = 3 ]'
rc=0; "$run" --label on-again -- true >/dev/null || rc=$?
ok "--on switches it back on" '[ "$rc" = 0 ]'

# Idle gate.
rc=0; out="$(GPU_RUN_IDLE="$tmp/idle-2" "$run" --only-when-idle 10 --label idle -- true 2>&1)" || rc=$?
ok "--only-when-idle refuses while the owner is active" '[ "$rc" = 4 ] && [[ "$out" == *"2 minutes ago"* ]]'
rc=0; GPU_RUN_IDLE="$tmp/idle-2" "$run" --only-when-idle 1 --label idle -- true >/dev/null || rc=$?
ok "--only-when-idle runs once idle long enough" '[ "$rc" = 0 ]'
rc=0; out="$(GPU_RUN_IDLE="$tmp/fullscreen" "$run" --only-when-idle 1 --label idle -- true 2>&1)" || rc=$?
ok "--only-when-idle refuses during a full-screen game" '[ "$rc" = 4 ] && [[ "$out" == *"full-screen"* ]]'

# A driver event is logged and loud; one inside the job's own window switches the card off.
out="$(GPU_RUN_EVENTS="$tmp/one-event" "$run" --label crashy --kind blender -- true 2>&1)"
ok "a driver event is logged" '[ "$(last ".driver_events[0].id")" = 1001 ] && [[ "$out" == *"DRIVER EVENTS: 1"* ]]'
ok "an event outside the job's window does not switch the card off" '[ ! -e "$GPU_RUN_STATE/OFF" ] && [[ "$out" != *"switched the card off"* ]]'
out="$(GPU_RUN_EVENTS="$tmp/job-event" "$run" --label crashy --kind blender -- sleep 1.2 2>&1)"
ok "an event inside the job's window switches the card off, in one line" '[ "$(grep -c "switched the card off" <<<"$out")" = 1 ] && grep -q "during the job \"crashy\": Windows Error Reporting 1001 at " "$GPU_RUN_STATE/OFF"'
rc=0; out="$("$run" --label after-crash -- true 2>&1)" || rc=$?
ok "the next job refuses and says which event" '[ "$rc" = 3 ] && [[ "$out" == *"Windows Error Reporting 1001"* ]] && [[ "$out" == *"gpu-run --on"* ]]'
"$run" --on >/dev/null
rc=0; "$run" --label after-on -- true >/dev/null || rc=$?
ok "--on clears the marker" '[ "$rc" = 0 ] && [ ! -e "$GPU_RUN_STATE/OFF" ]'

# The report, from a fixture log.
export GPU_RUN_STATE="$tmp/fixture"
mkdir -p "$GPU_RUN_STATE"
row() { # row start label kind cpu_run wall cpu exit events
  printf '{"v":1,"start":"%s","end":"%s","label":"%s","kind":"%s","cpu_run":%s,"wall_s":%s,"cpu_s":%s,"exit":%s,"gpu":{"load_peak":60,"vram_used_peak_gb":8.5,"temp_c_start":47,"temp_c_peak":%s,"temp_c_end":50},"driver_events":%s}\n' "$1" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$((60 + $5 % 7))" "$8"
}
{
  row 2026-11-10T10:00:00-08:00 old other false 9 1 0 '[]'
  row 2026-11-15T10:00:00-08:00 room-pick browser-test false 40 25 0 '[]'
  row 2026-11-15T10:05:00-08:00 room-pick browser-test false 42 26 0 '[]'
  row 2026-11-15T10:10:00-08:00 room-pick browser-test true 120 550 0 '[]'
  row 2026-11-15T10:20:00-08:00 cube blender false 5 1 1 '[{"time":"2026-11-15T10:20:03-08:00","provider":"Windows Error Reporting","id":1001,"text":"LiveKernelEvent 141"}]'
  row 2026-11-15T10:30:00-08:00 rest watch false 30 null 0 '[]'
  echo 'not json'
} >"$GPU_RUN_STATE/jobs.jsonl"
rep="$("$run" --report --since 2026-11-15)"
ok "the report skips jobs before --since" '[[ "$rep" != *"| old |"* ]] && [[ "$rep" == *"5 records"* ]]'
ok "the report counts runs and failures by kind, with the peak temperature" '[[ "$rep" == *"| browser-test | 2 | 0 | 41 s | 42 s | 60% | 8.5 GB | 65 C |"* ]] && [[ "$rep" == *"| blender | 1 | 1 |"* ]]'
ok "the report shows a baseline's temperature" '[[ "$rep" == *"| rest | 30 |"*"| 47 / 62 / 50 C |"* ]]'
ok "the report shows the card against the CPU" '[[ "$rep" == *"| room-pick | 2 / 1 | 41 s | 120 s | 2.9x | 25.5 s | 550 s | 21.6x |"* ]]'
ok "the report lists jobs during a driver event" '[[ "$rep" == *"cube (blender, exit 1): Windows Error Reporting 1001"* ]]'

echo "$((n - fail))/$n passed"
[ "$fail" = 0 ]
