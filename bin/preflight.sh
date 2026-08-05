#!/usr/bin/env bash
# preflight.sh — read-only gate before any nf-core launch on this host. Safe to re-run.
# usage: bash preflight.sh <windows-visible-run-dir> <estimated_work_GB>
set -euo pipefail

RUNDIR="${1:?usage: preflight.sh <rundir> <est_work_gb>}"
EST_GB="${2:?usage: preflight.sh <rundir> <est_work_gb>}"
RUNID="$(basename "$RUNDIR")"
WORKROOT="${NXF_WORKROOT:-${BIOINFO_WORK:-/work}/nxf}"
WORKDIR="$WORKROOT/$RUNID/work"
REFS="${BIOINFO_REFS:-/refs}"
TSV="$(cd "$(dirname "$0")/.." && pwd)/config/pipelines.tsv"

fail=0; warn=0
ok()   { printf '  OK    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }
note() { printf '  WARN  %s\n' "$*"; warn=$((warn+1)); }
# nearest existing ancestor — this script creates nothing.
upto() { local d="$1"; while [ ! -d "$d" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done; printf '%s' "$d"; }

echo "== host =="
cores="$(nproc)"
memgb="$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo)"
ok "cores visible to WSL = $cores"
if [ "$memgb" -ge 40 ]; then
  ok "RAM visible to WSL = ${memgb} GB"
else
  note "RAM visible to WSL = ${memgb} GB. WSL2 defaults to ~half of host RAM; set memory= in %USERPROFILE%\\.wslconfig and 'wsl --shutdown'."
fi

echo "== docker =="
if docker info >/dev/null 2>&1; then
  ok "docker responsive ($(docker version --format '{{.Server.Version}}'))"
  droot="$(docker info --format '{{.DockerRootDir}}')"
  case "$droot" in
    /mnt/*) bad "docker data-root is on drvfs: $droot" ;;
    *)      ok "docker data-root = $droot" ;;
  esac
else
  bad "docker not responding (pid1=$(ps -p 1 -o comm=)). Try: sudo systemctl start docker"
fi

echo "== filesystems =="
case "$WORKDIR" in
  /mnt/*) bad "work dir is on drvfs: $WORKDIR — must be ext4, refusing" ;;
  *)      ok "work dir on ext4: $WORKDIR" ;;
esac
[ -d "$WORKROOT" ] || note "$WORKROOT does not exist yet — free space measured on $(upto "$WORKDIR")"
avail_gb="$(df -BG --output=avail "$(upto "$WORKDIR")" | tail -1 | tr -dc '0-9')"
need_gb=$(( (EST_GB * 3 + 1) / 2 ))
if [ "$avail_gb" -ge "$need_gb" ]; then
  ok "ext4 free ${avail_gb} GB >= 1.5x estimate (${need_gb} GB)"
else
  bad "ext4 free ${avail_gb} GB < 1.5x estimate (${need_gb} GB). DO NOT LAUNCH."
fi
WINMNT="$(printf '%s' "${BIOINFO_HOME:-/mnt/d/bioinfo-agent}" | grep -oE '^/mnt/[a-z]+' || true)"
if [ -n "$WINMNT" ] && mountpoint -q "$WINMNT" 2>/dev/null; then
  d_gb="$(df -BG --output=avail "$WINMNT" | tail -1 | tr -dc '0-9')"
  ok "$WINMNT free ${d_gb} GB (rsync target for results)"
else
  note "${WINMNT:-the BIOINFO_HOME mount} is not mounted — copy-out target for results unchecked"
fi

echo "== nextflow =="
if command -v nextflow >/dev/null 2>&1; then
  ok "nextflow $(nextflow -v 2>&1 | head -1)"
else
  bad "nextflow not on PATH"
fi
REV=""; PIPE=""
if [ -f "$RUNDIR/cmd.sh" ]; then
  if grep -qE '(^| )-r +"?\$?\{?[0-9A-Za-z._-]+\}?"?' "$RUNDIR/cmd.sh" && ! grep -qE '(^| )-r +"?\$?\{?(dev|master|main)\}?"?( |$)' "$RUNDIR/cmd.sh"; then
    REV="$(grep -oE '(^| )-r +"?\$?\{?[0-9A-Za-z._-]+\}?"?' "$RUNDIR/cmd.sh" | head -1 | tr -d ' "${}' | sed 's/^-r//')"
    if grep -qE "^[[:space:]]*${REV}=" "$RUNDIR/cmd.sh"; then   # -r $REV — resolve the assignment
      # sed strips a trailing comment first: the cmd.sh template writes
      #   REV=3.18.0        # from config/pipelines.tsv
      # and `tr -d ' '` alone would glue the comment onto the revision.
      REV="$(grep -E "^[[:space:]]*${REV}=" "$RUNDIR/cmd.sh" | head -1 | cut -d= -f2- | sed 's/#.*$//' | tr -d '\047" ')"
    fi
    ok "revision pinned in cmd.sh: $REV"
  else
    bad "cmd.sh has no -r revision pin, or pins a floating branch (dev/master/main)"
  fi
  PIPE="$(grep -oE 'nf-core/[A-Za-z0-9_-]+' "$RUNDIR/cmd.sh" | head -1 | cut -d/ -f2 || true)"
  grep -q -- '-work-dir' "$RUNDIR/cmd.sh" || bad "cmd.sh does not set -work-dir"
  grep -q -- '-profile docker' "$RUNDIR/cmd.sh" || note "cmd.sh does not use -profile docker"
else
  bad "missing $RUNDIR/cmd.sh"
fi

echo "== stocked set =="
if [ -z "$PIPE" ]; then
  bad "cmd.sh names no nf-core/<pipeline> to look up"
elif [ ! -f "$TSV" ]; then
  note "$TSV absent — pipeline and revision unchecked against the stocked set"
else
  pin="$(awk -F'\t' -v p="$PIPE" '/^#/{next} $1=="pipeline"&&$2=="revision"{next} $1==p{print $2; exit}' "$TSV")"
  if [ -z "$pin" ]; then
    bad "nf-core/$PIPE has no row in $TSV — it is not stocked"
  elif [ "$pin" = "$REV" ]; then
    ok "nf-core/$PIPE -r $REV matches the pin in $TSV"
  else
    note "nf-core/$PIPE -r ${REV:-none} disagrees with the pin $pin in $TSV"
  fi
fi

echo "== samplesheet =="
SS="$RUNDIR/samplesheet.csv"
nrow=""; nsamp=""
if [ -f "$SS" ]; then
  ok "found $SS"
  if LC_ALL=C grep -q $'\r' "$SS"; then
    bad "samplesheet has CRLF line endings (edited on Windows). Fix: sed -i 's/\r\$//' \"$SS\""
  else
    ok "LF line endings"
  fi
  hdr="$(head -1 "$SS")"
  ok "header: $hdr"
  nrow="$(tail -n +2 "$SS" | grep -c '[^[:space:]]' || true)"
  nsamp="$(tail -n +2 "$SS" | cut -d, -f1 | sort -u | grep -c '[^[:space:]]' || true)"
  [ "$nrow" -gt 0 ] && ok "$nrow data rows, $nsamp distinct first-column IDs" || bad "no data rows"
  dups="$(tail -n +2 "$SS" | cut -d, -f1 | sort | uniq -d | tr '\n' ' ')"
  [ -z "$dups" ] || note "repeated first-column IDs: $dups (legitimate for merged tech reps; confirm it is intended)"
  while read -r p; do
    [ -n "$p" ] || continue
    if [ -e "$p" ]; then ok "input exists: $p"; else bad "input MISSING: $p"; fi
  done < <(tail -n +2 "$SS" | tr ',' '\n' | tr -d '"' | grep '/' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort -u)
else
  bad "missing $SS"
fi

echo "== plan =="
PLAN="$RUNDIR/plan.md"
if [ ! -f "$PLAN" ]; then
  bad "missing $PLAN — the plan is what the user approved; nothing launches without it"
else
  ok "found $PLAN"
  if [ -n "$REV" ]; then
    if grep -qF -- "$REV" "$PLAN"; then ok "plan.md names the revision cmd.sh pins ($REV)"
    else bad "plan.md never names revision $REV — the approved plan and cmd.sh describe different runs"; fi
  fi
  planN="$(grep -oiE '([0-9]+[[:space:]]+samples?|samples?[[:space:]]*[:=][[:space:]]*[0-9]+)' "$PLAN" | head -1 | tr -dc '0-9' || true)"
  if [ -z "$planN" ]; then
    note "plan.md states no sample count — sheet size not cross-checked"
  elif [ -z "$nrow" ]; then
    note "plan.md says $planN sample(s); no samplesheet to compare against"
  elif [ "$planN" -eq "$nrow" ] || [ "$planN" -eq "$nsamp" ]; then
    ok "plan.md sample count agrees with the sheet ($planN)"
  else
    bad "plan.md says $planN sample(s); sheet has $nrow rows / $nsamp distinct IDs"
  fi
fi

echo "== references =="
if [ -d "$REFS" ]; then ok "refs root $REFS"; else bad "refs root $REFS absent — run bootstrap/04-refs.sh"; fi
PF="$RUNDIR/params.yaml"
if [ -f "$PF" ]; then
  while read -r p; do
    if [ -e "$p" ]; then ok "ref resolves: $p"
    else bad "ref MISSING: $p — add a manifest row and re-run bootstrap/04-refs.sh"; fi
  # Anchored on a real path boundary: the char immediately before REFS must be
  # start-of-line, whitespace, or a quote -- never a path/word character. Without
  # this, prose like "config/refs.manifest.tsv" in a params.yaml comment (a very
  # natural thing to write) is misread as the path /refs.manifest.tsv, because
  # "config/refs.manifest.tsv" contains "/refs.manifest.tsv" as a raw substring.
  # Found live on run 20260805-atacseq-gbr-lcl-smoke: a comment citing the
  # manifest file by its repo-relative path failed preflight with
  # "ref MISSING: /refs.manifest.tsv" -- a real file, just not the one meant.
  done < <(grep -oE "(^|[^A-Za-z0-9_./-])${REFS}[^\"' ]*" "$PF" | sed -E 's#^[^/]*(/.*)#\1#' | sed 's/[,:]$//' | sort -u)
else
  note "no params.yaml; reference paths not checked directly (checked via cmd.sh instead)"
fi

echo "== concurrency =="
running="$(pgrep -fc 'nextflow.*run ' || true)"
if [ "${running:-0}" -eq 0 ]; then ok "no other nextflow run active"
else bad "$running nextflow process(es) already running — one heavy pipeline at a time on this host"; fi

printf '\npreflight: %d failure(s), %d warning(s)\n' "$fail" "$warn"
[ "$fail" -eq 0 ] || exit 1
