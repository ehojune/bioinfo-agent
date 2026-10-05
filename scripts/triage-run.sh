#!/usr/bin/env bash
# triage-run.sh -- read-only failure triage for an nf-core run directory.
#
#     triage-run.sh [--tail N] [--json] <run-dir>
#
# Reads Nextflow logs, the newest trace/report attempt, and failed task command files. It never
# writes to the run directory and never invokes Nextflow cleanup.
#
# If this dies with:  /usr/bin/env: 'bash\r': No such file or directory
# the file was checked out with CRLF from the NTFS side. Fix once:
#     sed -i 's/\r$//' triage-run.sh

set -euo pipefail

TAIL_LINES=20
JSON=0
RUN_DIR=""

usage() {
  printf 'usage: %s [--tail N] [--json] <run-dir>\n' "$0" >&2
}

while (($#)); do
  case "$1" in
    --tail)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { usage; exit 2; }
      TAIL_LINES="$2"
      shift 2
      ;;
    --json)
      JSON=1
      shift
      ;;
    --)
      shift
      [[ $# -eq 1 && -z "$RUN_DIR" ]] || { usage; exit 2; }
      RUN_DIR="$1"
      shift
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      [[ -z "$RUN_DIR" ]] || { usage; exit 2; }
      RUN_DIR="$1"
      shift
      ;;
  esac
done

[[ -n "$RUN_DIR" ]] || { usage; exit 2; }
[[ -d "$RUN_DIR" && -r "$RUN_DIR" && -x "$RUN_DIR" ]] || {
  printf 'triage-run: cannot read run directory: %s\n' "$RUN_DIR" >&2
  exit 1
}

RUN_ABS="$(cd "$RUN_DIR" 2>/dev/null && pwd -P)" || {
  printf 'triage-run: cannot read run directory: %s\n' "$RUN_DIR" >&2
  exit 1
}

shopt -s nullglob
NEXTFLOW_LOGS=()
STDOUT_LOGS=()
TRACES=()
REPORTS=()

add_artifact() {
  local kind="$1" path="$2"
  [[ -f "$path" && -r "$path" ]] || return 0
  case "$kind" in
    nextflow) NEXTFLOW_LOGS+=("$path") ;;
    stdout)   STDOUT_LOGS+=("$path") ;;
    trace)    TRACES+=("$path") ;;
    report)   REPORTS+=("$path") ;;
  esac
}

# The live layout keeps .nextflow.log at the run root and per-attempt trace/report files below
# reports/. A handed-off run may instead carry nextflow.log inside reports/. Search those bounded
# locations only; walking results/ or work/ would turn a small triage into a full run-tree scan.
for path in "$RUN_ABS"/.nextflow.log "$RUN_ABS"/.nextflow.log.*; do
  add_artifact nextflow "$path"
done
for path in "$RUN_ABS"/nextflow.stdout.log; do
  add_artifact stdout "$path"
done

scan_reports() {
  local dir="$1" path base
  [[ -d "$dir" && -r "$dir" && -x "$dir" ]] || return 0
  for path in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [[ -e "$path" || -L "$path" ]] || continue
    if [[ -d "$path" && ! -L "$path" ]]; then
      scan_reports "$path"
      continue
    fi
    base="${path##*/}"
    case "$base" in
      .nextflow.log|.nextflow.log.*|nextflow.log|nextflow.log.*)
        add_artifact nextflow "$path" ;;
      nextflow.stdout.log|nextflow.stdout.log.*)
        add_artifact stdout "$path" ;;
      trace*.txt)
        add_artifact trace "$path" ;;
      report*.html)
        add_artifact report "$path" ;;
    esac
  done
}
scan_reports "$RUN_ABS/reports"

# Accept flat trace/report files too. The documented layout is preferred above, but older
# nf-core commands may have written these directly into the launch directory.
for path in "$RUN_ABS"/trace*.txt; do add_artifact trace "$path"; done
for path in "$RUN_ABS"/report*.html; do add_artifact report "$path"; done

newest() {
  local best="" path
  for path in "$@"; do
    [[ -n "$best" && ! "$path" -nt "$best" ]] || best="$path"
  done
  printf '%s' "$best"
}

