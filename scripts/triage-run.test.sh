#!/usr/bin/env bash
# triage-run.test.sh -- fixture-driven tests for the read-only nf-core run triage.
#
#     bash scripts/triage-run.test.sh
#
# The fixture is synthetic and contains no research data. Tests assert on stable fields, not full
# prose, so wording can improve without weakening the status/task/read-only contract.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/triage-run.sh"
FIXTURE="$HERE/fixtures/triage-run/failed"
FIXTURES="$HERE/fixtures/triage-run"
[[ -r "$SRC" && -d "$FIXTURE" ]] || { printf 'missing script or fixture\n' >&2; exit 1; }
FIXTURE_ABS="$(cd "$FIXTURE" && pwd -P)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

ok() { pass=$((pass+1)); printf '  ok    %s\n' "$*"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$*"; }
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
not_contains() { ! contains "$1" "$2"; }

snapshot() {
  find "$1" -type f -exec cksum {} \; | sort
}

before="$(snapshot "$FIXTURES")"

# An abrupt stop has neither a terminal marker nor a live head process.
cp -R "$FIXTURES/hard-stopped" "$TMP/hard-stopped"
stopped_before="$(snapshot "$TMP/hard-stopped")"
output="$(bash "$SRC" "$TMP/hard-stopped" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && contains "$output" 'status: unknown' \
  && contains "$output" '멈춘 것으로 보이나 terminal 표식 없음' \
  && contains "$output" 'last log time: Oct-01 10:15:30.123' \
  && ok 'hard-stopped run is unknown with last log time' || bad 'hard-stopped run is unknown with last log time'
json="$(bash "$SRC" --json "$TMP/hard-stopped" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && contains "$json" '"status":"unknown"' \
  && contains "$json" '"last_log_time":"Oct-01 10:15:30.123"' \
  && ok 'hard-stopped JSON agrees' || bad 'hard-stopped JSON agrees'
[[ "$stopped_before" == "$(snapshot "$TMP/hard-stopped")" ]] \
  && ok 'hard-stopped input stays byte-identical' || bad 'hard-stopped input changed'

# A failed attempt is not the final run state: this head is still alive.
cp -R "$FIXTURES/live-head" "$TMP/live-head"
printf '%s\n' "$$" > "$TMP/live-head/nextflow.pid"
live_before="$(snapshot "$TMP/live-head")"
output="$(bash "$SRC" "$TMP/live-head" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && contains "$output" 'status: running' && contains "$output" 'failed tasks: 1' \
  && ok 'live PID beats historical failed attempt' || bad 'live PID beats historical failed attempt'
json="$(bash "$SRC" --json "$TMP/live-head" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && contains "$json" '"status":"running"' && contains "$json" '"failed":1' \
  && ok 'live PID JSON agrees' || bad 'live PID JSON agrees'
[[ "$live_before" == "$(snapshot "$TMP/live-head")" ]] \
  && ok 'live PID input stays byte-identical' || bad 'live PID input changed'

for pid in 999999999 0 -1 invalid $'123\n456'; do
  printf '%s\n' "$pid" > "$TMP/live-head/nextflow.pid"
  json="$(bash "$SRC" --json "$TMP/live-head" 2>&1)"; rc=$?
  [[ $rc -eq 0 ]] && contains "$json" '"status":"unknown"' && contains "$json" '"failed":1' \
    && ok 'dead or malformed PID cannot prove running or failed' || bad 'dead or malformed PID cannot prove running or failed'
done

# Terminal evidence wins even if the PID file still names a living process.
printf '%s\n' "$$" > "$TMP/live-head/nextflow.pid"
for marker in 'Session aborted -- Cause: synthetic error' 'Session aborted -- Cause: SIGTERM' 'Pipeline completed successfully'; do
  printf '%s\n' "$marker" >> "$TMP/live-head/.nextflow.log"
  case "$marker" in *SIGTERM) expected=cancelled ;; *successfully) expected=succeeded ;; *) expected=failed ;; esac
  json="$(bash "$SRC" --json "$TMP/live-head" 2>&1)"; rc=$?
  [[ $rc -eq 0 ]] && contains "$json" "\"status\":\"$expected\"" \
    && ok "terminal $expected wins over live PID" || bad "terminal $expected wins over live PID"
