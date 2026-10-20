#!/usr/bin/env bash
# Offline integration fixtures: run the real preflight gate, never launch Nextflow.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/work" "$TMP/refs" "$TMP/repository" "$TMP/runlog"
export BIOINFO_HOME="$TMP/repository" BIOINFO_RUNLOG="$TMP/runlog"
export BIOINFO_REFS="$TMP/refs" NXF_WORKROOT="$TMP/work"
export TEST_DF_LOG="$TMP/df.log" TEST_RESULT_BYTES=150000000 TEST_DF_MODE=normal
export PATH="$TMP/bin:$PATH"

cat > "$TMP/bin/df" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${@: -1}" >> "$TEST_DF_LOG"
if [ "$1" = -BG ]; then
  printf 'Avail\n4096G\n'
elif [ "${@: -1}" = "$TEST_RESULT_PROBE" ]; then
  case "$TEST_DF_MODE" in
    fail) exit 1 ;;
    malformed) printf 'Avail\nunknown\n' ;;
    *) printf 'Avail\n%s\n' "$TEST_RESULT_BYTES" ;;
  esac
else
  # The repo/runlog default has plenty of room; only the actual RUNDIR matters.
  printf 'Avail\n900000000000\n'
fi
MOCK
cat > "$TMP/bin/docker" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  version*) printf 'test-version\n' ;;
  *DockerRootDir*) printf '/var/lib/docker\n' ;;
esac
MOCK
cat > "$TMP/bin/nextflow" <<'MOCK'
#!/usr/bin/env bash
[ "$*" = -v ] || { printf 'unexpected Nextflow invocation\n' >&2; exit 99; }
printf 'nextflow test-version\n'
MOCK
cat > "$TMP/bin/pgrep" <<'MOCK'
#!/usr/bin/env bash
printf '0\n'
exit 1
MOCK
chmod +x "$TMP/bin/"*

passed=0
ok() { passed=$((passed + 1)); printf 'ok %d - %s\n' "$passed" "$1"; }
die() { printf 'FAIL: %s\n' "$1" >&2; cat "$TMP/output" >&2; exit 1; }
contains() { grep -Fq -- "$1" "$TMP/output" || die "missing output: $1"; }
fixture() {
  mkdir -p "$1"
  local pin
  pin="$(awk -F'\t' '$1=="fetchngs"{print $2}' "$REPO/config/pipelines.tsv")"
  printf 'nextflow run nf-core/fetchngs -r %s -profile docker -work-dir "%s"\n' "$pin" "$NXF_WORKROOT" > "$1/cmd.sh"
  printf 'SRR12345\n' > "$1/samplesheet.csv"
  printf 'Revision: %s\nAccessions: 1\n' "$pin" > "$1/plan.md"
}
run_gate() {
  local expected="$1" actual=0
  shift
  : > "$TEST_DF_LOG"
  bash "$REPO/bin/preflight.sh" "$@" > "$TMP/output" 2>&1 || actual=$?
  [ "$actual" -eq "$expected" ] || die "exit $actual, expected $expected"
}
checked_destination() {
  grep -Fxq -- "$TEST_RESULT_PROBE" "$TEST_DF_LOG" || die "df did not inspect the actual destination"
  if grep -Fxq -- "$BIOINFO_HOME" "$TEST_DF_LOG" ||
     grep -Fxq -- "$BIOINFO_RUNLOG" "$TEST_DF_LOG"; then
    die "df substituted the repository or default runlog for RUNDIR"
  fi
}

RUNDIR="$TMP/actual results/run with spaces"
fixture "$RUNDIR"
export TEST_RESULT_PROBE="$RUNDIR"
before="$(sha256sum "$RUNDIR/"*)"
run_gate 0 "$RUNDIR" 1 100
checked_destination
contains 'free 150 MB >= 1.5x output estimate (100 MB)'
[ "$before" = "$(sha256sum "$RUNDIR/"*)" ] || die "preflight changed the run record"
[ ! -e "$RUNDIR/results" ] || die "preflight created a results directory"
ok 'actual Linux destination with spaces passes at the exact capacity boundary without writes'

export TEST_RESULT_BYTES=149999999
run_gate 1 "$RUNDIR" 1 100
checked_destination
contains 'free 149 MB < 1.5x output estimate (100 MB). DO NOT LAUNCH.'
ok 'one byte below the output threshold fails despite ample space at BIOINFO_HOME'

export TEST_RESULT_BYTES=150000000
run_gate 0 "$RUNDIR" 1
contains 'capacity unchecked against an estimate'
ok 'legacy two-argument calls warn explicitly instead of certifying result capacity'

MISSING="$TMP/actual results/not created/child"
export TEST_RESULT_PROBE="$TMP/actual results"
run_gate 1 "$MISSING" 1 100
checked_destination
contains "results target $MISSING (measured at $TEST_RESULT_PROBE): free 150 MB >="
contains "missing $MISSING/cmd.sh"
[ ! -e "$TMP/actual results/not created" ] || die "preflight created an absent run directory"
ok 'nonexistent nested run uses its existing ancestor and creates nothing'

ln -s "$RUNDIR" "$TMP/run link"
export TEST_RESULT_PROBE="$TMP/run link"
run_gate 0 "$TMP/run link" 1 100
checked_destination
contains "measured at $TMP/run link"
ok 'existing directory symlink is passed intact to df for filesystem resolution'

run_gate 1 "$TMP/run link/new/child" 1 100
checked_destination
contains "measured at $TMP/run link"
[ ! -e "$RUNDIR/new" ] || die "preflight wrote through the symlink"
ok 'missing descendants of a directory symlink use the linked ancestor without writes'

export TEST_RESULT_PROBE="$RUNDIR" TEST_DF_MODE=fail
run_gate 1 "$RUNDIR" 1 100
contains "cannot measure results target $RUNDIR"
ok 'df failure refuses launch'

export TEST_DF_MODE=malformed
run_gate 1 "$RUNDIR" 1 100
contains "cannot measure results target $RUNDIR"
ok 'unparseable df capacity refuses launch'

export TEST_DF_MODE=normal TEST_RESULT_BYTES=0
run_gate 0 "$RUNDIR" 1 0
contains 'free 0 MB >= 1.5x output estimate (0 MB)'
ok 'explicit zero output estimate remains distinct from an omitted estimate'

for estimate in -1 1.5 1000000000 '1+1'; do
  run_gate 2 "$RUNDIR" 1 "$estimate"
  contains 'estimates must be nonnegative integers'
  [ ! -s "$TEST_DF_LOG" ] || die "invalid estimate reached a filesystem check"
done
ok 'negative, fractional, oversized and arithmetic output inputs are rejected before evaluation'

export TEST_RESULT_BYTES=1500000000000000
run_gate 0 "$RUNDIR" 1 999999999
contains '1.5x output estimate (999999999 MB)'
ok 'maximum accepted output estimate stays within integer arithmetic range'

printf 'PASS: %d preflight integration scenarios\n' "$passed"
