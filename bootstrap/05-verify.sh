#!/usr/bin/env bash
# 05-verify.sh — end-to-end substrate health check. Read-only, safe to run anytime.
#
#   bash /mnt/d/bioinfo-agent/bootstrap/05-verify.sh
#   bash /mnt/d/bioinfo-agent/bootstrap/05-verify.sh --facts
#
# Prints one line per check and a final verdict: READY, or a numbered list of what is
# broken. Exits non-zero unless READY. Warnings never fail the run — a missing VEP cache
# is a fact about the reference store, not a broken substrate.
#
# --facts prints nothing but key=value lines and exits 0. It is the ONE runtime source
# for host facts — cores, memory, the Nextflow ceiling, free space, tool versions. Docs
# and run plans read it instead of hardcoding numbers that go stale.
#
# Run this before every session, and again after any `wsl --shutdown`. Most "the
# pipeline hung" reports are a distro that came back with systemd not PID 1 and docker
# therefore dead.
#
# CRLF guard — see 01-wsl-base.sh. Trailing `#` swallows this line's own CR.
if [ -z "${BIOINFO_CRLF_REEXEC:-}" ] && grep -q $'\r' "$0" 2>/dev/null; then export BIOINFO_CRLF_REEXEC=1; exec bash <(tr -d '\r' < "$0") "$@"; fi  # CRLF self-heal
set -uo pipefail
# NOTE: deliberately NOT -e. This script's job is to survive every failure it finds and
# still print a complete report; -e would abort at the first broken check.

FACTS=0
case "${1:-}" in
  --facts)   FACTS=1 ;;
  -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
  '')        : ;;
  *) echo "unknown flag: $1" >&2; exit 2 ;;
esac

# NXF_OFFLINE, captured before anything is sourced — see the check in section 6.
NXF_OFFLINE_AMBIENT="${NXF_OFFLINE:-}"

# config/host.env first, the generated contract second, so ~/.config/bioinfo/env.sh
# always wins: that file is what a pipeline run actually gets, and it is what this
# script exists to check. Parsed, not sourced — see bootstrap/lib/host-env.sh.
HOST_ENV="${BIOINFO_HOME:-/mnt/d/bioinfo-agent}/config/host.env"
. "$(dirname "$0")/lib/host-env.sh"      # parses; never executes host.env
load_host_env "$HOST_ENV"

ENVFILE="$HOME/.config/bioinfo/env.sh"
if [ -f "$ENVFILE" ]; then
  # shellcheck disable=SC1090
  . "$ENVFILE"
  ENV_SOURCED=1
else
  ENV_SOURCED=0
fi

BIOINFO_HOME_V="${BIOINFO_HOME:-/mnt/d/bioinfo-agent}"
REFS="${BIOINFO_REFS:-/refs}"
WORK="${BIOINFO_WORK:-/work}"
EXPECT_DISTRO="${BIOINFO_DISTRO:-Ubuntu-24.04}"

# Thresholds. FAIL is "you cannot usefully start work"; WARN is "plan your disk".
EXT4_FAIL_GIB=20
EXT4_WARN_GIB=100
WIN_WARN_GIB=50

declare -a FAILS=()
declare -a WARNS=()

head_() { printf '\n== %s\n' "$*"; }
ok()    { printf '   [ ok ] %s\n' "$*"; }
info()  { printf '   [info] %s\n' "$*"; }
warn()  { printf '   [warn] %s\n' "$*"; WARNS+=("$*"); }
fail()  { printf '   [FAIL] %s\n' "$*"; FAILS+=("$*"); }

gib()  { awk -v k="${1:-0}" 'BEGIN{printf "%.0f", k/1048576}'; }          # KiB -> GiB
availk() { df -Pk "$1" 2>/dev/null | awk 'NR==2{print $4}'; }

