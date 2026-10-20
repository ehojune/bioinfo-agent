#!/usr/bin/env bash
# Detached full-sheet stub gate; prevents caller disconnects, not O(N) task cost.
set -euo pipefail

die() { printf 'stub-gate: %s\n' "$*" >&2; exit 2; }
usage() {
    printf '%s\n' \
        'Usage: stub-gate.sh launch RUN_DIR LABEL -- nextflow run PIPELINE ... -stub-run' \
        '       stub-gate.sh status RUN_DIR LABEL' \
        'Run full-sheet validation/preflight first. Use approved stub work/output paths.' \
        'A stub can run real tools when an upstream module has no stub block.'
}
[[ ${1:-} != --help && ${1:-} != -h ]] || { usage; exit 0; }
[[ $# -ge 3 ]] || { usage >&2; exit 2; }
action=$1; run=$2; label=$3; shift 3
[[ $action == launch || $action == status ]] || die "unknown action"
[[ $label =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$ ]] || die "invalid label"
[[ -d $run ]] || die "run directory does not exist"
run=$(cd "$run" && pwd -P)
gate="$run/.stub-gates/$label"
session="bioinfo-stub-$(printf '%s' "$gate" | sha256sum | cut -c1-20)"

if [[ $action == status ]]; then
    [[ $# -eq 0 ]] || die "unexpected status arguments"
    if [[ -r $gate/state ]]; then
        cat "$gate/state"
    elif [[ -d $gate ]] && tmux has-session -t "=$session" 2>/dev/null; then
        printf 'RUNNING\n'
    else
        printf 'UNKNOWN\n'
    fi
    exit 0
fi

[[ ${1:-} == -- ]] || die "expected -- before Nextflow argv"
shift
[[ $# -ge 4 && ${1##*/} == nextflow && $2 == run ]] || die "pass direct nextflow run argv"
found=0
for arg in "$@"; do
    [[ $arg != -log && $arg != -log=* ]] || die "helper owns -log"
    [[ $arg != -with-trace && $arg != -with-trace=* ]] || die "helper owns -with-trace"
    [[ $arg != -stub && $arg != -stub-run=* ]] || die "use the exact -stub-run flag"
    [[ $arg != -stub-run ]] || found=$((found+1))
done
[[ $found -eq 1 ]] || die "exactly one -stub-run is required"
command -v tmux >/dev/null || die "tmux is required"
command -v "$1" >/dev/null || die "Nextflow executable not found"
mkdir -p "$run/.stub-gates"
lock="$run/.stub-gates/active"
mkdir "$lock" 2>/dev/null || die "another gate is active or left an interrupted lock; inspect before clearing"
trap 'rmdir -- "$lock" 2>/dev/null || true' EXIT
# An existing attempt is immutable; a retry needs a new label.
mkdir "$gate" 2>/dev/null || die "label already exists; use a new attempt label"
runner="$gate/runner.sh"
{
    printf '#!/usr/bin/env bash\nset -uo pipefail\n'
    printf 'gate=%q\ncd -- %q\n' "$gate" "$run"
    printf 'trap '\''rmdir -- "$gate/../active" 2>/dev/null || true'\'' EXIT\n'
    printf 'record() {\n  printf "%%s\\n" "$1" > "$gate/exit-code.tmp"\n'
    printf '  mv -- "$gate/exit-code.tmp" "$gate/exit-code"\n'
    printf '  case "$1" in 0) state=PASS;; 129|130|137|143) state=INTERRUPTED;; *) state=FAILED;; esac\n'
    printf '  printf "%%s\\n" "$state" > "$gate/state.tmp"\n  mv -- "$gate/state.tmp" "$gate/state"\n}\n'
    printf 'interrupted() { trap "" HUP INT TERM; kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null; record "$1"; exit "$1"; }\n'
    printf 'command=('
    printf '%q ' "$1" -log "$gate/nextflow.log" "${@:2}" -with-trace "$gate/trace.txt"
    printf ')\n'
    printf '"${command[@]}" > "$gate/console.log" 2>&1 &\nchild=$!\nprintf "%%s\\n" "$child" > "$gate/head.pid"\n'
    printf 'trap "interrupted 129" HUP\ntrap "interrupted 130" INT\ntrap "interrupted 143" TERM\n'
    printf 'wait "$child"\nrc=$?\nrecord "$rc"\nexit "$rc"\n'
} > "$runner"
# Refresh the known execution contract even if the tmux server predates this shell.
# Do not write the caller's complete environment (which may contain credentials) to disk.
env_args=()
while IFS= read -r key; do
    case "$key" in
        PATH|HOME|JAVA_HOME|TMPDIR|NXF_*|BIOINFO_*|APPTAINER_*|SINGULARITY_*|DOCKER_*)
            env_args+=(-e "$key=${!key}") ;;
    esac
done < <(compgen -e)
printf -v launch 'bash %q' "$runner"
if ! tmux new-session -d -s "$session" -c "$run" "${env_args[@]}" "$launch"; then
    printf 'LAUNCH_FAILED\n' > "$gate/state"
    die "tmux launch failed; inspect $gate"
fi
# The detached runner now owns the lock, including cleanup on ordinary signals.
trap - EXIT
printf 'session: %s\nrecord: %s\n' "$session" "$gate"