done

# Exercise the existing run-specific scan without launching Nextflow or a JVM.
mkdir -p "$TMP/scan.v2+test"
cp "$FIXTURES/hard-stopped/.nextflow.log" "$TMP/scan.v2+test/.nextflow.log"
SCAN_PID="$$"; SCAN_RUN="$(cd "$TMP/scan.v2+test" && pwd -P)"
pgrep() {
  [[ "$1" == -f ]] || return 1
  printf '%s\n' "$SCAN_ARGV" | grep -Eq "$2" && printf '%s\n' "$SCAN_PID"
}
cat() {
  if [[ "${SCAN_PID_READ_FAIL:-0}" == 1 && "$1" == "$SCAN_RUN/nextflow.pid" ]]; then
    return 1
  elif [[ "$1" == "/proc/$SCAN_PID/comm" ]]; then
    printf '%s\n' "$SCAN_COMM"
  else
    command cat "$@"
  fi
}
ps() {
  if [[ "$*" == "-p $SCAN_PID -o comm=" ]]; then printf '%s\n' "$SCAN_COMM"; else command ps "$@"; fi
}
for pid_case in absent dead malformed multiline unreadable non-file dangling; do
  rm -rf "$SCAN_RUN/nextflow.pid"
  SCAN_PID_READ_FAIL=0
  case "$pid_case" in
    dead) printf '%s\n' 999999999 > "$SCAN_RUN/nextflow.pid" ;;
    malformed) printf '%s\n' invalid > "$SCAN_RUN/nextflow.pid" ;;
    multiline) printf '%s\n' 123 456 > "$SCAN_RUN/nextflow.pid" ;;
    unreadable)
      printf '%s\n' "$$" > "$SCAN_RUN/nextflow.pid"
      SCAN_PID_READ_FAIL=1 ;;
    non-file) mkdir "$SCAN_RUN/nextflow.pid" ;;
    dangling) ln -s missing-pid "$SCAN_RUN/nextflow.pid" ;;
  esac
  for scenario in head launcher sibling other-root; do
    SCAN_ARGV="java nextflow -work-dir $SCAN_RUN/work"; SCAN_COMM=java; expected=running
    case "$scenario" in
      launcher) SCAN_COMM=tmux; expected=unknown ;;
      sibling) SCAN_ARGV="java nextflow -work-dir $SCAN_RUN-rerun/work"; expected=unknown ;;
      other-root) SCAN_ARGV="java nextflow -work-dir /elsewhere/scan.v2+test/work"; expected=unknown ;;
    esac
    json="$(export SCAN_PID SCAN_ARGV SCAN_COMM SCAN_PID_READ_FAIL SCAN_RUN; export -f pgrep cat ps; bash "$SRC" --json "$SCAN_RUN" 2>&1)"; rc=$?
    [[ $rc -eq 0 ]] && contains "$json" "\"status\":\"$expected\"" \
      && ok "run-specific scan ($pid_case PID): $scenario" || bad "run-specific scan ($pid_case PID): $scenario"
  done
done
unset -f pgrep cat ps

output="$(bash "$SRC" "$FIXTURE" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok 'failed run is a successful triage' || bad "failed run returned $rc"
contains "$output" 'status: failed' && ok 'failed status' || bad 'failed status missing'
contains "$output" 'counts: cached=1 completed=1 failed=1' && ok 'trace counts' || bad 'trace counts wrong'
contains "$output" 'process: NFCORE_RNASEQ:RNASEQ:FASTQC' && ok 'process name' || bad 'process missing'
contains "$output" 'tag: sample_A' && ok 'task tag' || bad 'tag missing'
contains "$output" 'exit status: 137' && ok 'exit status' || bad 'exit status missing'
contains "$output" "$FIXTURE_ABS/work/ab/cdef1234567890" && ok 'absolute work directory' || bad 'work directory missing'
contains "$output" 'command: fastqc --threads 2 sample_A.fastq.gz' && ok 'command line' || bad 'command missing'
contains "$output" 'stderr line one' && contains "$output" 'stderr line three' \
  && ok 'default stderr tail' || bad 'stderr tail missing'
contains "$output" '.nextflow.log.1' && contains "$output" 'trace.fixture.txt' \
  && contains "$output" 'report.fixture.html' && ok 'rotated log, trace and report located' \
  || bad 'artifact discovery incomplete'
