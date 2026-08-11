#!/usr/bin/env bash
# 01-wsl-base.sh — distro baseline. Run as root inside the WSL distro.
#
#   wsl -d Ubuntu-24.04 -u root -- bash /mnt/d/bioinfo-agent/bootstrap/01-wsl-base.sh
#
# Writes /etc/wsl.conf, creates the pipeline user with passwordless sudo, installs the
# base toolchain, and stakes out the ext4 roots (BIOINFO_REFS, BIOINFO_WORK, plus the
# legacy BIOINFO_RUNS reserve). Idempotent: re-running repairs drift, it does not duplicate.
# Read the PRIVILEGE GRANT block it prints — two of its changes are root-equivalent.
#
# CRLF: this repo lives on NTFS. If git checked the file out with CRLF, `./01-...sh`
# dies on the shebang (`bad interpreter: bash^M`) before any code runs — nothing can be
# done about that from inside the file. Invoking it as `bash 01-...sh` does work, and
# the guard on the next executable line then re-executes a stripped copy. The trailing
# `#` comment on that line is load-bearing: it swallows the line's own CR so bash still
# sees the `fi` keyword. The permanent fix is `*.sh text eol=lf` in .gitattributes.
#
# BIOINFO_BOOTSTRAP_DIR is exported in the same breath because the re-exec destroys `$0`:
# the stripped copy runs as /dev/fd/NN, so a later `dirname "$0"` yields /dev/fd and the
# lib source below dies with "/dev/fd/lib/host-env.sh: No such file or directory". Every
# script with this guard resolves its own directory through that variable instead.
if [ -z "${BIOINFO_CRLF_REEXEC:-}" ] && grep -q $'\r' "$0" 2>/dev/null; then export BIOINFO_CRLF_REEXEC=1 BIOINFO_BOOTSTRAP_DIR="$(cd "$(dirname "$0")" && pwd)"; exec bash <(tr -d '\r' < "$0") "$@"; fi  # CRLF self-heal
set -euo pipefail

SELFDIR="${BIOINFO_BOOTSTRAP_DIR:-$(cd "$(dirname "$0")" && pwd)}"

# config/host.env is the per-machine override file host.env.example describes. Parsed
# before every default below, so the values here are genuine fallbacks. load_host_env
# always returns 0, so a malformed host.env cannot take the whole bootstrap down.
HOST_ENV="${BIOINFO_HOME:-/mnt/d/bioinfo-agent}/config/host.env"
. "$SELFDIR/lib/host-env.sh"      # parses; never executes host.env
load_host_env "$HOST_ENV"

BIOINFO_HOME_V="${BIOINFO_HOME:-/mnt/d/bioinfo-agent}"
BIOINFO_USER="${BIOINFO_USER:-ehojune}"
BIOINFO_UID="${BIOINFO_UID:-1000}"
DISTRO="${WSL_DISTRO_NAME:-${BIOINFO_DISTRO:-Ubuntu-24.04}}"
REFS_ROOT="${BIOINFO_REFS:-/refs}"
WORK_ROOT="${BIOINFO_WORK:-/work}"
RUNS_ROOT="${BIOINFO_RUNS:-/runs}"

log()  { printf '\n[01-base] %s\n' "$*"; }
info() { printf '           %s\n' "$*"; }

RESTART_NEEDED=0

if [ "$(id -u)" -ne 0 ]; then
  echo "[01-base] must run as root:  wsl -d $DISTRO -u root -- bash $0" >&2
  exit 1
fi

if [ ! -e /proc/sys/fs/binfmt_misc/WSLInterop ] && [ -z "${WSL_DISTRO_NAME:-}" ]; then
  echo "[01-base] this does not look like a WSL distro. Refusing — it would rewrite /etc/wsl.conf on a real host." >&2
  exit 1
fi

log "distro=$DISTRO user=$BIOINFO_USER refs=$REFS_ROOT work=$WORK_ROOT runs=$RUNS_ROOT"

