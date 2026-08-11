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
# It also cannot protect a root it has no way to learn. This hook runs on the WINDOWS side, and
# a value that exists only inside the distro -- exported in a login shell, never written to a
# host.env this process can reach -- is invisible to it. The two recoveries below cover the
# documented setups: the roots are read from the environment, or from config/host.env wherever
# that file actually is, and any path shaped like <root>/nxf/<runid> is recognised without
# knowing the root at all. What survives all three is a root that is BOTH unreachable AND not
# laid out as .../nxf/<runid> -- there, `rm -rf <that root>` looks like any other directory and
# is allowed. If your host is in that position, put BIOINFO_WORK and NXF_WORKROOT in the env
# block of .claude/settings.json so this process inherits them; that is the one route that
# always works, because it does not depend on this script guessing where anything lives.
#
# FAIL-OPEN, DELIBERATELY. This hook runs on every Bash call in any session where the plugin is
# installed. If it cannot parse its input it exits 0 and lets the normal permission flow decide.
# A guard that blocks everything when jq is missing is worse than no guard.
#
# Protocol: stdin is the PreToolUse JSON; exit 2 with a reason on stderr blocks the call.
#
# TESTS: hooks/guard-workdir.test.sh. Run it after every edit to this file — `bash
# hooks/guard-workdir.test.sh`: allow/deny cases only, no network, nothing outside a temp dir.
# (A hard-coded case count used to live here and went stale by ~47 cases; the suite reports
# its own totals when it runs.)
# Every case in it is a hole this hook actually had.

set -uo pipefail

