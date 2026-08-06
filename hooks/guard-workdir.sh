#!/usr/bin/env bash
# guard-workdir.sh — PreToolUse hook. Makes the work-directory rule machine-checkable.
#
# WHY THIS EXISTS
# Every other guardrail in this plugin is a sentence in a prompt. A sentence is not a gate.
# This script is the one rule worth enforcing mechanically: a Nextflow work directory is what
# -resume reads, and destroying it turns a recoverable failure into a full re-run of a job that
# may have taken a day. The reclamation procedure in references/runbook.md section 9 is
# legitimate; this hook implements its four conditions instead of restating them.
#
# WHAT IT BLOCKS
#   -with-cleanup / cleanup = true   always. They delete the work dir on success, by design.
#   nextflow clean                   always, from inside an agent. It takes a run NAME, not a
#                                    path, so this hook cannot tie it to a run id and therefore
#                                    cannot check the section 9 conditions. The deny explains
#                                    that and points at running it outside the agent instead.
#   rm -r/-rf under the work root    unless the run is finished, handed off, and past the hold.
#   rm -rf on a collapsed path       e.g. an unset variable turning a path into / or /<one-word>.
#   a pipeline launched in the archive distro ($BIOINFO_ARCHIVE_DISTRO), which is read-only.
#
# WHAT IT DOES NOT DO
# It is not a sandbox. It reads one command string and pattern-matches it. A determined caller
# can defeat it (base64, a wrapper script, an env var holding the path). It exists to stop the
# plausible accident, not an adversary.
#
# FAIL-OPEN, DELIBERATELY. This hook runs on every Bash call in any session where the plugin is
# installed. If it cannot parse its input it exits 0 and lets the normal permission flow decide.
# A guard that blocks everything when jq is missing is worse than no guard.
#
# Protocol: stdin is the PreToolUse JSON; exit 2 with a reason on stderr blocks the call.

set -uo pipefail

WORK_ROOT="${BIOINFO_WORK:-/work}"
# Run directories live under this, one per run id. SAME DERIVATION as bin/preflight.sh:9,
# every cmd.sh, and every NXFDIR= line in references/runbook.md. Hardcoding "$WORK_ROOT/nxf"
# here meant that on a host which sets NXF_WORKROOT elsewhere -- which runbook.md section 2
# tells the operator to export -- this hook matched nothing, and a live run's work directory
# was deletable while the identical command against the default root was blocked.
NXF_ROOT="${NXF_WORKROOT:-${WORK_ROOT}/nxf}"
HOLD_DAYS="${BIOINFO_WORKDIR_HOLD_DAYS:-7}"

deny() { printf 'BLOCKED by bioinfo guard: %s\n' "$1" >&2; exit 2; }
allow() { exit 0; }

INPUT="$(cat 2>/dev/null)" || allow
[ -n "$INPUT" ] || allow

# ---------------------------------------------------------------- extract .tool_input.command
# jq when present (WSL, most Linux). Git Bash on Windows usually has no jq, hence the fallback.
CMD=""
if command -v jq >/dev/null 2>&1; then
  CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
fi
if [ -z "$CMD" ]; then
  # Take the first "command": "..." value, honouring backslash escapes inside the string.
  CMD="$(printf '%s' "$INPUT" \
    | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(\([^"\\]\|\\.\)*\)".*/\1/p' \
    | head -1)"
  # Unescape the sequences that change what the command means.
  CMD="${CMD//\\\"/\"}"; CMD="${CMD//\\n/ }"; CMD="${CMD//\\t/ }"; CMD="${CMD//\\\\/\\}"
fi
[ -n "$CMD" ] || allow          # could not read it — not our call to make

