#!/usr/bin/env bash
# preflight.sh — read-only gate before any nf-core launch on this host. Safe to re-run.
# usage: bash preflight.sh <windows-visible-run-dir> <estimated_work_GB>
set -euo pipefail

RUNDIR="${1:?usage: preflight.sh <rundir> <est_work_gb>}"
EST_GB="${2:?usage: preflight.sh <rundir> <est_work_gb>}"
RUNID="$(basename "$RUNDIR")"
WORKROOT="${NXF_WORKROOT:-/work/nxf}"
WORKDIR="$WORKROOT/$RUNID/work"
REFS="${BIOINFO_REFS:-/refs}"

fail=0; warn=0
ok()   { printf '  OK    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=$((fail+1)); }
note() { printf '  WARN  %s\n' "$*"; warn=$((warn+1)); }

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
mkdir -p "$WORKDIR"
avail_gb="$(df -BG --output=avail "$WORKDIR" | tail -1 | tr -dc '0-9')"
need_gb=$(( (EST_GB * 3 + 1) / 2 ))
if [ "$avail_gb" -ge "$need_gb" ]; then
  ok "ext4 free ${avail_gb} GB >= 1.5x estimate (${need_gb} GB)"
else
  bad "ext4 free ${avail_gb} GB < 1.5x estimate (${need_gb} GB). DO NOT LAUNCH."
fi
d_gb="$(df -BG --output=avail /mnt/d | tail -1 | tr -dc '0-9')"
ok "/mnt/d free ${d_gb} GB (rsync target for results)"

echo "== nextflow =="
if command -v nextflow >/dev/null 2>&1; then
  ok "nextflow $(nextflow -v 2>&1 | head -1)"
else
  bad "nextflow not on PATH"
fi
if [ -f "$RUNDIR/cmd.sh" ]; then
  if grep -qE '(^| )-r +"?\$?\{?[0-9A-Za-z._-]+\}?"?' "$RUNDIR/cmd.sh" && ! grep -qE '(^| )-r +"?\$?\{?(dev|master|main)\}?"?( |$)' "$RUNDIR/cmd.sh"; then
    ok "revision pinned in cmd.sh: $(grep -oE '(^| )-r +"?\$?\{?[0-9A-Za-z._-]+\}?"?' "$RUNDIR/cmd.sh" | tr -s ' ' | head -1) (resolve any \$VAR against the REV= assignment above it)"
  else
    bad "cmd.sh has no -r revision pin, or pins a floating branch (dev/master/main)"
  fi
  grep -q -- '-work-dir' "$RUNDIR/cmd.sh" || bad "cmd.sh does not set -work-dir"
  grep -q -- '-profile docker' "$RUNDIR/cmd.sh" || note "cmd.sh does not use -profile docker"
else
  bad "missing $RUNDIR/cmd.sh"
fi
[ -f "$RUNDIR/plan.md" ] || note "missing $RUNDIR/plan.md — write the plan before launching"

echo "== samplesheet =="
SS="$RUNDIR/samplesheet.csv"
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
  [ "$nrow" -gt 0 ] && ok "$nrow data rows" || bad "no data rows"
  dups="$(tail -n +2 "$SS" | cut -d, -f1 | sort | uniq -d | tr '\n' ' ')"
  [ -z "$dups" ] || note "repeated first-column IDs: $dups (legitimate for merged tech reps; confirm it is intended)"
  while read -r p; do
    [ -n "$p" ] || continue
    if [ -e "$p" ]; then ok "input exists: $p"; else bad "input MISSING: $p"; fi
  done < <(tail -n +2 "$SS" | tr ',' '\n' | tr -d '"' | grep '/' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort -u)
else
  bad "missing $SS"
fi

echo "== references =="
if [ -d "$REFS" ]; then ok "refs root $REFS"; else bad "refs root $REFS absent — run bootstrap/04-refs.sh"; fi
PF="$RUNDIR/params.yaml"
if [ -f "$PF" ]; then
  while read -r p; do
    if [ -e "$p" ]; then ok "ref resolves: $p"
    else bad "ref MISSING: $p — add a manifest row and re-run bootstrap/04-refs.sh"; fi
  done < <(grep -oE "${REFS}[^\"' ]*" "$PF" | sed 's/[,:]$//' | sort -u)
else
  note "no params.yaml; reference paths not checked directly (checked via cmd.sh instead)"
fi

echo "== concurrency =="
running="$(pgrep -fc 'nextflow.*run ' || true)"
if [ "${running:-0}" -eq 0 ]; then ok "no other nextflow run active"
else note "$running nextflow process(es) already running — one heavy pipeline at a time"; fi

printf '\npreflight: %d failure(s), %d warning(s)\n' "$fail" "$warn"
[ "$fail" -eq 0 ] || exit 1