# Host settings sometimes carry a trailing slash, and the derivation below can introduce an
# inner one (BIOINFO_WORK=/ makes "//nxf"). Commands do not preserve either, so a raw value
# goes into the regex and the equality tests and matches nothing: with NXF_WORKROOT=/scratch/nxf/
# a plain `rm -rf /scratch/nxf/run/work` exited 0 and deleted a live run unchecked. Collapse
# repeats and trim the tail, keeping `/` itself.
#
# Pure shell, no fork. Everything in the startup path of this file is written that way: it runs
# once per Bash call in the session, and on Git Bash a process spawn costs tens of milliseconds.
NORM=""
norm_root() {         # result in $NORM rather than stdout: a command substitution is a fork
  local v="$1"
  while case "$v" in *//*) true ;; *) false ;; esac; do v="${v//\/\//\/}"; done
  while [ "$v" != "/" ] && [ "${v%/}" != "$v" ]; do v="${v%/}"; done
  NORM="$v"
}
# READ THE CONFIGURED ROOTS OFF DISK WHEN THE ENVIRONMENT DOES NOT CARRY THEM.
# hooks.json starts this script on the WINDOWS side. The distro's ~/.config/bioinfo/env.sh has
# never been sourced there, so on a host whose roots are configured only inside WSL both
# BIOINFO_WORK and NXF_WORKROOT are unset here and the defaults below take over. That is not a
# cosmetic gap: with the real root at /scratch/nxf,
#   wsl -d Ubuntu-24.04 -- bash -lc 'rm -rf /scratch/nxf/demo/work'
# carries a fully resolved path -- the exact form the deny below tells callers to use -- and the
# hook, matching against /work/nxf, found no target and exited 0 on a live run.
# config/host.env is the per-machine record, is plain KEY=VALUE, and sits on a path Windows can
# read. PARSE it, never source it: this file runs on every Bash call in the session and must not
# execute anything a config file happens to contain. (Caught in review of PR #18.)
#
# AND IT IS NOT NEXT TO THIS SCRIPT. host.env is gitignored (.gitignore, "config/host.env") --
# correctly, it is per-machine -- so on the advertised `claude plugin install` route
# CLAUDE_PLUGIN_ROOT points at a plugin cache that only ever contained host.env.example. The
# real file lives in the separately cloned setup repo. Looking only beside the script therefore
# missed it exactly when the plugin route was used, and with BIOINFO_WORK=/bigdisk/work set only
# there, `rm -rf /bigdisk/work` -- the entire configured run tree -- was allowed, since it
# matches neither the /work defaults nor the /nxf shape. So try the places it can actually be,
# nearest-known first. (Caught in review of PR #18.)
#
# LAZILY, from init_roots. Only section 5 needs any of this, and section 5 only runs for a
# recursive rm. Doing the discovery eagerly put it in front of EVERY Bash call in the session:
# measured on Git Bash, the hook went from 285 ms to 1111 ms per invocation, nearly all of it
# spent finding roots for commands that could never reach the check they are for.
HOSTENV=""; ROOTS_READY=0; WORK_ROOTS=""; NXF_ROOTS=""; WORK_ROOT=""; NXF_ROOT=""
find_hostenv() {
  local _selfdir _cand _alt _p
  _selfdir="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd || printf '')"
  for _cand in \
    "${BIOINFO_HOST_ENV:-}" \
    "${BIOINFO_HOME:-/mnt/d/bioinfo-agent}/config/host.env" \
    "${CLAUDE_PROJECT_DIR:-}/config/host.env" \
    "${CLAUDE_PLUGIN_ROOT:-}/config/host.env" \
    "${_selfdir:-}/config/host.env" \
    "${HOME:-}/bioinfo-agent/config/host.env"
  do
    case "$_cand" in ''|/config/host.env) continue ;; esac   # the variable was empty
    # A Windows-side shell sees D: as /d, not /mnt/d; host.env.example writes the WSL form.
    case "$_cand" in /mnt/?/*) _alt="/${_cand#/mnt/}" ;; *) _alt="" ;; esac
    for _p in "$_cand" "$_alt"; do
      [ -n "$_p" ] && [ -r "$_p" ] && { HOSTENV="$_p"; return 0; }
    done
  done
}
# SAME ACCEPTANCE AS bootstrap/lib/host-env.sh, which is the canonical reader for this file.
# It strips an optional `export ` prefix and whitespace around the key, and takes the value
# literally: quoted to the matching quote, otherwise up to the first space or '#'. A one-line
# sed that only understood `KEY=value` therefore missed `export BIOINFO_WORK=/bigdisk/work` --
# a form host-env.sh explicitly accepts -- and fell back to /work, after which
# `rm -rf /bigdisk/work` deleted the whole custom work tree with no run-state check. Two
# readers of one file must not disagree about what the file says. (Caught in review of PR #18.)
hostenv_get() {
  [ -n "$HOSTENV" ] && [ -r "$HOSTENV" ] || return 0
  local _want="$1" _line _key _v _out=""
  # load_host_env applies the last ACCEPTED assignment, not simply the last matching line.
  # Keep the same value parser and reject list so a later invalid line cannot hide a valid root.
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line="${_line%$'\r'}"
    case "$_line" in
      ''|'#'*) continue ;;
      *'='*)   ;;
      *)       continue ;;
    esac

    _key="${_line%%=*}"
    _v="${_line#*=}"
    _key="${_key#"${_key%%[![:space:]]*}"}"
    _key="${_key%"${_key##*[![:space:]]}"}"
    _key="${_key#export }"
    _key="${_key#"${_key%%[![:space:]]*}"}"
    [ "$_key" = "$_want" ] || continue

    _v="${_v#"${_v%%[![:space:]]*}"}"
    case "$_v" in
      '"'*) _v="${_v#\"}"; _v="${_v%%\"*}" ;;
      "'"*) _v="${_v#\'}"; _v="${_v%%\'*}" ;;
      *)    _v="${_v%%#*}"
            _v="${_v%"${_v##*[![:space:]]}"}"
            case "$_v" in *[[:space:]]*) _v="${_v%%[[:space:]]*}" ;; esac ;;
    esac
    case "$_v" in *'$('*|*'`'*|*';'*|*'|'*|*'&'*|*'>'*|*'<'*|*$'\n'*) continue ;; esac
    _out="$_v"
  done < "$HOSTENV"
  printf '%s' "$_out"
}
# PROTECT EVERY ROOT EITHER SOURCE NAMES, not whichever one wins a precedence fight.
# `${BIOINFO_WORK:=$(hostenv_get ...)}` meant an inherited value suppressed the file, and the
# two disagree in exactly the situation that matters: load_host_env exports unconditionally
# (host-env.sh line 80), so after a host move the FILE holds the live root while a shell that
# still has the old one exported hands this hook the dead one. It then guarded /old/work while
# runs filled /bigdisk/work, and `rm -rf /bigdisk/work` exited 0. (Caught in review of PR #18.)
#
# Picking a winner is the wrong shape for a guard. Deleting a root that is no longer in use is
# harmless to refuse; failing to guard one that is in use is the whole failure mode. So collect
# both readings plus the built-in default and protect the union. WORK_ROOT / NXF_ROOT stay as
# the single values quoted in messages.
NL='
'
_addroot() {          # $1 = WORK|NXF, $2 = raw value. Deduping append, no subshell.
  norm_root "$2"; [ -n "$NORM" ] || return 0
  local _roots _r
  if [ "$1" = WORK ]; then
    _roots="$WORK_ROOTS"
    while IFS= read -r _r; do [ "$_r" = "$NORM" ] && return 0; done <<EOF
$_roots
EOF
    WORK_ROOTS="$WORK_ROOTS$NORM$NL"
  else
    _roots="$NXF_ROOTS"
    while IFS= read -r _r; do [ "$_r" = "$NORM" ] && return 0; done <<EOF
$_roots
EOF
    NXF_ROOTS="$NXF_ROOTS$NORM$NL"
  fi
}
init_roots() {
  [ "$ROOTS_READY" -eq 1 ] && return 0
  ROOTS_READY=1
  local _w
  find_hostenv
  _addroot WORK "${BIOINFO_WORK:-/work}"
  _addroot WORK "$(hostenv_get BIOINFO_WORK)"
  _addroot WORK /work
  _addroot NXF  "${NXF_WORKROOT:-}"
  _addroot NXF  "$(hostenv_get NXF_WORKROOT)"
  # Run directories live one per run id under <root>/nxf. SAME DERIVATION as bin/preflight.sh,
  # every cmd.sh, and every NXFDIR= line in references/runbook.md — and it is the derivation
  # that applies whenever NXF_WORKROOT is not set at all, so it must hold for every work root.
  while IFS= read -r _w; do [ -n "$_w" ] && _addroot NXF "$_w/nxf"; done <<EOF
$WORK_ROOTS
EOF
  norm_root "${BIOINFO_WORK:-/work}";              WORK_ROOT="$NORM"
  norm_root "${NXF_WORKROOT:-${WORK_ROOT}/nxf}";   NXF_ROOT="$NORM"
}
HOLD_DAYS="${BIOINFO_WORKDIR_HOLD_DAYS:-7}"

# true when $1 is exactly one of the roots, i.e. a whole-tree wipe rather than one run
is_root() {
  local _t="$1" _r
  while IFS= read -r _r; do [ -n "$_r" ] && [ "$_t" = "$_r" ] && return 0; done <<EOF
$WORK_ROOTS
$NXF_ROOTS
EOF
  return 1
}

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
  #
  # \n BECOMES A NEWLINE, not a space. A newline is a command separator; a space is not, and
  # collapsing one into the other merged two commands into one segment, after which the reader
  # exemption judged the pair by the FIRST verb:
  #     {"command":"echo a\nrm -rf /work"}   ->   echo a rm -rf /work   ->   verb echo -> allowed
  # The rm was never scanned. Only on this branch: with jq the newline survives and the same
  # input denies, so the bypass existed exactly on the Windows side, which is the side
  # hooks.json actually starts this script on. \t stays a space -- a tab separates words, not
  # commands. (Found while fixing the round-10 continuation finding.)
  CMD="${CMD//\\\"/\"}"; CMD="${CMD//\\n/$NL}"; CMD="${CMD//\\t/ }"; CMD="${CMD//\\\\/\\}"
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
#
# ESCAPED SEPARATORS ARE NOT SEPARATORS. `;` `|` `&` are legal in a directory name, so a
# configured root may contain one -- BIOINFO_WORK=/big&disk/work -- and bash spells the target
# `rm -rf /big\&disk/work/nxf/demo/work`. Splitting on every & regardless of the backslash tore
# the path in half before any matcher saw it, no token held the whole root, and the hook exited
# 0. Park the escaped ones out of tr's reach and put them back afterwards as the bare character
# the shell would have produced. (Caught in review of PR #18.)
#
# PARITY, and it has to be counted rather than peeked at. `${CMD//\\;/…}` hid a separator
# whenever a backslash sat in front of it, which is wrong exactly when the backslash is itself
# escaped: bash reads `echo x\\; rm -rf /work` as TWO commands (verified -- it prints `x\` and
# then runs the second), but hiding that `;` left one echo-led segment, the reader exemption
# dropped it, and the rm sailed through. That was a bypass this PR introduced in the previous
# round, not a pre-existing one: the same input denied at 7707948.
#
# Consuming `\X` as a PAIR gets parity for free. In `x\\;` the two backslashes are eaten
# together, so the `;` after them is met bare and stays a separator. In `x\;` the pair is
# backslash-semicolon and the separator is hidden. No counter needed.
#
# The same pass joins a backslash-newline, because bash removes both characters and welds the
# word: `rm -rf /big\<newline>disk/work` is /bigdisk/work to bash, while every awk below reads
# one line at a time and could only ever see two unrelated fragments.
_E1="$(printf '\002')"; _E2="$(printf '\003')"; _E3="$(printf '\004')"
PREPASS=""
shell_prepass() {     # pure shell; gated below so a command with no backslash never pays for it
  # two statements: `local` expands all its arguments before assigning any, so ${#s} in the
  # same line reads the caller's (unset) s and trips set -u
  local s="$1" out="" i=0 c nx n q=""
  n=${#s}
  while [ "$i" -lt "$n" ]; do
    c="${s:i:1}"
    # A backslash escapes anything outside quotes, is literal inside '', and inside "" escapes
    # only $ ` " \ and newline -- before anything else bash keeps it as a literal character.
    # Treating it as a general escape there rewrote a root that genuinely contains a backslash:
    # "/foo/a\&b/work" is /foo/a\&b/work to bash, and dropping the backslash left nothing to
    # match. (Caught in review of PR #18.)
    if [ "$c" = '\' ] && [ "$q" != "'" ] && [ $((i+1)) -lt "$n" ]; then
      nx="${s:i+1:1}"
      if [ "$q" = '"' ]; then
        case "$nx" in
          '$'|'`'|'"'|'\'|"$NL") ;;                    # genuinely an escape here
          *) out="$out$c"; i=$((i+1)); continue ;;     # literal; let nx be handled on its own
        esac
      fi
      case "$nx" in
        ';')   out="$out$_E1" ;;
        '|')   out="$out$_E2" ;;
        '&')   out="$out$_E3" ;;
        "$NL") : ;;                    # line continuation: bash drops both and joins the word
        *)     out="$out\\$nx" ;;      # leave it; the tokenizer strips the backslash later
      esac
      i=$((i+2)); continue
    fi
    # QUOTES PARK SEPARATORS TOO, and this is the commoner spelling. Escaping was handled first
    # and quoting was not, so `rm -rf "/foo/big&disk/work"` still had its & fed to the tr below
    # and neither fragment matched the root -- while bash treats the quoted & as part of the
    # pathname and deletes it. Writing a path with a special character in quotes is what a
    # person actually does; the backslash form is the rarer one. (Caught in review of PR #18.)
    if [ -z "$q" ]; then
      # $'…' and $"…" are quote introducers, not expansions. bash resolves $'/work' to /work,
      # and leaving the $ attached made the token read $'/work' -> $/work, matching no root.
      # Only when a quote follows immediately: $NXFDIR is a variable and must stay one.
      if [ "$c" = '$' ] && [ $((i+1)) -lt "$n" ]; then
        case "${s:i+1:1}" in '"'|"'") i=$((i+1)); continue ;; esac
      fi
      case "$c" in '"'|"'") q="$c"; out="$out$c"; i=$((i+1)); continue ;; esac
    elif [ "$c" = "$q" ]; then
      q=""; out="$out$c"; i=$((i+1)); continue
    else
      case "$c" in
        ';') out="$out$_E1"; i=$((i+1)); continue ;;
        '|') out="$out$_E2"; i=$((i+1)); continue ;;
        '&') out="$out$_E3"; i=$((i+1)); continue ;;
      esac
    fi
    out="$out$c"; i=$((i+1))
  done
  PREPASS="$out"
}
# Run it for a backslash, or for a quote that shares the command with a separator. Anything
# else cannot need it, and this walk is pure shell on every recursive rm.
_pp=0
case "$CMD" in
  *\\*) _pp=1 ;;
  *[\"\']*) case "$CMD" in *[\;\|\&]*) _pp=1 ;; esac ;;
esac
[ "$_pp" -eq 1 ] && { shell_prepass "$CMD"; CMD="$PREPASS"; }
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
# `\&`, not `&`. In a ${var//pat/repl} replacement bash reads a bare & as the matched text, so
# `${CMD//$_E3/&}` put the placeholder straight back and the restore was a silent no-op -- which
# is exactly why the ; and | cases worked and the & one did not. A variable holding & is
# reinterpreted the same way; only the backslash escapes it. Verified on bash 5.3.15.
CMD="${CMD//$_E1/;}"; CMD="${CMD//$_E2/|}"; CMD="${CMD//$_E3/\&}"

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

# Past this line the command really is a recursive rm, so it is worth learning where the work
# roots are. Everything above answered without needing to know.
init_roots

esc() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'; }
# alternation over every root either source named, longest first so the run-bearing
# <root>/nxf wins over its own <root> prefix
alt_of() { local _r _o=""; while IFS= read -r _r; do
    [ -n "$_r" ] && _o="$_o|$(esc "$_r")"
  done; printf '%s' "${_o#|}"; }
# Roots worth scanning for: every value the environment or host.env named, plus the built-in
# default, which WORK_ROOTS already carries. Duplicates are impossible (sort -u) and harmless.
ROOT_ALT="$(printf '%s\n%s\n' "$NXF_ROOTS" "$WORK_ROOTS" | alt_of)"
# The run-id-bearing roots only — a bare work root has no run id directly under it.
NXF_ALT="$(printf '%s\n' "$NXF_ROOTS" | alt_of)"

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
#
# TWO patterns, because one is not enough. The original only looked for a variable followed
# IMMEDIATELY by /nxf or /work, which misses the shape a custom root produces:
# `rm -rf "$NXF_WORKROOT/demo/work"` puts `demo` in between, so nothing matched, and since the
# literal-root extraction below cannot see through the variable either, the command was
# allowed straight through to the shell — deleting a live run's work directory with no pid,
# handoff or hold check. (Caught in review of PR #18; the pre-PR code denied it only by
# accident, via the substring bug this PR removed.)
#   A — a variable anywhere in a token that also carries an /nxf or /work component.
#   B — a variable this repo uses to name a work or run DATA root, whatever follows it.
# Both are deliberately narrow at the boundary: `$USER/workspace` matches neither, because
# /work must end at a path separator. B is an explicit list rather than a name heuristic on
# purpose -- $WORKDIR and $TMPD are scratch directories in this repo's own bootstrap scripts,
# and a "contains the word work" rule would deny them for no reason.
UNEXPANDED_A='\$\{?[A-Za-z_][A-Za-z0-9_]*\}?[^[:space:]"'"'"';|&]*/(nxf|work)([/[:space:]"'"'"';|&]|$)'
UNEXPANDED_B='\$\{?(NXF_WORKROOT|NXFDIR|NXF_WORK|BIOINFO_WORK|BIOINFO_RUNS)\}?([^A-Za-z0-9_]|$)'
if printf '%s' "$CMD" | grep -qE "$UNEXPANDED_A" || printf '%s' "$CMD" | grep -qE "$UNEXPANDED_B"; then
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
#
# PLUS A ROOT-AGNOSTIC SHAPE. Reading config/host.env above recovers the configured root for the
# documented setup, but runbook.md section 2 also tells the operator to `export NXF_WORKROOT`,
# and an export that never reaches host.env is invisible to a hook running on the Windows side.
# So do not rely on knowing the root at all: `<anything>/nxf/<runid>` IS the run-tree layout this
# repo builds everywhere -- bin/preflight.sh, every cmd.sh, every NXFDIR= line. Matching the
# shape catches /scratch/nxf/demo/work on a host this process cannot introspect. A directory
# that genuinely is somebody's unrelated ".../nxf/<name>" gets the run-state questions asked
# about it, which is the right way to be wrong for a guard whose job is the destructive case.
#
# AND WHITESPACE INSIDE A WORD IS NOT A BOUNDARY. A configured root may contain a space -- the
# host-env loader supports a quoted value precisely so it can -- and bash writes such a target as
#   rm -rf /big\ disk/work/nxf/demo/work        or   rm -rf "/big disk/work/nxf/demo/work"
# Splitting blindly on whitespace produced `/big\` and `disk/work/nxf/demo/work`, neither of
# which matches anything, so the hook exited 0 while bash reassembled the real path and deleted
# it. Walk the string once: swallow the quoting the way a shell would, and hold a space that
# belongs to a word as \001 until after the split. (Caught in review of PR #18.)
#
# TWO TOKENISATIONS, UNIONED, because one cannot serve both shapes. Quoting means "this is one
# word" for a path with a space, and "this is an inner command" for the form the agent actually
# uses to reach the distro:
#   wsl -d Ubuntu-24.04 -- bash -lc 'rm -rf /scratch/nxf/demo/work'
# Treating that quoted run as a single word hides the path inside it; splitting the quoted path
# on its space destroys it. Nothing in the command text says which one a given quote is. So
# produce both streams and match against the union: this decides one bit, and an extra candidate
# token can only make the guard stricter, which is the safe direction for a delete.
#
#   stream 1  quotes dropped, BACKSLASH-escaped whitespace held as part of the word.
#             Covers the inner-command form, and the composition of the two that a first
#             attempt at this missed entirely:
#               wsl -d Ubuntu -- bash -lc 'rm -rf /big\ disk/work/nxf/demo/work'
#             where the quote is a command wrapper but the space inside it belongs to the path.
#   stream 2  quoted spans held as one word. Covers "/big disk/work/nxf/demo/work".
#
# Both streams also drop the $ of a $'…' / $"…" word, which bash resolves away entirely.
#
# What neither covers is a quote nested inside a quote -- bash -lc '... "/big disk/..." ...' --
# nor the escape DECODING inside $'…', where bash turns \x2f and \t into real characters. Doing
# either properly means being a shell, which this is not; see WHAT IT DOES NOT DO.
SEP="$(printf '\001')"
# The prefix is OPTIONAL. `^/.*/nxf` demanded a nonempty component before /nxf, so a top-level
# root -- NXF_WORKROOT=/nxf, perfectly valid and, being inside the distro, invisible to a
# Windows-side hook -- matched nothing and `rm -rf /nxf/demo/work` exited 0 on a live run.
# (Caught in review of PR #18.)
NXF_SHAPE='^(/.*)?/nxf(/[^/]+.*)?$'
targets="$( { printf '%s' "$CMD" \
  | awk -v S="$SEP" '{
      out=""; n=length($0)
      for (i=1; i<=n; i++) {
        c = substr($0,i,1)
        if (c=="\\" && i<n) {
          nx = substr($0,i+1,1)
          if (nx==" " || nx=="\t") { out = out S; i++; continue }
          # DROP THE BACKSLASH. A shell does; keeping it meant the token read /ref\?/work
          # while bash deleted /ref?/work, so a root with any escaped character in its name
          # matched nothing. Whitespace is the one escape that becomes SEP instead, because
          # there the backslash is carrying word-joining, not just quoting the character.
          out = out nx; i++; continue
        }
        # $ immediately before a quote introduces $'…' / $"…"; drop it, keep $VAR intact
        if (c=="$" && i<n) { nq = substr($0,i+1,1); if (nq=="\"" || nq=="\047") continue }
        if (c=="\"" || c=="\047") continue
        out = out c
      }
      print out
    }' | tr -s '[:space:]' '\n' | sed "s/${SEP}/ /g"
              printf '%s' "$CMD" \
  | awk -v S="$SEP" '{
      out=""; q=""; n=length($0)
      for (i=1; i<=n; i++) {
        c = substr($0,i,1)
        if (q=="" && c=="\\" && i<n) {
          nx = substr($0,i+1,1)
          if (nx==" " || nx=="\t") { out = out S; i++; continue }
          out = out nx; i++; continue          # same as stream 1: the shell drops it
        }
        if (q=="" && c=="$" && i<n) { nq = substr($0,i+1,1); if (nq=="\"" || nq=="\047") continue }
        if (q=="") { if (c=="\"" || c=="\047") { q=c; continue } }
        else {
          if (c==q) { q=""; continue }
          if (c==" " || c=="\t") { out = out S; continue }
        }
        out = out c
      }
      print out
    }' | tr -s '[:space:]' '\n' | sed "s/${SEP}/ /g"
            } | grep -E "^(${ROOT_ALT})(/.*)?\$|${NXF_SHAPE}" | sort -u || true)"