# ------------------------------------------------------------------ /etc/wsl.conf
# systemd=true            : docker.service, and anything else that expects a real init.
# default=<user>          : so `wsl -d <distro>` lands as the pipeline user, not root.
# appendWindowsPath=false : keeping the whole Windows PATH inside the distro makes every
#                           `command -v` walk hundreds of drvfs entries. It is a measurable
#                           tax on any script that probes for tools, which Nextflow does
#                           constantly. Call Windows binaries by full path if ever needed.
# automount metadata is deliberately NOT set: without it /mnt/* shows mode 0777, which is
# exactly what we want for running repo scripts off NTFS, and turning it on changes
# permission semantics across an existing 2 TB tree for no benefit here.
log "writing /etc/wsl.conf"
NEW_WSLCONF=$(mktemp)
cat > "$NEW_WSLCONF" <<EOF
# managed by bioinfo bootstrap/01-wsl-base.sh — edits here are overwritten
[boot]
systemd=true

[user]
default=$BIOINFO_USER

[interop]
enabled=true
appendWindowsPath=false

[automount]
enabled=true
mountFsTab=false
EOF

if [ -f /etc/wsl.conf ] && cmp -s "$NEW_WSLCONF" /etc/wsl.conf; then
  info "unchanged"
else
  if [ -f /etc/wsl.conf ]; then
    BAK="/etc/wsl.conf.bak.$(date +%Y%m%d%H%M%S)"
    cp -p /etc/wsl.conf "$BAK"
    info "existing config backed up to $BAK"
  fi
  install -m 0644 "$NEW_WSLCONF" /etc/wsl.conf
  info "installed"
  RESTART_NEEDED=1
fi
rm -f "$NEW_WSLCONF"

# ------------------------------------------------------------------ user
log "user $BIOINFO_USER"
if id "$BIOINFO_USER" >/dev/null 2>&1; then
  info "exists (uid $(id -u "$BIOINFO_USER"))"
else
  # Prefer uid 1000 so file ownership matches the legacy distro's home archive; fall
  # back to an auto-assigned uid rather than failing if 1000 is already taken.
  if getent passwd "$BIOINFO_UID" >/dev/null 2>&1; then
    info "uid $BIOINFO_UID already taken by $(getent passwd "$BIOINFO_UID" | cut -d: -f1) — letting useradd pick one"
    useradd -m -s /bin/bash -c 'bioinfo pipeline user' "$BIOINFO_USER"
  else
    useradd -m -s /bin/bash -u "$BIOINFO_UID" -c 'bioinfo pipeline user' "$BIOINFO_USER"
  fi
  info "created (uid $(id -u "$BIOINFO_USER"))"
fi

# ------------------------------------------------------------------ privilege grants
# Disclosure, not a formality. Both grants below are root, and neither is obvious from
# the outside. Printed every run, before anything is applied.
cat <<EOF

############################################################################
  PRIVILEGE GRANT — $BIOINFO_USER becomes root-equivalent in this distro.

  1. /etc/sudoers.d/90-bioinfo-nopasswd
       $BIOINFO_USER ALL=(ALL) NOPASSWD:ALL
     Any command, as root, with no password prompt. No password is set on
     the account, so this drop-in IS the only path to root.

  2. bootstrap/02-docker.sh puts $BIOINFO_USER in the 'docker' group.
     The docker socket runs as root and does not check what you mount:
     'docker run -v /:/host' reads and writes the whole filesystem as
     root. Docker group membership is root access, not a lesser one.

  Deliberate — this is a single-user pipeline box and every run needs both.
  If this distro is shared with anyone, Ctrl-C now and grant sudo per
  command instead.
############################################################################

EOF

# No password is set. WSL never runs login(1), so a locked password costs nothing and
# removes a credential from the box. sudo works via the NOPASSWD drop-in below.
for grp in sudo; do
  if id -nG "$BIOINFO_USER" | tr ' ' '\n' | grep -qx "$grp"; then
    info "already in group $grp"
  else
    usermod -aG "$grp" "$BIOINFO_USER"
    info "added to group $grp"
  fi
done

SUDOERS=/etc/sudoers.d/90-bioinfo-nopasswd
SUDOERS_TMP=$(mktemp)
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$BIOINFO_USER" > "$SUDOERS_TMP"
if [ -f "$SUDOERS" ] && cmp -s "$SUDOERS_TMP" "$SUDOERS"; then
  info "sudoers drop-in unchanged"
else
  # Validate before installing. A malformed file in sudoers.d breaks sudo for everyone,
  # and in a distro with no root password that is genuinely hard to recover from.
  if visudo -cqf "$SUDOERS_TMP"; then
    install -m 0440 -o root -g root "$SUDOERS_TMP" "$SUDOERS"
    info "installed $SUDOERS"
  else
    rm -f "$SUDOERS_TMP"
    echo "[01-base] refusing to install an invalid sudoers file" >&2
    exit 1
  fi