# ---------------------------------------------------------------- drop read-only segments
# A guard that fires on the NAME of a dangerous command is a guard that blocks
#   grep -r 'nextflow clean' docs/
#   echo "never rm -rf /work"
# Both are things you do constantly while working ON this repo. Split the command on the
# separators the checks below already treat as boundaries, and discard any segment whose
# leading verb can only read. What is left is scanned.
#
# The list is deliberately short. sed (-i), git (clean), find (-delete) and xargs are NOT
# on it: each can delete, so each stays subject to the checks.
#
# A redirection cancels the exemption. `echo "cleanup = true" >> nextflow.config` starts with
# a reader but WRITES the setting that destroys -resume, and the verb alone cannot see that.
# Any segment containing `>` is scanned. That costs a false positive on things like
# `grep -r 'nextflow clean' docs/ > out.txt`, which is the right way to be wrong here: the
# exemption exists because reading about a command is not running it, and a redirect is a write.
CMD_SCAN="$(
  printf '%s\n' "$CMD" | tr ';|&' '\n\n\n' | while IFS= read -r _seg || [ -n "$_seg" ]; do
    case "$_seg" in *'>'*) printf '%s\n' "$_seg"; continue ;; esac
    _verb="$(printf '%s' "$_seg" | sed 's/^[[:space:]]*//' | awk '{print $1}')"
    case "${_verb##*/}" in
      echo|printf|grep|egrep|fgrep|rg|ag|cat|head|tail|less|more|wc|diff|comm|sort|uniq|column|nl|strings|jq|test|true|false)
        continue ;;
    esac
    printf '%s\n' "$_seg"
  done
)"
[ -n "${CMD_SCAN//[[:space:]]/}" ] || allow      # every segment was a reader
CMD="$CMD_SCAN"

# ---------------------------------------------------------------- 1. cleanup flags, always
case "$CMD" in
  *-with-cleanup*)
    deny "-with-cleanup deletes the work directory on success and destroys -resume for every
      later invocation. Reclaim space deliberately after handoff instead
      (references/runbook.md section 9)." ;;
esac
if printf '%s' "$CMD" | grep -qE 'cleanup[[:space:]]*=[[:space:]]*true'; then
  deny "cleanup = true makes Nextflow remove the work directory on completion. config/local.config
      section 7 sets it false on purpose. Do not override it."
fi

# ---------------------------------------------------------------- 2. archive distro is read-only
# NO DEFAULT, deliberately. hooks.json starts this as `bash guard-workdir.sh` on the Windows
# side, where BIOINFO_ARCHIVE_DISTRO is only whatever the agent process happened to inherit —
# usually nothing, since host.env lives inside the distro. Defaulting to "Ubuntu-legacy" was
# wrong in both directions: on a host whose archive has another name the real archive went
# unprotected, and on a host with no archive at all a legitimate distro that happened to be
# called Ubuntu-legacy was blocked outright.
#
# So the check only runs when the name is actually known. That narrows this rule to sessions
# that export the variable, and it is the honest scope: a guard that guesses which distro is
# read-only can silently protect the wrong one. The prompt-level rule in agents/bioinfo-tech.md
# still covers the rest.
if [ -n "${BIOINFO_ARCHIVE_DISTRO:-}" ]; then
  esc_archive="$(printf '%s' "$BIOINFO_ARCHIVE_DISTRO" | sed 's/[][\.*^$+?()|{}]/\\&/g')"
  if printf '%s' "$CMD" | grep -qE "wsl(\.exe)?[^|;&]*-d[[:space:]]+${esc_archive}" \
     && printf '%s' "$CMD" | grep -qE 'nextflow|nf-core|docker[[:space:]]+run'; then
    deny "$BIOINFO_ARCHIVE_DISTRO is a read-only archive of the old environment. Run pipelines
      in the distro named by BIOINFO_DISTRO instead."
  fi
fi

# ---------------------------------------------------------------- 3. collapsed-path rm
# An unset variable turns 'rm -rf $WORK/x' into 'rm -rf /x'. Catch the shapes that reach the root.
# RECURSIVE matches both flag spellings: -r/-R in any short cluster, and --recursive.
RECURSIVE='\brm\b[^|;&]*[[:space:]](-[a-zA-Z]*[rR]|--recursive)'
if printf '%s' "$CMD" | grep -qE "$RECURSIVE"; then
  # The /<one-word> shape is the one this file's header has always advertised and the one the
  # deny text below names, but the pattern only ever covered "/", "/*" and "". `rm -rf /runs`
  # -- literally what `rm -rf $BIOINFO_RUNS` becomes when the variable is empty -- sailed
  # through. A single top-level component is now matched too, with or without a trailing slash
  # or glob, and quoted or not. Deeper paths are NOT matched here: `/work/nxf/<runid>/work` is
  # section 5's business, and the runbook section 9 reclaim must keep working.
  if printf '%s' "$CMD" | grep -qE '\brm\b[^|;&]*[[:space:]]["'"'"']?(/|/\*|""|/[A-Za-z0-9_.-]+/?\*?)["'"'"']?([[:space:]]|$)'; then
    deny "rm target is the filesystem root, a single top-level directory, or an empty string.
      This is what an unset \$BIOINFO_WORK / \$BIOINFO_RUNS / \$BIOINFO_REFS looks like — the path
      collapses to /, /work, /runs or /refs. Check the variable is set before retrying; if you
      really meant a top-level directory, do it outside this agent."
  fi