[ -n "$targets" ] || allow

while IFS= read -r t; do
  [ -n "$t" ] || continue
  # SAME NORMALIZATION THE ROOTS GOT. `${t%/}` strips one trailing slash, so `rm -rf /work//`
  # left `/work/`, matched no root, produced no run id, and fell out of the loop at exit 0 --
  # while rm treats it as /work and takes the whole tree with every resume cache in it. Roots
  # were normalized from the start and targets were not; that asymmetry was the bug.
  # (Caught in review of PR #18.)
  norm_root "$t"; t="$NORM"
  [ -n "$t" ] || continue

  # Refuse to wipe the whole work root regardless of run state. The */nxf case covers a root
  # this process could not learn: it is still somebody's run tree, whoever configured it.
  if is_root "$t" || case "$t" in */nxf) true ;; *) false ;; esac; then
    deny "that target is the entire work root ($t), not one run. Every run's -resume cache lives
      under it. Delete a single finished run directory instead."
  fi

  # runid is the component directly under the run root. Try the roots this process knows first,
  # then fall back to the layout itself so a root configured out of reach still resolves.
  runid="$(printf '%s' "$t" | sed -nE "s#^(${NXF_ALT})/([^/]+).*#\2#p")"
  rundir="$(printf '%s' "$t" | sed -nE "s#^((${NXF_ALT})/[^/]+).*#\1#p")"
  if [ -z "$runid" ]; then
    # same optional prefix as NXF_SHAPE: a run under the top-level root /nxf has none
    runid="$(printf '%s' "$t" | sed -nE 's#^(.*)/nxf/([^/]+).*#\2#p')"
    rundir="$(printf '%s' "$t" | sed -nE 's#^((.*)/nxf/[^/]+).*#\1#p')"
  fi
  [ -n "$runid" ] || continue

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
  #
  # AND THE MATCH MUST BE A JVM. The Nextflow head process is always java; nothing else that
  # matches this pattern is. Two other things do match, and one of them never goes away:
  # references/runbook.md section 5 launches every run with
  #   tmux new-session -d -s <name> -e NXF_HOME=…/.nextflow … "bash '<rundir>/cmd.sh'"
  # and that argv becomes the tmux SERVER's own command line for the life of the server -- it
  # holds "nextflow" (from the forwarded NXF_HOME) and "/<runid>/" (from the cmd.sh path), so
  # this pattern hits it. The server outlives the run, and a LATER run's session keeps it alive
  # while its argv still names the FIRST run, so without this filter run 1's work directory is
  # reported live and refused for reclaim indefinitely -- the documented section 9 reclaim simply
  # stops working. Measured 2026-08-07 on 20260807-rnaseq-scer-gln3-ibutanol: pgrep returned
  # 131512 `tmux: server`, 131517 `java` (the run), 131789 `bash` (the launching shell).
  # Same filter, same reason, as the pid-recording loop in runbook section 5.
  #
  # /proc only. On a host without it the filter cannot run, and the honest fallback is the old
  # unfiltered behaviour: over-blocking a reclaim is the safe direction for a delete guard.
  esc_runid="$(printf '%s' "$runid" | sed 's/[][\.*^$+?()|{}]/\\&/g')"
  if command -v pgrep >/dev/null 2>&1; then
    live=0
    while IFS= read -r scanpid; do
      [ -n "$scanpid" ] || continue
      if [ -r "/proc/$scanpid/comm" ]; then
        [ "$(cat "/proc/$scanpid/comm" 2>/dev/null)" = java ] && { live=1; break; }
      else
        live=1; break                       # no /proc to check with — assume live
      fi
    done <<EOF
$(pgrep -f "nextflow.*/${esc_runid}/" 2>/dev/null)
EOF
    if [ "$live" -eq 1 ]; then
      deny "a nextflow process for run $runid is still running. Deleting its work directory now
      loses the run. If that process is stale, stop it first."
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