fi
rm -f "$SUDOERS_TMP"

# ------------------------------------------------------------------ packages
log "base packages"
export DEBIAN_FRONTEND=noninteractive

PKGS=(
  ca-certificates curl wget gnupg
  git unzip zip pigz xz-utils
  build-essential
  openjdk-17-jre-headless          # Nextflow needs a JRE >= 17; headless is ~180 MB lighter
  python3 python3-venv python3-pip pipx  # installed here because 03-nextflow.sh runs unprivileged
  dos2unix                         # the NTFS/CRLF escape hatch, referenced by the other scripts
  tmux                             # the only detach route that survives a one-shot wsl.exe
                                   # returning: its server is long-lived, so it holds the distro
                                   # up. runbook.md section 5 documents no alternative, so this
                                   # is not optional tooling.
  jq rsync tree less procps bc time file findutils util-linux
)

MISSING=()
for p in "${PKGS[@]}"; do
  if ! dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q '^install ok installed$'; then
    MISSING+=("$p")
  fi
done

if [ "${#MISSING[@]}" -eq 0 ]; then
  info "all ${#PKGS[@]} packages already installed"
else
  info "installing: ${MISSING[*]}"
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends "${MISSING[@]}"
fi

# ------------------------------------------------------------------ ext4 scratch roots
# All three are top-level on the distro's ext4 volume on purpose.
#   $REFS_ROOT  — reference store per config/refs.manifest.tsv
#   $WORK_ROOT  — Nextflow work dirs and temp. Kept out of /home so that a runaway
#                 pipeline fills a directory you can `du` in one place, and so home
#                 stays small enough to `wsl --export` when migrating machines.
#   $RUNS_ROOT  — legacy reserve, retained for existing host.env files; not an active outdir.
# None may ever live under /mnt/* — drvfs is 5-10x slower and Nextflow's work dir is
# nothing but small random reads and writes. BIOINFO_RUNLOG is deliberately absent here:
# its run records and copied deliverables live in the repo on NTFS for Windows access.
log "ext4 roots"
for d in "$REFS_ROOT" "$WORK_ROOT" "$RUNS_ROOT"; do
  case "$d" in
    /mnt/*) echo "[01-base] $d is under /mnt — that is drvfs. Refusing." >&2; exit 1 ;;
  esac
  if [ -d "$d" ]; then
    info "$d exists"
  else
    install -d -m 0755 "$d"
    info "$d created"
  fi
  chown "$BIOINFO_USER":"$BIOINFO_USER" "$d"
done
install -d -m 0755 -o "$BIOINFO_USER" -g "$BIOINFO_USER" "$WORK_ROOT/nextflow" "$WORK_ROOT/tmp"
install -d -m 0755 -o "$BIOINFO_USER" -g "$BIOINFO_USER" \
  "$REFS_ROOT/genomes" "$REFS_ROOT/catalogs" "$REFS_ROOT/cache"

# ------------------------------------------------------------------ summary
log "summary"
info "wsl.conf        : $(grep -c . /etc/wsl.conf) non-empty lines"
info "user            : $BIOINFO_USER uid=$(id -u "$BIOINFO_USER") groups=$(id -nG "$BIOINFO_USER" | tr ' ' ',')"
info "java            : $(java -version 2>&1 | head -1)"
info "pid 1           : $(ps -p 1 -o comm=)"
info "$REFS_ROOT $WORK_ROOT $RUNS_ROOT : owned by $BIOINFO_USER"

echo
if [ "$RESTART_NEEDED" -eq 1 ] || [ "$(ps -p 1 -o comm=)" != "systemd" ]; then
  cat <<EOF
============================================================================
  RESTART THE DISTRO NOW. /etc/wsl.conf is only read at distro boot, so
  systemd is not PID 1 and the default user is not applied until you do.

  From Windows:

      wsl --terminate $DISTRO

  Then continue:

      wsl -d $DISTRO -u root -- bash $BIOINFO_HOME_V/bootstrap/02-docker.sh
============================================================================
EOF
else
  cat <<EOF
============================================================================
  Baseline in place and systemd is already PID 1 — no restart needed.
  Next:  wsl -d $DISTRO -u root -- bash $BIOINFO_HOME_V/bootstrap/02-docker.sh
============================================================================
EOF
fi