lines="$(printf '%s\n' "$output" | wc -l | tr -d ' ')"
((lines < 100)) && ok 'single-failure report stays under 100 lines' || bad "report has $lines lines"

tail_output="$(bash "$SRC" --tail 1 "$FIXTURE" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && contains "$tail_output" 'stderr line three' \
  && not_contains "$tail_output" 'stderr line two' && ok '--tail overrides the default' \
  || bad '--tail did not select one line'

json="$(bash "$SRC" --json --tail 2 "$FIXTURE" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && [[ "$json" == \{*\} ]] && contains "$json" '"status":"failed"' \
  && contains "$json" '"cached":1' && contains "$json" '"process":"NFCORE_RNASEQ:RNASEQ:FASTQC"' \
  && contains "$json" '"stderr_tail":["stderr line two","stderr line three with quote \"x\" and slash \\tmp"]' \
  && ok 'JSON contains the text report fields and escaped tail' || bad 'JSON output incomplete or malformed'

mkdir -p "$TMP/succeeded/reports"
printf '%s\n' 'Execution complete -- Goodbye' > "$TMP/succeeded/.nextflow.log"
printf '%s\n' 'Succeeded : 2' 'Cached : 1' 'Failed : 0' > "$TMP/succeeded/nextflow.stdout.log"
output="$(bash "$SRC" "$TMP/succeeded" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && contains "$output" 'status: succeeded' \
  && contains "$output" 'counts: cached=1 completed=2 failed=0' \
  && ok 'successful run and summary counts' || bad 'successful run classification failed'

output="$(bash "$SRC" "$FIXTURES/validation-aborted" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && contains "$output" 'status: failed' && contains "$output" 'failed tasks: 0' \
  && ok 'validation error abort is failed without tasks' || bad 'validation error abort is failed without tasks'

json="$(bash "$SRC" --json "$FIXTURES/retry-succeeded" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && contains "$json" '"status":"succeeded"' \
  && contains "$json" '"completed":1,"failed":1' && contains "$json" '"exit_status":137' \
  && ok 'retry success retains failed attempt' || bad 'retry success retains failed attempt'

mkdir -p "$TMP/ignored/reports"
printf '%s\n' 'NOTE: Process `SYNTHETIC_TASK (sample_A)` terminated with an error exit status (1) -- Error is ignored' \
  > "$TMP/ignored/.nextflow.log"
printf 'name\tstatus\texit\nSYNTHETIC_TASK (sample_A)\tFAILED\t1\n' \
  > "$TMP/ignored/reports/trace.ignored.txt"
printf '%s\n' 'Pipeline completed successfully' > "$TMP/ignored/nextflow.stdout.log"
output="$(bash "$SRC" "$TMP/ignored" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && contains "$output" 'status: succeeded' && contains "$output" 'failed tasks: 1' \
  && ok 'ignored failure stdout success retains attempt' || bad 'ignored failure stdout success retains attempt'

# The authoritative session abort must beat both an earlier success and a stale stdout success.
mkdir -p "$TMP/late-abort"
printf '%s\n' 'Pipeline completed successfully' 'Session aborted -- Cause: Invalid synthetic input' \
  'Execution complete -- Goodbye' > "$TMP/late-abort/.nextflow.log"
printf '%s\n' 'Pipeline completed successfully' > "$TMP/late-abort/nextflow.stdout.log"
output="$(bash "$SRC" "$TMP/late-abort" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && contains "$output" 'status: failed' \
  && ok 'latest session abort overrides earlier and stdout success' \
  || bad 'latest session abort overrides earlier and stdout success'

mkdir -p "$TMP/cancelled"
printf '%s\n' 'Session aborted -- Cause: SIGINT' \
  'Execution cancelled -- Finishing pending tasks before exit' > "$TMP/cancelled/.nextflow.log"
mkdir -p "$TMP/cancelled/reports"
printf 'name\tstatus\texit\nNFCORE_RNASEQ:CANCELLED_TASK (sample_A)\tFAILED\t143\n' \
  > "$TMP/cancelled/reports/trace.cancelled.txt"
output="$(bash "$SRC" "$TMP/cancelled" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && contains "$output" 'status: cancelled' \
  && ok 'cancelled run' || bad 'cancelled run classification failed'

