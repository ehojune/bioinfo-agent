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
#   nextflow clean                   while any nextflow run is live.
#   rm -r/-rf under the work root    unless the run is finished, handed off, and past the hold.
#   rm -rf on a collapsed path       e.g. an unset variable turning a path into / or /<one-word>.
#   a pipeline launched in the archive distro (Ubuntu-legacy), which is read-only by policy.
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
CMD_SCAN="$(
  printf '%s\n' "$CMD" | tr ';|&' '\n\n\n' | while IFS= read -r _seg || [ -n "$_seg" ]; do
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
if printf '%s' "$CMD" | grep -qE 'wsl(\.exe)?[^|;&]*-d[[:space:]]+Ubuntu-legacy' \
   && printf '%s' "$CMD" | grep -qE 'nextflow|nf-core|docker[[:space:]]+run'; then
  deny "Ubuntu-legacy is a read-only archive of the old environment. Pipelines run in Ubuntu-24.04."
fi

# ---------------------------------------------------------------- 3. collapsed-path rm
# An unset variable turns 'rm -rf $WORK/x' into 'rm -rf /x'. Catch the shapes that reach the root.
# RECURSIVE matches both flag spellings: -r/-R in any short cluster, and --recursive.
RECURSIVE='\brm\b[^|;&]*[[:space:]](-[a-zA-Z]*[rR]|--recursive)'
if printf '%s' "$CMD" | grep -qE "$RECURSIVE"; then
  if printf '%s' "$CMD" | grep -qE '\brm\b[^|;&]*[[:space:]](/|/\*|"")([[:space:]]|$)'; then
    deny "rm target is the filesystem root, or an empty string. This is what an unset
      \$BIOINFO_WORK / \$BIOINFO_RUNS looks like. Check the variable is set before retrying."
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

esc_root="$(printf '%s' "$WORK_ROOT" | sed 's/[][\.*^$/]/\\&/g')"
targets="$(printf '%s' "$CMD" | grep -oE "(${esc_root}|/work)(/[^[:space:]\"';|&]*)*" || true)"
[ -n "$targets" ] || allow

while IFS= read -r t; do
  [ -n "$t" ] || continue

  # Refuse to wipe the whole work root regardless of run state.
  if [ "$t" = "$WORK_ROOT" ] || [ "$t" = "/work" ] || [ "$t" = "$WORK_ROOT/nxf" ] || [ "$t" = "/work/nxf" ]; then
    deny "that target is the entire work root ($t), not one run. Every run's -resume cache lives
      under it. Delete a single finished run directory instead."
  fi

  # runid is the component directly under <root>/nxf/
  runid="$(printf '%s' "$t" | sed -nE "s#^(${esc_root}|/work)/nxf/([^/]+).*#\2#p")"
  [ -n "$runid" ] || continue

  rundir="$(printf '%s' "$t" | sed -nE "s#^((${esc_root}|/work)/nxf/[^/]+).*#\1#p")"

  # Condition 1 — the run must not be live.
  if [ -f "$rundir/nextflow.pid" ]; then
    pid="$(cat "$rundir/nextflow.pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      deny "run $runid is still running (pid $pid). Deleting its work directory now loses the run."
    fi
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
    deny "no handoff.md found for run $runid. The handoff is the record that the run finished and
      the user saw the results. Write it, get sign-off, then reclaim (runbook.md section 9)."
  fi

  if [ -n "$(find "$handoff" -mtime "-${HOLD_DAYS}" 2>/dev/null)" ]; then
    deny "run $runid was handed off less than ${HOLD_DAYS} days ago. The hold exists because
      follow-up questions arrive after the handoff and answering them needs -resume."
  fi
done <<EOF
$targets
EOF

allow
