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
  && contains "$output" 'process: PROCESS_ONE' && contains "$output" 'process: PROCESS_TWO' \
  && contains "$output" 'tag: sample_B (retry)' \
  && ok 'every failed task and header-named trace field' || bad 'multiple failed tasks were not reported'

mkdir -p "$TMP/empty"
output="$(bash "$SRC" "$TMP/empty" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && contains "$output" 'status: running' \
  && ok 'readable directory without terminal evidence stays zero' || bad 'empty readable directory failed'

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