mkdir -p "$TMP/stale-stdout"
printf '%s\n' 'Execution cancelled -- Finishing pending tasks before exit' > "$TMP/stale-stdout/.nextflow.log"
printf '%s\n' 'Process `SYNTHETIC_TASK` terminated with an error exit status (137) -- Execution is retried (1)' \
  > "$TMP/stale-stdout/nextflow.stdout.log"
json="$(bash "$SRC" --json "$TMP/stale-stdout" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && contains "$json" '"status":"cancelled"' \
  && ok 'terminal marker is resolved within its own log' || bad 'terminal marker is resolved within its own log'

for signal in SIGINT SIGTERM; do
  printf '%s\n' 'Process `SYNTHETIC_TASK` terminated with an error exit status (137) -- Execution is retried (1)' \
    "Session aborted -- Cause: $signal" 'Execution complete -- Goodbye' > "$TMP/cancelled/.nextflow.log"
  cp "$FIXTURES/retry-succeeded/reports/trace.retry.txt" "$TMP/cancelled/reports/trace.cancelled.txt"
  output="$(bash "$SRC" "$TMP/cancelled" 2>&1)"; rc=$?
  [[ $rc -eq 0 ]] && contains "$output" 'status: cancelled' \
    && ok "$signal cancellation survives historical failure and shutdown" \
    || bad "$signal cancellation survives historical failure and shutdown"
done

# Reuse a synthetic BEL stderr fixture, then sweep all control bytes in a disposable copy.
cp -R "$FIXTURE" "$TMP/controls"
cp "$FIXTURES/control-stderr/.command.err" "$TMP/controls/work/ab/cdef1234567890/.command.err"
json="$(bash "$SRC" --json "$TMP/controls" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && printf '%s\n' "$json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["failed_tasks"][0]["stderr_tail"] == ["stderr bell \x07"]
'; then
  ok 'BEL stderr JSON parses and round-trips'
else
  bad 'BEL stderr JSON parses and round-trips'
fi

for ((code=0; code<32; code++)); do
  printf -v octal '%03o' "$code"
  printf 'control %02d: ' "$code"
  printf '%b' "\\$octal"
  printf ' end\n'
done > "$TMP/controls/work/ab/cdef1234567890/.command.err"
json="$(bash "$SRC" --json --tail 40 "$TMP/controls" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && printf '%s\n' "$json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
expected = "".join("control %02d: %s end\n" % (i, chr(i)) for i in range(32)).split("\n")[:-1]
assert data["failed_tasks"][0]["stderr_tail"] == expected
'; then
  ok 'all U+0000 through U+001F stderr bytes round-trip in JSON'
else
  bad 'all U+0000 through U+001F stderr bytes round-trip in JSON'
fi

mkdir -p "$TMP/running"
printf '%s\n' 'Starting process > NFCORE_RNASEQ:RNASEQ:FASTQC (sample_A)' > "$TMP/running/.nextflow.log"
printf '%s\n' "$$" > "$TMP/running/nextflow.pid"
output="$(bash "$SRC" "$TMP/running" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && contains "$output" 'status: running' \
  && ok 'running run' || bad 'running run classification failed'

mkdir -p "$TMP/rotated/work/ab/cdef1234567890"
cp "$FIXTURE/.nextflow.log" "$TMP/rotated/.nextflow.log.1"
cp "$FIXTURE/work/ab/cdef1234567890/.command.err" "$TMP/rotated/work/ab/cdef1234567890/.command.err"
cp "$FIXTURE/work/ab/cdef1234567890/.command.sh" "$TMP/rotated/work/ab/cdef1234567890/.command.sh"
output="$(bash "$SRC" "$TMP/rotated" 2>&1)"; rc=$?
rotated_abs="$(cd "$TMP/rotated" && pwd -P)"
[[ $rc -eq 0 ]] && contains "$output" 'status: failed' \
  && contains "$output" 'process: NFCORE_RNASEQ:RNASEQ:FASTQC' \
  && contains "$output" "$rotated_abs/work/ab/cdef1234567890" \
  && ok 'rotated-log fallback without a trace' || bad 'rotated-log fallback failed'