fstype_of() {
  local d="$1"
  while [ ! -e "$d" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done
  if command -v findmnt >/dev/null 2>&1; then
    findmnt -no FSTYPE -T "$d" 2>/dev/null || echo unknown
  else
    stat -f -c %T "$d" 2>/dev/null || echo unknown
  fi
}

# ============================================================ --facts
# Machine-readable, one key=value per line, nothing else on stdout. Blank value means
# "could not determine" — callers must handle that rather than assume a default.
if [ "$FACTS" -eq 1 ]; then
  printf 'cores=%s\n'        "$(nproc 2>/dev/null)"
  printf 'mem_gb=%s\n'       "$(awk '/^MemTotal:/{printf "%.0f", $2/1048576}' /proc/meminfo 2>/dev/null)"
  printf 'nxf_max_cpus=%s\n' "${BIOINFO_MAX_CPUS:-}"
  printf 'nxf_max_mem=%s\n'  "${BIOINFO_MAX_MEMORY:-}"
  printf 'work_root=%s\n'    "$WORK"
  printf 'work_free_gb=%s\n' "$([ -d "$WORK" ] && gib "$(availk "$WORK")")"
  printf 'refs_root=%s\n'    "$REFS"
  printf 'refs_free_gb=%s\n' "$([ -d "$REFS" ] && gib "$(availk "$REFS")")"
  printf 'distro=%s\n'       "${WSL_DISTRO_NAME:-$EXPECT_DISTRO}"
  printf 'nextflow_ver=%s\n' "$(nextflow -v 2>/dev/null | sed -n 's/.*version \([0-9][^ ]*\).*/\1/p' | head -1)"
  printf 'nfcore_ver=%s\n'   "$(nf-core --version 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | tail -1)"
  exit 0
fi

printf '\nbioinfo substrate verification  —  %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"

# ============================================================ 1. distro identity
head_ 'Distro'
if [ -n "${WSL_DISTRO_NAME:-}" ]; then
  info "WSL_DISTRO_NAME = $WSL_DISTRO_NAME"
  if [ "$WSL_DISTRO_NAME" = "$EXPECT_DISTRO" ]; then
    ok "running in the expected distro"
  else
    # The legacy archive distro is a real hazard here: it has anaconda and old tools and
    # will half-work, producing results nobody can reproduce.
    fail "expected $EXPECT_DISTRO but this is $WSL_DISTRO_NAME. If this is Ubuntu-legacy, exit — that distro is a read-only archive, not the pipeline substrate."
  fi
else
  fail "WSL_DISTRO_NAME unset — this does not look like a WSL distro"
fi

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  info "${PRETTY_NAME:-unknown}"
  info "kernel $(uname -r)"
fi

# ============================================================ 2. systemd
head_ 'Init'
PID1="$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')"
if [ "$PID1" = "systemd" ]; then
  ok 'systemd is PID 1'
else
  fail "PID 1 is '$PID1', not systemd. /etc/wsl.conf needs [boot] systemd=true AND a restart: run 'wsl --terminate ${WSL_DISTRO_NAME:-$EXPECT_DISTRO}' from Windows, then come back."
fi

# ============================================================ 3. docker
head_ 'Docker'
if ! command -v docker >/dev/null 2>&1; then
  fail 'docker not installed — run bootstrap/02-docker.sh as root'
elif ! docker info >/dev/null 2>&1; then
  if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    fail "docker daemon unreachable and $USER is not in the docker group. Fix: sudo usermod -aG docker $USER, then 'wsl --terminate ${WSL_DISTRO_NAME:-$EXPECT_DISTRO}' from Windows (group membership is only re-read at login)."
  else
    fail "docker daemon not responding. Try: sudo systemctl start docker ; then journalctl -u docker -n 50"
  fi
else
  ok "daemon up, server $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  DROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
  info "data-root $DROOT ($(fstype_of "$DROOT"))"
  case "$DROOT" in
    /mnt/*) fail "docker data-root $DROOT is on drvfs — image layer extraction will crawl. Move it to ext4." ;;
  esac

  # Only pull if we must; a cached image keeps this check offline-safe.
  if docker image inspect hello-world >/dev/null 2>&1; then
    HW_CACHED=1
  else
    HW_CACHED=0
  fi
  if docker run --rm hello-world >/dev/null 2>&1; then
    if [ "$HW_CACHED" -eq 1 ]; then ok 'hello-world ran (cached image)'; else ok 'hello-world pulled and ran — registry reachable'; fi
  else
    if [ "$HW_CACHED" -eq 0 ]; then
      fail 'cannot run hello-world and the image is not cached — most likely no network / registry blocked. Nextflow will not be able to pull pipeline containers either.'
    else
      fail 'hello-world image is cached but will not run — the container runtime is broken. Check: journalctl -u docker -n 50'
    fi
  fi
fi

# ============================================================ 4. java
head_ 'Java'
if ! command -v java >/dev/null 2>&1; then
  fail 'no java — run bootstrap/01-wsl-base.sh as root'
else
  JV="$(java -version 2>&1 | head -1)"
  JMAJ="$(printf '%s' "$JV" | sed -n 's/.*version "\([0-9]\+\).*/\1/p')"
  info "$JV"
  if [ -n "$JMAJ" ] && [ "$JMAJ" -ge 17 ]; then ok "Java $JMAJ (>= 17)"; else fail "Nextflow needs Java 17+, found: $JV"; fi
  if [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java" ]; then ok "JAVA_HOME = $JAVA_HOME"
  else warn "JAVA_HOME is unset or wrong (${JAVA_HOME:-unset}) — Nextflow usually copes, but set it via 03-nextflow.sh"; fi
fi

# ============================================================ 5. nextflow / nf-core
head_ 'Nextflow toolchain'
# A fail, not a warn. Without the contract the NXF_* checks below would happily validate
# whatever config/host.env happens to export and report READY on a box where no run can
# work — which is the failure this script exists to prevent.
[ "$ENV_SOURCED" -eq 1 ] && ok "env contract sourced from $ENVFILE" || fail "$ENVFILE absent — the environment contract was never generated. Run bootstrap/03-nextflow.sh as the pipeline user."

if ! command -v nextflow >/dev/null 2>&1; then
  fail 'nextflow not on PATH — run bootstrap/03-nextflow.sh as the pipeline user'
else
  NV="$(nextflow -version 2>&1 | sed -n 's/.*version \([0-9][^ ]*\).*/\1/p' | head -1)"
  if [ -n "$NV" ]; then ok "nextflow $NV"; else fail "nextflow present but 'nextflow -version' failed — run it by hand to see the JVM error"; fi
fi

if ! command -v nf-core >/dev/null 2>&1; then
  fail 'nf-core not on PATH — run bootstrap/03-nextflow.sh'
else
  # nf-core prints an ASCII banner before the version string, and that banner opens with a
  # blank line — `head -1` captures the blank and the check reads as a failure on a perfectly
  # healthy install. Take the last line that actually carries a version number.
  NFC="$(nf-core --version 2>&1 | grep -E '[0-9]+\.[0-9]+' | tail -1 | sed 's/^[[:space:]]*//')"
  if [ -n "$NFC" ]; then ok "$NFC"; else fail 'nf-core present but --version produced no version string'; fi
fi

# ============================================================ 6. NXF_* placement
head_ 'NXF_* paths (must be ext4, must be writable)'
for v in NXF_HOME NXF_ASSETS NXF_WORK NXF_TEMP NXF_SINGULARITY_CACHEDIR; do
  p="${!v:-}"
  if [ -z "$p" ]; then
    if [ "$v" = "NXF_SINGULARITY_CACHEDIR" ]; then
      warn "$v unset (only matters for -profile singularity/apptainer)"
    else
      fail "$v is unset — the environment contract is incomplete. Re-run 03-nextflow.sh and open a new shell."
    fi
    continue
  fi

  case "$p" in
    /mnt/*) fail "$v=$p is on drvfs. Nextflow work and cache directories must be on ext4; drvfs is 5-10x slower on the small random I/O these do."; continue ;;
  esac

  FT="$(fstype_of "$p")"
  if [ "$FT" != "ext4" ]; then
    warn "$v=$p is on filesystem '$FT', expected ext4"
  fi

  if [ ! -d "$p" ]; then
    fail "$v=$p does not exist"
    continue
  fi
  TPROBE="$p/.bioinfo-write-probe.$$"
  if touch "$TPROBE" 2>/dev/null; then
    rm -f "$TPROBE"
    ok "$v=$p  ($FT, writable)"
  else
    fail "$v=$p is not writable by $USER"
  fi
done

# This script sources env.sh, and env.sh ends with `unset NXF_OFFLINE` — so testing
# $NXF_OFFLINE here could never fail, whatever the machine looked like. Ask a fresh login
# shell instead. That is exactly the environment a `wsl -d <distro> -- bash -lc 'nextflow
# run ...'` gets, which is how every run is actually launched.
OFFLINE_IN_LOGIN="$(bash -lc 'printf %s "${NXF_OFFLINE:-}"' 2>/dev/null)"
if [ -n "$OFFLINE_IN_LOGIN" ]; then
  fail "a fresh login shell has NXF_OFFLINE='$OFFLINE_IN_LOGIN'. It must be unset — nf-core runs resolve revisions and pull containers on first use. Find the export in ~/.bashrc, ~/.profile or /etc/environment."
elif [ -n "$NXF_OFFLINE_AMBIENT" ]; then
  warn "the shell that launched this script had NXF_OFFLINE='$NXF_OFFLINE_AMBIENT'. A login shell clears it, so runs are safe, but that export is still somewhere."
else
  ok 'NXF_OFFLINE unset in a fresh login shell'
fi

# ============================================================ 7. disk
head_ 'Disk'
EXT4_K="$(availk /)"
if [ -n "$EXT4_K" ]; then
  EXT4_G="$(gib "$EXT4_K")"
  if   [ "$EXT4_G" -lt "$EXT4_FAIL_GIB" ]; then fail "ext4 root has only ${EXT4_G} GiB free — nothing will run. Free space or grow the VHDX."
  elif [ "$EXT4_G" -lt "$EXT4_WARN_GIB" ]; then warn "ext4 root has ${EXT4_G} GiB free — thin for a WGS or STAR-index run"
  else ok "ext4 root: ${EXT4_G} GiB free"; fi
else
  fail 'could not read free space on /'
fi

for m in "$REFS" "${NXF_WORK:-/work/nextflow}"; do
  [ -d "$m" ] || continue
  K="$(availk "$m")"
  [ -n "$K" ] && info "$m: $(gib "$K") GiB free on $(fstype_of "$m")"
done

for w in /mnt/c /mnt/d /mnt/e; do
  if mountpoint -q "$w" 2>/dev/null; then
    K="$(availk "$w")"
    G="$(gib "${K:-0}")"
    if [ "$G" -lt "$WIN_WARN_GIB" ]; then warn "$w has only ${G} GiB free"
    else info "$w: ${G} GiB free"; fi
  else
    if [ "$w" = "/mnt/d" ]; then
      fail '/mnt/d is not mounted — the repo and every manifest link source live there'
    else
      info "$w not mounted"
    fi
  fi
done

# ============================================================ 8. repo + refs
head_ 'Repo and reference store'
if [ -d "$BIOINFO_HOME_V" ]; then ok "BIOINFO_HOME = $BIOINFO_HOME_V"
else fail "BIOINFO_HOME=$BIOINFO_HOME_V does not exist"; fi

MANIFEST="$BIOINFO_HOME_V/config/refs.manifest.tsv"
REFSCRIPT="$BIOINFO_HOME_V/bootstrap/04-refs.sh"

if [ ! -f "$MANIFEST" ]; then
  fail "manifest missing: $MANIFEST"
elif [ ! -f "$REFSCRIPT" ]; then
  fail "04-refs.sh missing: $REFSCRIPT"
else
  # Reuse 04 rather than reimplementing its logic — one definition of "correct refs".
  # --dry-run makes it read-only; its exit code is non-zero only for hard breakage.
  REFOUT="$(bash "$REFSCRIPT" --dry-run --quiet --manifest "$MANIFEST" --refs "$REFS" 2>&1)"
  REFRC=$?
  SUMLINE="$(printf '%s\n' "$REFOUT" | grep -E '^\[04-refs\] [0-9]+ rows' || true)"
  [ -n "$SUMLINE" ] && info "${SUMLINE#\[04-refs\] }"
  if [ "$REFRC" -eq 0 ]; then
    ok 'reference store consistent with the manifest (build/fetch gaps aside)'
  else
    fail "reference store has broken link/copy sources. Run: bash $REFSCRIPT --dry-run"
    printf '%s\n' "$REFOUT" | sed -n 's/^/          /p' | head -20
  fi
fi

if [ -d "$REFS" ]; then
  NLINKS="$(find "$REFS" -maxdepth 6 \( -type l -o -type f \) 2>/dev/null | wc -l)"
  info "$REFS holds $NLINKS files/symlinks"
  BROKEN="$(find "$REFS" -maxdepth 6 -xtype l 2>/dev/null | wc -l)"
  if [ "$BROKEN" -gt 0 ]; then
    fail "$BROKEN dangling symlink(s) under $REFS — run: bash $REFSCRIPT"
  fi
else
  fail "$REFS does not exist"
fi

# ============================================================ 9. network (soft)
head_ 'Network (advisory)'
if curl -fsS -m 6 -o /dev/null https://github.com 2>/dev/null; then
  ok 'github reachable — pipeline pulls will work'
else
  warn 'github unreachable within 6s. Cached pipelines and containers still run; first-time pulls will not.'
fi

# ============================================================ verdict
printf '\n============================================================\n'
if [ "${#WARNS[@]}" -gt 0 ]; then
  printf 'WARNINGS (%d) — not blocking:\n' "${#WARNS[@]}"
  i=1; for w in "${WARNS[@]}"; do printf '  %d. %s\n' "$i" "$w"; i=$((i+1)); done
  printf '\n'
fi

if [ "${#FAILS[@]}" -eq 0 ]; then
  printf 'READY\n'
  printf '============================================================\n'
  exit 0
fi

printf 'NOT READY — %d problem(s):\n' "${#FAILS[@]}"
i=1; for f in "${FAILS[@]}"; do printf '  %d. %s\n' "$i" "$f"; i=$((i+1)); done
printf '============================================================\n'
exit 1