fi

# ---------------------------------------------------------------- 4. nextflow clean
if printf '%s' "$CMD" | grep -qE '\bnextflow\b[^|;&]*\bclean\b'; then
  if pgrep -f 'nextflow.*run ' >/dev/null 2>&1; then
    deny "a nextflow run is live; 'nextflow clean' can remove the cache it is resuming from.
      Wait for the run to finish."
  fi
  deny "'nextflow clean' is only correct via the references/runbook.md section 9 checklist:
      the run is finished, results are synced out, the user signed off, and the ${HOLD_DAYS}-day hold
      has elapsed. Confirm all four with the user, then run it outside this agent."
fi

# ---------------------------------------------------------------- 5. rm under the work root
# Only fires when a target genuinely sits under the work root; unrelated rm is none of our business.
printf '%s' "$CMD" | grep -qE "$RECURSIVE" || allow

esc() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'; }
esc_root="$(esc "$WORK_ROOT")"
esc_nxf="$(esc "$NXF_ROOT")"
# Roots worth scanning for. The bare literals stay in the alternation because hooks.json starts
# this on the Windows side, where neither BIOINFO_WORK nor NXF_WORKROOT is usually inherited and
# the defaults are all this has to go on. Duplicates in the alternation are harmless.
ROOT_ALT="${esc_nxf}|${esc_root}|/work/nxf|/work"
# The run-id-bearing roots only — /work on its own has no run id under it.
NXF_ALT="${esc_nxf}|/work/nxf"

# UNEXPANDED VARIABLE IN THE TARGET.
# This hook sees the command TEXT, before the caller's shell expands anything. So
# `rm -rf "$NXFDIR/work"` arrives literally, and the extraction below pulls `/work` out of it
# and would report "that is the entire work root" — blocking the one cleanup section 9
# actually documents. The opposite shape, `cd $NXFDIR && rm -rf work`, hides the target
# completely and would sail through.
#
# Neither answer is available to us: without the value there is no run id, so the finished /
# handed-off / past-the-hold conditions cannot be checked at all. Say that, rather than guess
# in either direction, and name the form that can be checked.
if printf '%s' "$CMD" | grep -qE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/(nxf|work)'; then
  deny "the target is an unexpanded variable, so this hook cannot tell which run it is —
      and therefore cannot confirm the run has finished, been handed off, and passed the
      ${HOLD_DAYS}-day hold. Re-issue it with the resolved path, e.g.
        rm -rf ${WORK_ROOT}/nxf/<runid>/work
      which is checkable. (references/runbook.md section 9 shows that form.)"
fi

# SPLIT INTO TOKENS, THEN ANCHOR. The old form searched for the root as a raw substring
# anywhere in the command, so every one of these was read as the bare work root and denied
# with "that target is the entire work root (/work)" -- a directory the caller never named:
#
#   rm -rf /mnt/e/workspace/tmp          "/work" as a prefix of another component
#   rm -rf /mnt/d/workflow_old           same
#   rm -rf /home/u/projects/network/work "/work" as the last component of an unrelated tree
#
# In all three the "(/...)*" tail matched zero times and $t collapsed to exactly "/work".
# A path argument is a whitespace-delimited token, so split on whitespace, drop the quotes,
# and require the root to match from the START of a token to a component boundary. Anchoring
# a single regex at both ends instead would break on two targets in one command, because the
# whitespace that ends the first is the same character that begins the second and grep -o
# does not return overlapping matches.
targets="$(printf '%s' "$CMD" \
  | tr -s '[:space:]' '\n' \
  | sed -E "s/^[\"']+//; s/[\"']+\$//" \
  | grep -E "^(${ROOT_ALT})(/.*)?\$" || true)"
[ -n "$targets" ] || allow