mkdir -p "$TMP/multi/reports" "$TMP/multi/task-one" "$TMP/multi/task-two"
printf '%s\n' 'Starting workflow' > "$TMP/multi/.nextflow.log"
printf 'status\texit\ttag\tprocess\tworkdir\nFAILED\t1\tsample_A\tPROCESS_ONE\t%s\nFAILED\t2\tsample_B (retry)\tPROCESS_TWO\t%s\n' \
  "$TMP/multi/task-one" "$TMP/multi/task-two" > "$TMP/multi/reports/trace.multi.txt"
output="$(bash "$SRC" "$TMP/multi" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && contains "$output" 'failed tasks: 2' \
  && contains "$output" 'status: unknown' \
  && contains "$output" 'process: PROCESS_ONE' && contains "$output" 'process: PROCESS_TWO' \
  && contains "$output" 'tag: sample_B (retry)' \
  && ok 'every failed task and header-named trace field' || bad 'multiple failed tasks were not reported'

# A root failure and its collateral termination are different trace states.
mkdir -p "$TMP/aborted/reports"
printf '%s\n' 'Session aborted -- Cause: synthetic task failure' > "$TMP/aborted/.nextflow.log"
printf 'name\tstatus\texit\nROOT (sample_A)\tFAILED\t1\nSIBLING (sample_A)\tABORTED\t143\n' \
  > "$TMP/aborted/reports/trace.aborted.txt"
output="$(bash "$SRC" "$TMP/aborted" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && contains "$output" 'failed=1 aborted=1 non_clean=0' \
  && contains "$output" 'failed tasks: 1' && contains "$output" 'process: ROOT' \
  && not_contains "$output" 'process: SIBLING' \
  && ok 'text separates root failure from aborted sibling' || bad 'text separates root failure from aborted sibling'
json="$(bash "$SRC" --json "$TMP/aborted" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && printf '%s\n' "$json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["counts"]["failed"] == 1
assert data["counts"]["aborted"] == 1
assert data["counts"]["non_clean"] == 0
assert [task["process"] for task in data["failed_tasks"]] == ["ROOT"]
'; then
  ok 'JSON separates root failure from aborted sibling'
else
  bad 'JSON separates root failure from aborted sibling'
fi

# A non-clean exit with another status is diagnostic evidence, not a FAILED row.
printf 'status\texit\texit_status\tname\r\nABORTED\t\t143\tSIBLING\r\nUNKNOWN\t\t-1\tNON_CLEAN\r\nRUNNING\t\t1\tLIVE\r\n' \
  > "$TMP/aborted/reports/trace.aborted.txt"
printf '%s\n' 'Session aborted -- Cause: SIGTERM' > "$TMP/aborted/.nextflow.log"
json="$(bash "$SRC" --json "$TMP/aborted" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && printf '%s\n' "$json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["status"] == "cancelled"
assert data["counts"]["failed"] == 0
assert data["counts"]["aborted"] == 1
assert data["counts"]["non_clean"] == 1
assert data["failed_tasks"] == []
'; then
  ok 'CRLF exit_status trace keeps non-clean and running rows out of failures'
else
  bad 'CRLF exit_status trace keeps non-clean and running rows out of failures'
fi

mkdir -p "$TMP/empty"
output="$(bash "$SRC" "$TMP/empty" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && contains "$output" 'status: unknown' && contains "$output" 'last log time: (unavailable)' \
  && ok 'readable directory without terminal evidence stays zero' || bad 'empty readable directory failed'
json="$(bash "$SRC" --json "$TMP/empty" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && contains "$json" '"status":"unknown","last_log_time":null' \
  && contains "$json" '"aborted":null,"non_clean":null' \
  && ok 'empty JSON has unknown state and unavailable time' || bad 'empty JSON has unknown state and unavailable time'

bash "$SRC" "$TMP/does-not-exist" >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok 'unreadable run directory is non-zero' || bad 'missing directory returned zero'

if LC_ALL=C awk '/\r$/ { bad=1 } END { exit bad }' "$SRC"; then
  ok 'script is LF-only'
else
  bad 'script contains CRLF'
fi

after="$(snapshot "$FIXTURES")"
[[ "$before" == "$after" ]] && ok 'triage left the fixture byte-identical' || bad 'triage changed its input'

printf '\ntriage-run: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