select_nextflow_log() {
  local current=() path base
  for path in "${NEXTFLOW_LOGS[@]}"; do
    base="${path##*/}"
    [[ "$base" == .nextflow.log || "$base" == nextflow.log ]] && current+=("$path")
  done
  if ((${#current[@]})); then
    newest "${current[@]}"
  elif ((${#NEXTFLOW_LOGS[@]})); then
    newest "${NEXTFLOW_LOGS[@]}"
  fi
}

SELECTED_LOG="$(select_nextflow_log)"
SELECTED_STDOUT="$(newest "${STDOUT_LOGS[@]}")"
SELECTED_TRACE="$(newest "${TRACES[@]}")"
SELECTED_REPORT="$(newest "${REPORTS[@]}")"

COUNT_CACHED=""
COUNT_COMPLETED=""
COUNT_FAILED=""
COUNT_ABORTED=""
COUNT_NON_CLEAN=""
if [[ -n "$SELECTED_TRACE" ]]; then
  counts="$(awk -F '\t' '
    NR == 1 {
      for (i=1; i<=NF; i++) {
        sub(/\r$/, "", $i)
        h[tolower($i)] = i
      }
      known = ("status" in h)
      next
    }
    known {
      s = toupper($(h["status"]))
      sub(/\r$/, "", s)
      if (s == "CACHED") cached++
      else if (s == "COMPLETED") completed++
      else if (s == "FAILED") failed++
      else if (s == "ABORTED") aborted++
      code = ("exit" in h) ? $(h["exit"]) : ""
      if (code == "" && "exit_status" in h) code = $(h["exit_status"])
      sub(/\r$/, "", code)
      if (s != "FAILED" && s != "ABORTED" && s != "RUNNING" &&
          code ~ /^-?[0-9]+$/ && code+0 != 0) non_clean++
    }
    END {
      if (known) printf "%d%c%d%c%d%c%d%c%d%c1", cached+0,31,completed+0,31,failed+0,31,aborted+0,31,non_clean+0,31
      else printf "%c%c%c%c%c0", 31,31,31,31,31
    }
  ' "$SELECTED_TRACE")"
  IFS=$'\037' read -r COUNT_CACHED COUNT_COMPLETED COUNT_FAILED COUNT_ABORTED COUNT_NON_CLEAN COUNTS_KNOWN <<< "$counts"
  if [[ "$COUNTS_KNOWN" != 1 ]]; then
    COUNT_CACHED=""; COUNT_COMPLETED=""; COUNT_FAILED=""; COUNT_ABORTED=""; COUNT_NON_CLEAN=""
  fi
fi

# A missing trace is normal early in a run. Recover final summary counts from stdout/log text when
# possible, while leaving genuinely unknown values empty rather than inventing zeros.
if [[ -z "$COUNT_CACHED" ]]; then
  summary_sources=()
  [[ -n "$SELECTED_LOG" ]] && summary_sources+=("$SELECTED_LOG")
  [[ -n "$SELECTED_STDOUT" ]] && summary_sources+=("$SELECTED_STDOUT")
  if ((${#summary_sources[@]})); then
    counts="$(awk '
      {
        line=$0
        while (match(line, /(Cached|Succeeded|Completed|Failed)[[:space:]]*:[[:space:]]*[0-9]+/)) {
          part=substr(line, RSTART, RLENGTH)
          key=part; sub(/[[:space:]]*:.*$/, "", key)
          value=part; sub(/^.*:[[:space:]]*/, "", value)
          if (key == "Cached") cached=value
          else if (key == "Succeeded" || key == "Completed") completed=value
          else if (key == "Failed") failed=value
          line=substr(line, RSTART+RLENGTH)
        }
      }
      END { printf "%s%c%s%c%s", cached, 31, completed, 31, failed }
    ' "${summary_sources[@]}")"
    IFS=$'\037' read -r COUNT_CACHED COUNT_COMPLETED COUNT_FAILED <<< "$counts"
  fi
fi

TASK_PROCESS=()
TASK_TAG=()
TASK_EXIT=()
TASK_WORKDIR=()
TASK_COMMAND=()

resolve_workdir() {
  local stated="$1" hash="$2" candidate=""
  if [[ -n "$stated" && "$stated" != "-" ]]; then
    if [[ "$stated" == /* ]]; then candidate="$stated"; else candidate="$RUN_ABS/$stated"; fi
    if [[ -d "$candidate" ]]; then
      (cd "$candidate" 2>/dev/null && pwd -P) || printf '%s' "$candidate"
    else
      printf '%s' "$candidate"
    fi
    return
  fi
  if [[ "$hash" =~ ^[[:xdigit:]]{2}/[[:xdigit:]]+$ ]]; then
    for candidate in "$RUN_ABS/work/$hash"*; do
      [[ -d "$candidate" ]] || continue
      (cd "$candidate" 2>/dev/null && pwd -P) || printf '%s' "$candidate"
      return
    done
  fi
}

first_command() {
  local file="$1"
  [[ -f "$file" && -r "$file" ]] || return 0
  awk '
    {
      sub(/\r$/, "")
      line=$0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "" || line ~ /^#/ || line ~ /^set[[:space:]]+[-+]/) next
      if (length(line) <= 240) print line
      exit
    }
  ' "$file"
}

add_task() {
  local process="$1" tag="$2" code="$3" stated="$4" hash="$5" workdir command
  workdir="$(resolve_workdir "$stated" "$hash")"
  command=""
  [[ -n "$workdir" ]] && command="$(first_command "$workdir/.command.sh")"
  TASK_PROCESS+=("$process")
  TASK_TAG+=("$tag")
  TASK_EXIT+=("$code")
  TASK_WORKDIR+=("$workdir")
  TASK_COMMAND+=("$command")
}

if [[ -n "$SELECTED_TRACE" ]]; then
  while IFS=$'\037' read -r process tag code workdir hash; do
    [[ -n "$process$tag$code$workdir$hash" ]] || continue
    add_task "$process" "$tag" "$code" "$workdir" "$hash"
  done < <(awk -F '\t' '
    function clean(s) { sub(/\r$/, "", s); return s }
    function value(name) { return (name in h) ? clean($(h[name])) : "" }
    function emit_name(full,    p,t,start) {
      p=full; t=""
      if (match(full, / \(/) && substr(full,length(full),1) == ")") {
        start=RSTART
        t=substr(full, start+2, length(full)-start-2)
        p=substr(full, 1, start-1)
      }
      return p SUBSEP t
    }
    NR == 1 {
      for (i=1; i<=NF; i++) { $i=clean($i); h[tolower($i)]=i }
      next
    }
    {
      status=toupper(value("status"))
      code=value("exit"); if (code == "") code=value("exit_status")
      # ABORTED and other non-clean exits are counted separately, never as root failures.
      if (status != "FAILED") next
      process=value("process")
      tag=value("tag")
      if (process == "") {
        split(emit_name(value("name")), parts, SUBSEP)
        process=parts[1]
        if (tag == "") tag=parts[2]
      }
      workdir=value("workdir"); if (workdir == "") workdir=value("work_dir")
      hash=value("hash")
      printf "%s%c%s%c%s%c%s%c%s\n", process,31,tag,31,code,31,workdir,31,hash
    }
  ' "$SELECTED_TRACE")
fi

# If no failed row reached the newest trace, parse Nextflow's standard error block. This also
# covers failures before trace initialisation and a retained rotated log with no trace file.
if ((${#TASK_PROCESS[@]} == 0)) && [[ -n "$SELECTED_LOG" ]]; then
  while IFS=$'\037' read -r process tag code workdir hash; do
    [[ -n "$process$tag$code$workdir" ]] || continue
    add_task "$process" "$tag" "$code" "$workdir" "$hash"
  done < <(awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]\r]+$/, "", s); return s }
    function emit(    p,t,start) {
      if (!active) return
      p=name; t=""
      if (match(name, / \(/) && substr(name,length(name),1) == ")") {
        start=RSTART; t=substr(name,start+2,length(name)-start-2); p=substr(name,1,start-1)
      }
      printf "%s%c%s%c%s%c%s%c\n", p,31,t,31,code,31,workdir,31
    }
    /Error executing process > / {
      emit(); active=1; code=""; workdir=""; want_code=0; want_work=0
      name=$0
      sub(/^.*process > /, "", name)
      name=trim(name)
      first=substr(name,1,1); last=substr(name,length(name),1)
      if ((first == "\047" && last == "\047") || (first == "\"" && last == "\""))
        name=substr(name,2,length(name)-2)
      next
    }
    active && /^[[:space:]]*Command exit status:/ {
      value=$0; sub(/^[^:]*:[[:space:]]*/, "", value); value=trim(value)
      if (value != "") code=value; else want_code=1
      next
    }
    active && /^[[:space:]]*Work dir:/ {
      value=$0; sub(/^[^:]*:[[:space:]]*/, "", value); value=trim(value)
      if (value != "") workdir=value; else want_work=1
      next
    }
    active && want_code { value=trim($0); if (value != "") { code=value; want_code=0 }; next }
    active && want_work { value=trim($0); if (value != "") { workdir=value; want_work=0 }; next }
    END { emit() }
  ' "$SELECTED_LOG")
fi

if ((${#TASK_PROCESS[@]})) && { [[ -z "$COUNT_FAILED" ]] || ((COUNT_FAILED < ${#TASK_PROCESS[@]})); }; then
  COUNT_FAILED="${#TASK_PROCESS[@]}"
fi

evidence_sources=()
[[ -n "$SELECTED_LOG" ]] && evidence_sources+=("$SELECTED_LOG")
[[ -n "$SELECTED_STDOUT" ]] && evidence_sources+=("$SELECTED_STDOUT")
FAILED_EVIDENCE=0
TERMINAL_STATUS=""
if ((${#evidence_sources[@]})); then
  evidence="$(awk '
    # Prefer the selected Nextflow log; stdout is a fallback, not a later session.
    function remember() {
      if (chosen == "" && terminal != "") { chosen=terminal; chosen_failed=failed }
    }
    FNR == 1 { remember(); terminal=""; failed=0 }
    /Error executing process/ || /terminated with an error exit status/ { failed=1 }
    /Session aborted -- Cause:/ {
      if ($0 ~ /Session aborted -- Cause: SIG(INT|TERM)([^[:alnum:]_]|$)/)
        terminal="cancelled"
      else terminal="failed"
      next
    }
    /[Cc]ancelled by user/ || /Received SIG(INT|TERM)([^[:alnum:]_]|$)/ {
      terminal="cancelled"; next
    }
    # FINISH errorStrategy also emits this line. Resolve it against task failures below.
    /Execution cancelled/ {
      if (terminal != "failed" && terminal != "cancelled") terminal="stopping"
      next
    }
    /Pipeline completed successfully/ { terminal="succeeded"; next }
    # ScriptRunner.shutdown prints Goodbye even after abort/cancellation. It is only a
    # successful completion when the session has no terminal abort/cancellation evidence.
    /Execution complete -- Goodbye/ || /Session complete/ {
      if (terminal == "") terminal="succeeded"
    }
    END { remember(); printf "%s%c%d", chosen,31,chosen_failed+0 }
  ' "${evidence_sources[@]}")"
  IFS=$'\037' read -r TERMINAL_STATUS FAILED_EVIDENCE <<< "$evidence"
fi

# Process checks never send a signal other than the read-only liveness probe.
pid_is_live() {
  local pid="$1" state
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  case "${OSTYPE:-}" in
    msys*|cygwin*)
      # Git Bash PIDs are not Windows PIDs; query its own process table.
      ps -p "$pid" 2>/dev/null | awk -v pid="$pid" 'NR>1 && $1 == pid { found=1 } END { exit !found }'
      return
      ;;
  esac
  if [[ -r "/proc/$pid/stat" ]]; then
    state="$(awk '{ sub(/^.*\) /, ""); print $1 }' "/proc/$pid/stat" 2>/dev/null)" || return 1
    [[ -n "$state" && "$state" != Z && "$state" != X ]] || return 1
    return 0
  fi
  kill -0 "$pid" 2>/dev/null
}

head_is_live() {
  local pid run_pattern comm
  if [[ -f "$RUN_ABS/nextflow.pid" && -r "$RUN_ABS/nextflow.pid" ]]; then
    if pid="$(cat "$RUN_ABS/nextflow.pid" 2>/dev/null)"; then
      pid="${pid%$'\r'}"
      if pid_is_live "$pid"; then return 0; fi
    fi
  fi
  # A missing, unreadable, malformed or stale PID is no evidence; keep scanning.
  # Same run-path-delimited scan and JVM filter as guard-workdir/runbook. No
  # unfiltered fallback: a tmux server or launcher shell is not a head process.
  command -v pgrep >/dev/null 2>&1 || return 1
  run_pattern="$(printf '%s' "$RUN_ABS" | sed 's/[][\.*^$+?()|{}]/\\&/g')"
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
    if [[ -r "/proc/$pid/comm" ]]; then
      comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || continue
    else
      comm="$(ps -p "$pid" -o comm= 2>/dev/null)" || continue
      comm="${comm##*/}"
    fi
    [[ "$comm" == java ]] && pid_is_live "$pid" && return 0
  done < <(pgrep -f "nextflow.*$run_pattern/" 2>/dev/null || true)
  return 1
}

# Task failures/counts describe attempts, never the final state of a run.
if [[ -n "$TERMINAL_STATUS" && "$TERMINAL_STATUS" != stopping ]]; then
  STATUS="$TERMINAL_STATUS"
elif [[ "$TERMINAL_STATUS" == stopping ]]; then
  if ((FAILED_EVIDENCE == 1)); then STATUS=failed; else STATUS=cancelled; fi
elif head_is_live; then
  STATUS=running
else
  STATUS=unknown
fi

LAST_LOG_TIME=""
last_log="${SELECTED_LOG:-$SELECTED_STDOUT}"
if [[ -n "$last_log" ]]; then
  LAST_LOG_TIME="$(awk '
    /^[A-Z][a-z][a-z]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/ { stamp=$1 " " $2 }
    match($0, /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][T ][0-9][0-9]:[0-9][0-9]:[0-9][0-9]([.,][0-9]+)?(Z|[+-][0-9][0-9]:?[0-9][0-9])?/) { stamp=substr($0,RSTART,RLENGTH) }
    END { print stamp }
  ' "$last_log")"
  if [[ -z "$LAST_LOG_TIME" ]]; then
    LAST_LOG_TIME="$(stat -c '%y' "$last_log" 2>/dev/null || stat -f '%Sm' "$last_log" 2>/dev/null || true)"
  fi
fi

display_count() { [[ -n "$1" ]] && printf '%s' "$1" || printf '?'; }

json_strings() {
  LC_ALL=C awk -v mode="$1" '
    function escape(value,    i,ch) {
      for (i=1; i<=length(value); i++) {
        ch=substr(value,i,1)
        printf "%s", (ch in escapes) ? escapes[ch] : ch
      }
    }
    BEGIN {
      for (i=0; i<32; i++) escapes[sprintf("%c",i)]=sprintf("\\u%04x",i)
      escapes["\\"]="\\\\"; escapes["\""]="\\\""
      escapes["\b"]="\\b"; escapes["\f"]="\\f"; escapes["\r"]="\\r"; escapes["\t"]="\\t"
      printf "%s", mode == "lines" ? "[" : "\""
    }
    {
      if (mode == "lines") {
        if (NR>1) printf ","
        sub(/\r$/, "")
        printf "\""; escape($0); printf "\""
      }
      else {
        if (NR>1) printf "\\n"
        escape($0)
      }
    }
    END { printf "%s", mode == "lines" ? "]" : "\"" }
  '
}

# The appended record separator lets awk preserve every newline in the scalar value.
json_quote() { printf '%s\n' "$1" | json_strings string; }
json_count() { [[ -n "$1" ]] && printf '%s' "$1" || printf 'null'; }

json_paths() {
  local first=1 path
  printf '['
  for path in "$@"; do
    ((first == 1)) || printf ','
    json_quote "$path"
    first=0
  done
  printf ']'
}

json_stderr_tail() {
  local workdir="$1"
  if [[ -n "$workdir" && -f "$workdir/.command.err" && -r "$workdir/.command.err" ]]; then
    # Stream bytes directly: Bash variables/read would silently discard embedded NUL.
    { tail -n "$TAIL_LINES" "$workdir/.command.err" 2>/dev/null || true; } | json_strings lines
  else
    printf '[]'
  fi
}

if ((JSON == 1)); then
  printf '{'
  printf '"run_dir":'; json_quote "$RUN_ABS"
  printf ',"status":'; json_quote "$STATUS"
  printf ',"last_log_time":'; [[ -n "$LAST_LOG_TIME" ]] && json_quote "$LAST_LOG_TIME" || printf 'null'
  printf ',"counts":{"cached":'; json_count "$COUNT_CACHED"
  printf ',"completed":'; json_count "$COUNT_COMPLETED"
  printf ',"failed":'; json_count "$COUNT_FAILED"
  printf ',"aborted":'; json_count "$COUNT_ABORTED"
  printf ',"non_clean":'; json_count "$COUNT_NON_CLEAN"
  printf '},"tail":%s' "$TAIL_LINES"
  printf ',"nextflow_logs":'; json_paths "${NEXTFLOW_LOGS[@]}"
  printf ',"stdout_logs":'; json_paths "${STDOUT_LOGS[@]}"
  printf ',"traces":'; json_paths "${TRACES[@]}"
  printf ',"reports":'; json_paths "${REPORTS[@]}"
  printf ',"failed_tasks":['
  for ((i=0; i<${#TASK_PROCESS[@]}; i++)); do
    ((i == 0)) || printf ','
    printf '{"process":'; json_quote "${TASK_PROCESS[$i]}"
    printf ',"tag":'; [[ -n "${TASK_TAG[$i]}" ]] && json_quote "${TASK_TAG[$i]}" || printf 'null'
    printf ',"exit_status":';
    if [[ "${TASK_EXIT[$i]}" =~ ^-?[0-9]+$ ]]; then printf '%s' "${TASK_EXIT[$i]}"; else json_quote "${TASK_EXIT[$i]}"; fi
    printf ',"workdir":'; [[ -n "${TASK_WORKDIR[$i]}" ]] && json_quote "${TASK_WORKDIR[$i]}" || printf 'null'
    printf ',"stderr_tail":'; json_stderr_tail "${TASK_WORKDIR[$i]}"
    printf ',"command":'; [[ -n "${TASK_COMMAND[$i]}" ]] && json_quote "${TASK_COMMAND[$i]}" || printf 'null'
    printf '}'
  done
  printf ']}\n'
  exit 0
fi

printf 'run: %s\n' "$RUN_ABS"
printf 'status: %s\n' "$STATUS"
if [[ "$STATUS" == unknown ]]; then
  printf '  멈춘 것으로 보이나 terminal 표식 없음\n'
fi
printf 'last log time: %s\n' "${LAST_LOG_TIME:-(unavailable)}"
printf 'counts: cached=%s completed=%s failed=%s aborted=%s non_clean=%s\n' \
  "$(display_count "$COUNT_CACHED")" "$(display_count "$COUNT_COMPLETED")" "$(display_count "$COUNT_FAILED")" \
  "$(display_count "$COUNT_ABORTED")" "$(display_count "$COUNT_NON_CLEAN")"

printf 'nextflow logs:'
if ((${#NEXTFLOW_LOGS[@]})); then
  printf '\n'; for path in "${NEXTFLOW_LOGS[@]}"; do printf '  %s\n' "$path"; done
else
  printf ' none\n'
fi
printf 'stdout logs:'
if ((${#STDOUT_LOGS[@]})); then
  printf '\n'; for path in "${STDOUT_LOGS[@]}"; do printf '  %s\n' "$path"; done
else
  printf ' none\n'
fi
printf 'trace files:'
if ((${#TRACES[@]})); then
  printf '\n'; for path in "${TRACES[@]}"; do printf '  %s\n' "$path"; done
else
  printf ' none\n'
fi
printf 'report files:'
if ((${#REPORTS[@]})); then
  printf '\n'; for path in "${REPORTS[@]}"; do printf '  %s\n' "$path"; done
else
  printf ' none\n'
fi

printf 'failed tasks: %d\n' "${#TASK_PROCESS[@]}"
for ((i=0; i<${#TASK_PROCESS[@]}; i++)); do
  printf '\ntask %d:\n' "$((i+1))"
  printf '  process: %s\n' "${TASK_PROCESS[$i]:-(unknown)}"
  printf '  tag: %s\n' "${TASK_TAG[$i]:-(none)}"
  printf '  exit status: %s\n' "${TASK_EXIT[$i]:-(unknown)}"
  printf '  work dir: %s\n' "${TASK_WORKDIR[$i]:-(unknown)}"
  [[ -z "${TASK_COMMAND[$i]}" ]] || printf '  command: %s\n' "${TASK_COMMAND[$i]}"
  printf '  stderr (last %d lines):\n' "$TAIL_LINES"
  workdir="${TASK_WORKDIR[$i]}"
  if [[ -n "$workdir" && -f "$workdir/.command.err" && -r "$workdir/.command.err" ]]; then
    if ! tail -n "$TAIL_LINES" "$workdir/.command.err" 2>/dev/null | sed 's/^/    /'; then
      printf '    (unavailable)\n'
    fi
  else
    printf '    (unavailable)\n'
  fi
done

exit 0