while IFS= read -r t; do
  [ -n "$t" ] || continue
  t="${t%/}"                                   # `rm -rf /work/` is still the work root
  [ -n "$t" ] || continue

  # Refuse to wipe the whole work root regardless of run state.
  if [ "$t" = "$WORK_ROOT" ] || [ "$t" = "/work" ] || [ "$t" = "$NXF_ROOT" ] || [ "$t" = "/work/nxf" ]; then
    deny "that target is the entire work root ($t), not one run. Every run's -resume cache lives
      under it. Delete a single finished run directory instead."
  fi

  # runid is the component directly under the run root
  runid="$(printf '%s' "$t" | sed -nE "s#^(${NXF_ALT})/([^/]+).*#\2#p")"
  [ -n "$runid" ] || continue

  rundir="$(printf '%s' "$t" | sed -nE "s#^((${NXF_ALT})/[^/]+).*#\1#p")"

  # Condition 1 — the run must not be live.
  # TWO independent checks, because either alone has a hole. The pid file is only written if
  # the launcher happened to write one — a foreground or tmux launch has no `$!` to record —
  # and a missing file silently means "not live", which would let this fall through to the
  # hold check and delete a running run's work directory. The process scan covers that, and
  # the pid file covers the case where the scan cannot see the process (a different mount
  # namespace, or a `nextflow` invocation whose command line does not carry the run id).
  if [ -f "$rundir/nextflow.pid" ]; then
    pid="$(cat "$rundir/nextflow.pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      deny "run $runid is still running (pid $pid). Deleting its work directory now loses the run."
    fi
  fi
  # Delimited with the path separators that surround the run id on a real command line
  # (-work-dir /work/nxf/<runid>/work). A bare "nextflow.*$runid" also matches a DIFFERENT
  # run whose id merely starts with this one — 20260804-study vs 20260804-study-rerun — which
  # here would block a legitimate reclaim, and in the runbook's stop recipe killed the wrong
  # run outright. runid comes from a path component, so it needs escaping for the regex.
  # `\\&`, not `\&`. In a sed replacement `&` is the whole match and `\&` escapes it into a
  # LITERAL ampersand — so the old form turned study.v2 into study&v2, a pattern that matches
  # nothing, and the guard then saw a live run as finished. `\\` emits one backslash, `&` the
  # matched character: study.v2 -> study\.v2.
  esc_runid="$(printf '%s' "$runid" | sed 's/[][\.*^$+?()|{}]/\\&/g')"
  if command -v pgrep >/dev/null 2>&1 && pgrep -f "nextflow.*/${esc_runid}/" >/dev/null 2>&1; then
    deny "a nextflow process for run $runid is still running. Deleting its work directory now
      loses the run. If that process is stale, stop it first."
  fi

  # Conditions 2-4 — handed off, and past the hold. The handoff note is the record that the run
  # finished, the results were read, and the user was told. No handoff means no sign-off.
  handoff=""
  for cand in \
    "${BIOINFO_RUNLOG:-}/$runid/handoff.md" \
    "${BIOINFO_HOME:-/mnt/d/bioinfo-agent}/runs/$runid/handoff.md" \
    "$rundir/handoff.md"
  do
    [ -n "$cand" ] && [ -f "$cand" ] && { handoff="$cand"; break; }
  done

  if [ -z "$handoff" ]; then
    # "Not found" and "not visible from here" are different facts and the caller has to be able
    # to tell them apart. hooks.json starts this hook on the WINDOWS side, so when the agent
    # reaches the distro through `wsl -d <distro> -- bash -lc '...'` none of the three candidate
    # paths can resolve: BIOINFO_RUNLOG and BIOINFO_HOME are not exported there, and /mnt/d and
    # /work are inside the distro. That is the normal case for an agent-issued reclaim, and the
    # old wording ("write it, get sign-off") sent the reader off to write a file that already
    # existed. Say which paths were tried.
    deny "cannot confirm a handoff for run $runid — no handoff.md at any of:
        ${BIOINFO_RUNLOG:-<BIOINFO_RUNLOG unset>}/$runid/handoff.md
        ${BIOINFO_HOME:-/mnt/d/bioinfo-agent}/runs/$runid/handoff.md
        $rundir/handoff.md
      If the run was never handed off: write it and get sign-off first (runbook.md section 9).
      If it was, this hook simply cannot see those paths from where it runs — it starts on the
      Windows side, so a run record inside the distro is invisible to it. Do the reclaim from a
      shell in the distro rather than through this agent."
  fi

  if [ -n "$(find "$handoff" -mtime "-${HOLD_DAYS}" 2>/dev/null)" ]; then
    deny "run $runid was handed off less than ${HOLD_DAYS} days ago. The hold exists because
      follow-up questions arrive after the handoff and answering them needs -resume."
  fi
done <<EOF
$targets
EOF

allow
