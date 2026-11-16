#!/usr/bin/env bash
# Tests for bin/gpu-run that need no graphics card: argument parsing, the off switch, the lock,
# the log line (with a fake sampler, event query and idle check) and the report from a fixture.
# Run: bin/gpu-run.test.sh
set -euo pipefail
run="$(cd "$(dirname "$0")" && pwd)/gpu-run"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GPU_RUN_STATE="$tmp/state" GPU_RUN_LOCK="$tmp/card-{n}.lock"
unset TEST_NO_GPU TEST_GPU_JOBS TEST_GPU_SLOT_HELD
slot() { echo "$tmp/card-$1.lock"; }
log="$GPU_RUN_STATE/jobs.jsonl"
GiB=1073741824

# A fake sampler: one sample, a pause (so the job starts after it), then busier samples.
cat >"$tmp/sampler" <<EOF
#!/bin/sh
echo '{"t":1,"load":null,"types":{},"used":$((4 * GiB)),"top":[["dwm",$((2 * GiB))]],"cpu":1.0,"adapter":"Test Card","total":$((16 * GiB)),"temp":45.5,"fan":800}'
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
chmod +x "$tmp"/hot "$tmp"/no-temp
printf '#!/bin/sh\necho "[]"\n' >"$tmp/no-events"
printf '#!/bin/sh\necho %s\n' "'{\"time\":\"2026-11-15T20:36:35-08:00\",\"log\":\"Application\",\"provider\":\"Windows Error Reporting\",\"id\":1001,\"text\":\"LiveKernelEvent 141\"}'" >"$tmp/one-event"
printf '#!/bin/sh\necho %s\n' "'{\"idle_min\":2,\"state\":5}'" >"$tmp/idle-2"
printf '#!/bin/sh\necho %s\n' "'{\"idle_min\":60,\"state\":3}'" >"$tmp/fullscreen"
chmod +x "$tmp"/sampler "$tmp"/no-events "$tmp"/one-event "$tmp"/idle-2 "$tmp"/fullscreen
export GPU_RUN_SAMPLER="$tmp/sampler" GPU_RUN_EVENTS="$tmp/no-events"

fail=0 n=0
ok() { n=$((n + 1)); if ! eval "$2"; then fail=$((fail + 1)); echo "FAIL: $1"; fi; }
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

# CPU time counts orphaned grandchildren too.
"$run" --label busy -- sh -c 'python3 -c "import time
t = time.process_time()
while time.process_time() - t < 0.6: pass" & exit 0' >/dev/null
ok "CPU time includes an orphaned grandchild" '[ "$(last ".cpu_s >= 0.5")" = true ] && [ "$(last .cpu_complete)" = true ]'

# The slots: a job takes one free slot, waits while every slot is in use, and holds its slot
# while it runs; a heavy job takes every slot.
default_slots="$(grep -oP '^DEFAULT_SLOTS = \K\d+' "$run")"
"$run" --label held -- sh -c '! flock -n "$(echo "$GPU_RUN_LOCK" | sed "s/{n}/1/")" true && [ "$TEST_GPU_JOBS" = '"$((default_slots + 1))"' ] && [ "$TEST_GPU_SLOT_HELD" = 1 ]' >/dev/null
ok "a job holds slot 1 while it runs, and the command gets one more slot than the default" '[ "$(last ".exit,.slots[0]" | tr "\n" " ")" = "0 1 " ]'
export TEST_GPU_JOBS=2
flock "$(slot 1)" sleep 1.5 &
holder=$!
sleep 0.3
"$run" --label second -- sh -c '! flock -n "'"$(slot 2)"'" true && [ "$TEST_GPU_JOBS" = 3 ]' >/dev/null
wait "$holder"
ok "with slot 1 in use a job takes slot 2 at once" '[ "$(last ".exit,.slots[0]" | tr "\n" " ")" = "0 2 " ] && [ "$(last ".lock_wait_s < 1")" = true ]'
flock "$(slot 1)" sleep 2 &
h1=$!
flock "$(slot 2)" sleep 2 &
h2=$!
sleep 0.3
out="$("$run" --label wait -- true 2>&1)"
wait "$h1" "$h2"
ok "a job waits while every slot is in use, and says so" '[[ "$out" == *"waiting for the graphics card (all 2 slots"* ]] && [ "$(last ".lock_wait_s >= 1")" = true ]'
"$run" --label render --kind blender -- sh -c '! flock -n "'"$(slot 1)"'" true && ! flock -n "'"$(slot 2)"'" true && [ "$TEST_GPU_JOBS" = 2 ] && [ -z "${TEST_GPU_SLOT_HELD:-}" ]' >/dev/null
ok "a heavy job holds every slot" '[ "$(last ".exit,(.slots | length)" | tr "\n" " ")" = "0 2 " ]'
flock "$(slot 2)" sleep 1.5 &
holder=$!
sleep 0.3
out="$("$run" --label render --kind image -- true 2>&1)"
wait "$holder"
ok "a heavy job waits for a test job on any slot" '[[ "$out" == *"heavy job takes all 2 slots"* ]] && [ "$(last ".lock_wait_s >= 1")" = true ]'
unset TEST_GPU_JOBS
"$run" --no-lock --label free -- sh -c 'flock -n "'"$(slot 1)"'" true && [ -z "${TEST_GPU_JOBS:-}" ] && [ -z "${TEST_GPU_SLOT_HELD:-}" ]' >/dev/null
ok "--no-lock leaves the slots and the environment alone" '[ "$(last ".exit,.lock" | tr "\n" " ")" = "0 none " ]'

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

# A driver event during a job is logged and loud.
out="$(GPU_RUN_EVENTS="$tmp/one-event" "$run" --label crashy --kind blender -- true)"
ok "a driver event is logged" '[ "$(last ".driver_events[0].id")" = 1001 ] && [[ "$out" == *"DRIVER EVENTS: 1"* ]]'

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
