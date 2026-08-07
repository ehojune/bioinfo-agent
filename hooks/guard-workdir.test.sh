#!/usr/bin/env bash
# guard-workdir.test.sh — exit-code tests for guard-workdir.sh. Read-only, safe to run anytime.
#
#   bash hooks/guard-workdir.test.sh
#
# RUN THIS AFTER EVERY EDIT TO guard-workdir.sh. That hook is ~300 lines of regex and shell
# string handling whose entire output is one bit, allow or deny, which makes it both the easiest
# thing here to test and the easiest to break silently. PR #18 changed its matching six times;
# five of those rounds introduced or exposed a real hole, and each round's evidence lived only in
# a throwaway shell probe. This file is that evidence, kept.
#
# EXIT CODES ONLY. Nothing here asserts on the wording of a deny message. Those get rewritten
# often — three times in PR #18 alone — and a test that fails on rephrasing is a test people
# delete. What must not change without someone deciding to change it is which commands get
# through.
#
# HERMETIC. Every case runs with the ambient BIOINFO_*/NXF_*/CLAUDE_* variables cleared and HOME
# pointed at an empty directory, so a case that needs a root sets it explicitly and the machine
# this runs on cannot change the answer. Fixtures live in a temp dir and are removed at exit.

set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/guard-workdir.sh"
[ -r "$SRC" ] || { printf 'cannot read %s\n' "$SRC" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/nohome" "$TMP/fakerepo/hooks"

# RUN A COPY, FROM A DIRECTORY WITH NO config/. The hook looks for host.env beside itself, and
# beside the real one sits the developer's own config/host.env -- gitignored, so absent from a
# fresh clone, but present on any machine that has been set up. Testing in place therefore let
# that file answer for the fixtures below, and the first run of this suite failed a case for
# that reason and no other. The copy is byte-identical and made fresh on every run.
# The copy keeps the real <repo>/hooks/<script> layout, because the hook resolves that
# candidate as $(dirname $0)/../config/host.env and a flat copy would look one level too high.
HOOK="$TMP/fakerepo/hooks/guard-workdir.sh"
cp "$SRC" "$HOOK"

pass=0; fail=0
section() { printf '\n== %s ==\n' "$*"; }

# check <allow|deny> <command> [VAR=value ...]
check() {
  local want="$1" cmd="$2"; shift 2
  local esc got rc
  # Newlines are escaped too, not just backslash and quote: a raw newline inside a JSON string
  # is invalid, the hook's extraction then finds nothing, and it fails open — so a case written
  # with a real newline would have "passed" by never being parsed at all.
  esc="$(printf '%s' "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g' \
         | awk '{ printf "%s%s", (NR>1 ? "\\n" : ""), $0 }')"
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$esc" \
    | env -u BIOINFO_WORK -u NXF_WORKROOT -u BIOINFO_RUNLOG -u BIOINFO_ARCHIVE_DISTRO \
          -u BIOINFO_HOST_ENV -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR \
          -u BIOINFO_WORKDIR_HOLD_DAYS \
          HOME="$TMP/nohome" BIOINFO_HOME="$TMP/nohome" "$@" \
          bash "$HOOK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && got=allow || got=deny
  if [ "$got" = "$want" ]; then
    pass=$((pass+1)); printf '  ok    %-6s %s\n' "$got" "$cmd"
  else
    fail=$((fail+1)); printf '  FAIL  want=%-5s got=%-5s %s\n' "$want" "$got" "$cmd"
  fi
}

section "readers and unrelated targets pass through"
check allow 'echo hello'
check allow "grep -r 'nextflow clean' docs/"
check allow 'rm -rf node_modules'
check allow 'rm -rf ./build'
check allow 'rm -rf /tmp/scratch/foo'
check allow 'rm -rf /c/Users/admin/tmp/x'
check allow 'rm -rf "$TMPD"'
check allow 'rm -rf "$dest"'
check allow 'rm -rf /tmp/$USER/workspace'

section "1. cleanup flags"
check deny 'nextflow run nf-core/rnaseq -with-cleanup'
check deny 'echo "cleanup = true" >> nextflow.config'

section "3. collapsed paths — an unset root reaching the filesystem root"
check deny 'rm -rf /'
check deny 'rm -rf /*'
check deny 'rm -rf ""'
check deny 'rm -rf /runs'
check deny 'rm -rf /runs/'
check deny 'rm -rf /runs/*'
check deny 'rm -rf "/refs"'

section "4. nextflow clean"
check deny 'nextflow clean -n -before myrun'

section "5. the work root and one run under it"
check deny 'rm -rf /work'
check deny 'rm -rf /work/'
check deny 'rm -rf /work/nxf'
check deny 'rm -rf /work/nxf/20260728-x/work'

section "5. paths that merely CONTAIN the root string"
# Each of these was denied as "the entire work root (/work)" before the token split.
check allow 'rm -rf /mnt/e/workspace/tmp'
check allow 'rm -rf /mnt/d/workflow_old'
check allow 'rm -rf /home/u/projects/network/work'

section "5. unexpanded variables — no run id, so no run-state check is possible"
check deny 'rm -rf "$NXFDIR/work"'
check deny 'rm -rf "$NXF_WORKROOT/demo/work"'
check deny 'rm -rf "$BIOINFO_WORK/nxf/run1/work"'
check deny 'rm -rf ${NXFDIR}/work'
check deny 'rm -rf "$NXFDIR"'
check deny 'rm -rf "$W/nxf/run1/work"'

section "root normalization — trailing and repeated slashes"
check deny  'rm -rf /scratch/nxf/run/work'   NXF_WORKROOT=/scratch/nxf
check deny  'rm -rf /scratch/nxf/run/work'   NXF_WORKROOT=/scratch/nxf/
check deny  'rm -rf /scratch/nxf/run/work'   NXF_WORKROOT=/scratch//nxf//
check deny  'rm -rf /nxf/run/work'           BIOINFO_WORK=/
check deny  'rm -rf /work/nxf/run/work'      BIOINFO_WORK=/work/
check deny  'rm -rf /bigdisk/work/nxf/r/work' BIOINFO_WORK=/bigdisk/work
check allow 'rm -rf /bigdisk/workspace'       BIOINFO_WORK=/bigdisk/work

section "root-agnostic layout — the root is configured somewhere this hook cannot read"
# hooks.json starts the hook on the Windows side; a root exported only inside the distro is
# invisible there. <anything>/nxf/<runid> is recognisable without knowing the root.
check deny  "wsl -d Ubuntu-24.04 -- bash -lc 'rm -rf /scratch/nxf/demo/work'"
check deny  'rm -rf /scratch/nxf/demo/work'
check deny  'rm -rf /scratch/nxf'
check deny  'rm -rf /some/other/root/nxf/run7/work'
check allow 'rm -rf /some/other/root/results'

section "host.env discovery — where the file can be, given host.env is gitignored"
mkdir -p "$TMP/viahome/config" "$TMP/cache/config" "$TMP/proj/config" "$TMP/home2/bioinfo-agent/config"
printf 'BIOINFO_WORK=/rootA/work\n' > "$TMP/viahome/config/host.env"
printf 'BIOINFO_WORK=/rootB/work\n' > "$TMP/cache/config/host.env"
printf 'BIOINFO_WORK=/rootC/work\n' > "$TMP/proj/config/host.env"
printf 'BIOINFO_WORK=/rootD/work\n' > "$TMP/home2/bioinfo-agent/config/host.env"
printf 'BIOINFO_WORK=/rootE/work\n' > "$TMP/explicit.env"
check deny 'rm -rf /rootA/work' BIOINFO_HOME="$TMP/viahome"
check deny 'rm -rf /rootB/work' CLAUDE_PLUGIN_ROOT="$TMP/cache"
check deny 'rm -rf /rootC/work' CLAUDE_PROJECT_DIR="$TMP/proj"
check deny 'rm -rf /rootD/work' HOME="$TMP/home2"
check deny 'rm -rf /rootE/work' BIOINFO_HOST_ENV="$TMP/explicit.env"
# beside the script — the symlink/junction install route
mkdir -p "$TMP/fakerepo/config"
printf 'BIOINFO_WORK=/rootF/work\n' > "$TMP/fakerepo/config/host.env"
check deny 'rm -rf /rootF/work'
rm -rf "$TMP/fakerepo/config"   # restore the hermetic baseline for everything after this

section "host.env — the LAST assignment wins, as load_host_env does"
printf 'BIOINFO_WORK=/old/work\nBIOINFO_WORK=/bigdisk/work\n' > "$TMP/lastwins.env"
check deny  'rm -rf /bigdisk/work' BIOINFO_HOST_ENV="$TMP/lastwins.env"
check allow 'rm -rf /old/work'     BIOINFO_HOST_ENV="$TMP/lastwins.env"

section "host.env — the last ACCEPTED assignment wins"
printf 'BIOINFO_WORK=/bigdisk/work\nBIOINFO_WORK=$(not-allowed)\n' > "$TMP/invalid-last.env"
check deny 'rm -rf /bigdisk/work' BIOINFO_HOST_ENV="$TMP/invalid-last.env"
printf 'BIOINFO_WORK=$(not-allowed)\nBIOINFO_WORK=/bigdisk/work\n' > "$TMP/valid-last.env"
check deny 'rm -rf /bigdisk/work' BIOINFO_HOST_ENV="$TMP/valid-last.env"
printf 'BIOINFO_WORK=/bigdisk/work\nBIOINFO_WORK=\n' > "$TMP/empty-last.env"
check allow 'rm -rf /bigdisk/work' BIOINFO_HOST_ENV="$TMP/empty-last.env"

section "host.env line forms — must match bootstrap/lib/host-env.sh exactly"
i=0
while IFS= read -r line; do
  i=$((i+1)); printf '%s\n' "$line" > "$TMP/form$i.env"
  check deny 'rm -rf /bigdisk/work' BIOINFO_HOST_ENV="$TMP/form$i.env"
done <<'FORMS'
BIOINFO_WORK=/bigdisk/work
export BIOINFO_WORK=/bigdisk/work
   export   BIOINFO_WORK=/bigdisk/work
BIOINFO_WORK = /bigdisk/work
BIOINFO_WORK="/bigdisk/work"
BIOINFO_WORK='/bigdisk/work'
BIOINFO_WORK=/bigdisk/work   # trailing comment
export BIOINFO_WORK="/bigdisk/work"  # both
FORMS

section "a root containing a space — the loader supports it, so the guard must too"
printf 'BIOINFO_WORK="/big disk/work"\n' > "$TMP/space.env"
check deny  'rm -rf /big\ disk/work/nxf/demo/work'   BIOINFO_HOST_ENV="$TMP/space.env"
check deny  'rm -rf "/big disk/work/nxf/demo/work"'  BIOINFO_HOST_ENV="$TMP/space.env"
check deny  "rm -rf '/big disk/work/nxf/demo/work'"  BIOINFO_HOST_ENV="$TMP/space.env"
check deny  'rm -rf /big\ disk/work'                 BIOINFO_HOST_ENV="$TMP/space.env"
check allow 'rm -rf /big\ disk/workspace'            BIOINFO_HOST_ENV="$TMP/space.env"

section "escaped space inside a quoted inner command — the composed WSL form"
check deny  "wsl -d Ubuntu -- bash -lc 'rm -rf /big\\ disk/work/nxf/demo/work'" BIOINFO_HOST_ENV="$TMP/space.env"
check deny  'wsl -d Ubuntu -- bash -lc "rm -rf /big\ disk/work/nxf/demo/work"'  BIOINFO_HOST_ENV="$TMP/space.env"
check allow "wsl -d Ubuntu -- bash -lc 'ls /big\\ disk/work'"                   BIOINFO_HOST_ENV="$TMP/space.env"

section "an inherited root must not suppress host.env — protect both"
# load_host_env exports unconditionally, so after a host move the FILE holds the live root while
# a stale shell still exports the dead one. Guessing a winner risks guarding only the dead tree.
printf 'BIOINFO_WORK=/bigdisk/work\n' > "$TMP/moved.env"
check deny 'rm -rf /bigdisk/work'          BIOINFO_HOST_ENV="$TMP/moved.env" BIOINFO_WORK=/old/work
check deny 'rm -rf /old/work'              BIOINFO_HOST_ENV="$TMP/moved.env" BIOINFO_WORK=/old/work
check deny 'rm -rf /bigdisk/work/nxf/r/work' BIOINFO_HOST_ENV="$TMP/moved.env" BIOINFO_WORK=/old/work
check deny 'rm -rf /old/work/nxf/r/work'     BIOINFO_HOST_ENV="$TMP/moved.env" BIOINFO_WORK=/old/work
check allow 'rm -rf /unrelated/work'         BIOINFO_HOST_ENV="$TMP/moved.env" BIOINFO_WORK=/old/work

section "a root containing an ERE metacharacter"
printf 'BIOINFO_WORK=/ref+store/work\n' > "$TMP/meta.env"
check deny  'rm -rf /ref+store/work'            BIOINFO_HOST_ENV="$TMP/meta.env"
check deny  'rm -rf /ref+store/work/nxf/r/work' BIOINFO_HOST_ENV="$TMP/meta.env"
check allow 'rm -rf /refstore/work'             BIOINFO_HOST_ENV="$TMP/meta.env"
check allow 'rm -rf /reffff+store/work'         BIOINFO_HOST_ENV="$TMP/meta.env"

section "a root containing a shell-pattern metacharacter"
printf 'BIOINFO_WORK=/ref?/work\n' > "$TMP/glob.env"
check deny 'rm -rf "/ref?/work"' BIOINFO_HOST_ENV="$TMP/glob.env" BIOINFO_WORK=/ref1/work
check deny 'rm -rf /ref1/work'    BIOINFO_HOST_ENV="$TMP/glob.env" BIOINFO_WORK=/ref1/work

section "/nxf as a TOP-LEVEL root — the shape match must not require a prefix"
check deny  'rm -rf /nxf/demo/work'
check deny  "wsl -d Ubuntu -- bash -lc 'rm -rf /nxf/demo/work'"
check deny  'rm -rf /nxf'
check allow 'rm -rf /nxfstuff/demo'

section "escaped shell separators in a root — ; | & are legal in a directory name"
# host.env cannot carry these (host-env.sh rejects them, and so does this hook's reader), so
# the root can only arrive inherited. Bash writes the target with the separator escaped, and
# splitting on it regardless tore the path apart before any matcher saw it.
check deny  'rm -rf /big\&disk/work'               BIOINFO_WORK='/big&disk/work'
check deny  'rm -rf /big\&disk/work/nxf/demo/work' BIOINFO_WORK='/big&disk/work'
check deny  'rm -rf /big\&disk/work/nxf'           BIOINFO_WORK='/big&disk/work'
check allow 'rm -rf /big\&disk/workspace'          BIOINFO_WORK='/big&disk/work'
check deny  'rm -rf /semi\;disk/work'              BIOINFO_WORK='/semi;disk/work'
check deny  'rm -rf /pipe\|disk/work'              BIOINFO_WORK='/pipe|disk/work'
# an UNescaped separator is still a separator
check allow 'echo hi & echo bye'
check deny  'echo hi ; rm -rf /work'

section "backslash-escaped path characters — the shell drops the backslash, so must the tokenizer"
check deny  'rm -rf /ref\?/work'             BIOINFO_WORK='/ref?/work'
check deny  'rm -rf /ref\?/work/nxf/r/work'  BIOINFO_WORK='/ref?/work'
check deny  'rm -rf /ref\*/work'             BIOINFO_WORK='/ref*/work'
check deny  'rm -rf /a\(b/work'              BIOINFO_WORK='/a(b/work'
check deny  'rm -rf /d\$x/work'              BIOINFO_WORK='/d$x/work'
check allow 'rm -rf /ref1/work'              BIOINFO_WORK='/ref?/work'

section "backslash parity — an escaped backslash does not escape what follows it"
# bash runs TWO commands for the even case (verified: it prints `x\` then runs the second), and
# ONE for the odd case. Hiding the separator on "a backslash precedes it" got that backwards and
# let the second command hide behind the reader exemption.
check deny  'echo x\\; rm -rf /work'
check allow 'echo x\; rm -rf /work'

section "a newline is a command separator; a space is not"
# The no-jq extraction mapped \n to a space, which merged two commands into one segment and let
# the reader exemption judge the pair by the first verb. jq keeps the newline, so this bypass
# existed only on the Windows side — the side hooks.json actually starts the hook on.
check deny 'echo a
rm -rf /work'
check deny 'cat foo
rm -rf /work/nxf/r/work'

section "backslash-newline continuation — bash removes both and welds the word"
check deny  'rm -rf /big\
disk/work'                    BIOINFO_WORK=/bigdisk/work
check allow 'rm -rf /big\\
disk/work'                    BIOINFO_WORK=/bigdisk/work

section "QUOTED separators — the commoner spelling of a path with a special character"
check deny  'rm -rf "/foo/big&disk/work"'             BIOINFO_WORK='/foo/big&disk/work'
check deny  'rm -rf "/foo/big&disk/work/nxf/r/work"'  BIOINFO_WORK='/foo/big&disk/work'
check allow 'rm -rf "/foo/big&disk/workspace"'        BIOINFO_WORK='/foo/big&disk/work'
check deny  "rm -rf '/foo/semi;disk/work'"            BIOINFO_WORK='/foo/semi;disk/work'
check deny  'rm -rf "/foo/pipe|disk/work"'            BIOINFO_WORK='/foo/pipe|disk/work'
# and an UNquoted separator is still a separator, so the hidden-command cases stay denied
check deny  'echo hi ; rm -rf /work'
check deny  'echo hi && rm -rf /work'

section 'inside "" a backslash escapes only $ ` " \ and newline'
# bash resolves "/foo/a\&b/work" to /foo/a\&b/work — the backslash is a literal character
# there, so a root that genuinely contains one must still match.
check deny  'rm -rf "/foo/a\&b/work"'              BIOINFO_WORK='/foo/a\&b/work'
check deny  'rm -rf "/foo/a\&b/work/nxf/r/work"'   BIOINFO_WORK='/foo/a\&b/work'
check allow 'rm -rf "/foo/a\&b/workspace"'         BIOINFO_WORK='/foo/a\&b/work'
# and outside quotes the same two characters ARE an escape, so this root has no backslash
check deny  'rm -rf /foo/a\&b/work'                BIOINFO_WORK='/foo/a&b/work'

section "\$'…' and \$\"…\" are quote introducers, not expansions"
# bash resolves $'/work' to /work. Leaving the $ attached made the token read $/work.
check deny  "rm -rf \$'/work'"
check deny  "rm -rf \$'/work/nxf/r/work'"
check deny  'rm -rf $"/work"'
check allow "rm -rf \$'/workspace/tmp'"
# and a real expansion must stay an unexpanded variable, not be read as a quote
check deny  'rm -rf $NXFDIR/work'
check allow 'rm -rf $HOME/tmp'

section "repeated slashes in the TARGET, not just in the configured root"
# rm treats /work// as /work. Roots were normalized from the start and targets were not.
check deny 'rm -rf /work//'
check deny 'rm -rf /work///'
check deny 'rm -rf /work//nxf'
check deny 'rm -rf /work//nxf//run1//work'
check deny 'rm -rf /work/'

section "runbook section 9 — the reclaim must become possible, not stay blocked forever"
W="$TMP/fakework"; mkdir -p "$W/nxf/testrun/work"
check deny  "rm -rf $W/nxf/testrun/work" BIOINFO_WORK="$W"          # no handoff yet
touch "$W/nxf/testrun/handoff.md"
check deny  "rm -rf $W/nxf/testrun/work" BIOINFO_WORK="$W"          # inside the hold
touch -d '30 days ago' "$W/nxf/testrun/handoff.md" 2>/dev/null \
  || touch -t "$(date -d '30 days ago' +%Y%m%d0000 2>/dev/null || echo 202001010000)" "$W/nxf/testrun/handoff.md"
check allow "rm -rf $W/nxf/testrun/work" BIOINFO_WORK="$W"          # past the hold

section "the liveness scan must match the JVM, not the tmux server that outlives it"
# runbook section 5 launches every run as
#   tmux new-session -d -s <name> -e NXF_HOME=…/.nextflow … "bash '<rundir>/cmd.sh'"
# and that argv becomes the tmux SERVER's own command line for as long as the server lives —
# which is longer than the run, and longer than the NEXT run, since a later session reuses the
# same server while its argv still names the FIRST run. An unfiltered
# `pgrep -f "nextflow.*/<runid>/"` therefore reports a finished run as live forever and the
# section 9 reclaim above stops working. Stand in a non-JVM process carrying exactly that shape
# and require the reclaim to still be allowed; then a real JVM would have to be `java` to block.
if command -v pgrep >/dev/null 2>&1 && [ -r /proc/self/comm ]; then
  # ONE process, not a wrapper plus a child. `exec -a` (bash, not POSIX sh — the earlier `sh -c`
  # spelling of this failed with "exec: -a: not found" and the case went green while exercising
  # nothing) replaces the shell with `sleep` itself, carrying the tmux-server argv shape as
  # argv[0], which is what pgrep -f reads. So $! is the whole stand-in and killing it leaves
  # nothing behind: a wrapper-plus-child version orphans `sleep 60` for a minute after the suite
  # exits, still holding the harness's stdout. comm stays `sleep`, i.e. not `java`, which is the
  # property under test. Descriptors closed anyway, belt and braces.
  bash -c 'exec -a "tmux new-session -d -s x -e NXF_HOME=/h/.nextflow bash '"$W"'/nxf/testrun/cmd.sh" sleep 60' \
    >/dev/null 2>&1 &
  _fakepid=$!
  trap 'kill '"$_fakepid"' 2>/dev/null; rm -rf "$TMP"' EXIT
  sleep 0.3
  if pgrep -f "nextflow.*/testrun/" >/dev/null 2>&1; then
    check allow "rm -rf $W/nxf/testrun/work" BIOINFO_WORK="$W"      # non-JVM match must not block
  else
    # The stand-in did not take, so an "allow" here would prove nothing. Say so rather than
    # bank a vacuous pass — that is exactly how this case first went green while testing nothing.
    fail=$((fail+1)); printf '  FAIL  stand-in process not visible to pgrep; case not exercised\n'
  fi
  kill "$_fakepid" 2>/dev/null
  trap 'rm -rf "$TMP"' EXIT
else
  printf '  skip  no pgrep or no /proc — JVM-filter case not exercised\n'
fi

printf '\nguard-workdir: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
