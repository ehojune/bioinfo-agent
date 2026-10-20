#!/usr/bin/env bash
# Detached full-sheet stub gate; prevents caller disconnects, not O(N) task cost.
set -euo pipefail

die() { printf 'stub-gate: %s\n' "$*" >&2; exit 2; }
contract_key() {
    case "$1" in
        PATH|HOME|JAVA_HOME|JAVA_TOOL_OPTIONS|JDK_JAVA_OPTIONS|TMPDIR|NXF_*|BIOINFO_*|APPTAINER_*|SINGULARITY_*|DOCKER_*|SSL_CERT_FILE|SSL_CERT_DIR|REQUESTS_CA_BUNDLE|CURL_CA_BUNDLE|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy) return 0 ;;
        *) return 1 ;;
    esac
}
release_lock() {
    [[ -r $lock/owner && $(cat -- "$lock/owner") == "$owner" ]] || return 0
    rm -- "$lock/owner"
    rmdir -- "$lock"
}
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
previous=
for arg in "$@"; do
    case "$arg" in
        -preview|-preview=*|--help|--help=*|-help|-h|-version|--version)
            die "preview/help/version flags do not execute a stub gate" ;;
    esac
    [[ $previous != -stub-run || ( $arg != false && $arg != true ) ]] || die "use the bare -stub-run flag"
    [[ $arg != -log && $arg != -log=* ]] || die "helper owns -log"
    [[ $arg != -with-trace && $arg != -with-trace=* ]] || die "helper owns -with-trace"
    [[ $arg != -stub && $arg != -stub-run=* ]] || die "use the exact -stub-run flag"
    [[ $arg != -stub-run ]] || found=$((found+1))
    previous=$arg
done
[[ $found -eq 1 ]] || die "exactly one -stub-run is required"
command -v tmux >/dev/null || die "tmux is required"
command -v "$1" >/dev/null || die "Nextflow executable not found"
mkdir -p "$run/.stub-gates"
lock="$run/.stub-gates/active"
mkdir "$lock" 2>/dev/null || die "another gate is active or left an interrupted lock; inspect before clearing"
owner="$session:$$"
printf '%s\n' "$owner" > "$lock/owner"
phase=prepare
trap '[[ $phase != prepare ]] || release_lock' EXIT
# An existing attempt is immutable; a retry needs a new label.
mkdir "$gate" 2>/dev/null || die "label already exists; use a new attempt label"
# Snapshot names as well as values. The server may still export a variable the
# caller deliberately unset (especially NXF_OFFLINE or an old NXF_WORKROOT).
env_args=()
env_keys=()
while IFS= read -r key; do
    if contract_key "$key"; then
        env_args+=(-e "$key=${!key}")
        env_keys+=("$key")
    fi
done < <(compgen -e)
runner="$gate/runner.sh"
{
    printf '#!/usr/bin/env bash\nset -uo pipefail\n'
    printf 'gate=%q\nlock=%q\nowner=%q\n' "$gate" "$lock" "$owner"
    declare -f release_lock
    printf 'trap '\''release_lock'\'' EXIT\n'
    printf 'cd -- %q || exit 2\n' "$run"
    declare -f contract_key
    printf 'declare -A keep_env=('
    for key in "${env_keys[@]}"; do printf '[%q]=1 ' "$key"; done
    printf ')\n'
    printf 'while IFS= read -r key; do\n'
    printf '  if contract_key "$key" && [[ -z ${keep_env[$key]+present} ]]; then unset "$key"; fi\n'
    printf 'done < <(compgen -e)\n'
    printf 'record() {\n  printf "%%s\\n" "$1" > "$gate/exit-code.tmp"\n'
    printf '  mv -- "$gate/exit-code.tmp" "$gate/exit-code"\n'
    printf '  case "$1" in 0) state=PASS;; 129|130|137|143) state=INTERRUPTED;; *) state=FAILED;; esac\n'
    printf '  printf "%%s\\n" "$state" > "$gate/state.tmp"\n  mv -- "$gate/state.tmp" "$gate/state"\n}\n'
    # A signal can arrive between spawning the child and assigning $!. Buffer it
    # until the PID is known; never release the lock while that child can run.
    printf 'child=\npending_signal=\n'
    printf 'interrupted() {\n  if [[ -z $child ]]; then pending_signal=$1; return; fi\n'
    printf '  trap "" HUP INT TERM\n  kill -TERM "$child" 2>/dev/null || true\n'
    printf '  wait "$child" 2>/dev/null\n  record "$1"\n  exit "$1"\n}\n'
    printf 'trap "interrupted 129" HUP\ntrap "interrupted 130" INT\ntrap "interrupted 143" TERM\n'
    printf 'command=('
    printf '%q ' "$1" -log "$gate/nextflow.log" "${@:2}" -with-trace "$gate/trace.txt"
    printf ')\n'
    printf '"${command[@]}" > "$gate/console.log" 2>&1 &\nchild=$!\n'
    printf '[[ -z $pending_signal ]] || interrupted "$pending_signal"\n'
    printf 'printf "%%s\\n" "$child" > "$gate/head.pid"\nprintf "ready\\n" > "$gate/ready"\n'
    printf 'wait "$child"\nrc=$?\nrecord "$rc"\nexit "$rc"\n'
} > "$runner"
# Values are sent to tmux, not persisted in runner.sh. Absent names are unset in
# this new session only, without changing other sessions or the global server.
printf -v launch 'bash %q' "$runner"
# From here onward a disconnected launcher must leave the lock intact: tmux may
# already have created the session even when the client has not returned.
phase=launching
if ! tmux new-session -d -s "$session" -c "$run" "${env_args[@]}" "$launch"; then
    printf 'LAUNCH_FAILED\n' > "$gate/state"
    die "tmux launch failed; inspect $gate"
fi
# Acknowledge that the runner owns the child and installed its signal handlers.
for _ in {1..100}; do
    [[ ! -r $gate/ready ]] || break
    sleep 0.05
done
[[ -r $gate/ready ]] || die "runner readiness unconfirmed; retain the lock and inspect $gate"
trap - EXIT
printf 'session: %s\nrecord: %s\n' "$session" "$gate"
