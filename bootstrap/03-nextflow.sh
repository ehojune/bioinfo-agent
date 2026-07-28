#!/usr/bin/env bash
# 03-nextflow.sh — Nextflow + nf-core tooling + the environment contract.
# Run as the PIPELINE USER, not root:
#
#   wsl -d Ubuntu-24.04 -- bash /mnt/d/bioinfo/bootstrap/03-nextflow.sh
#
# Flags:  --update   also self-update an existing Nextflow and upgrade nf-core
#         --help
#
# Idempotent. Re-running rewrites the env file and re-verifies; it does not reinstall.
#
# CRLF guard — see the long comment in 01-wsl-base.sh. Trailing `#` swallows the CR.
if [ -z "${BIOINFO_CRLF_REEXEC:-}" ] && grep -q $'\r' "$0" 2>/dev/null; then export BIOINFO_CRLF_REEXEC=1; exec bash <(tr -d '\r' < "$0") "$@"; fi  # CRLF self-heal
set -euo pipefail

DO_UPDATE=0
for a in "$@"; do
  case "$a" in
    --update) DO_UPDATE=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done

log()  { printf '\n[03-nxf] %s\n' "$*"; }
info() { printf '          %s\n' "$*"; }
die()  { printf '\n[03-nxf] FATAL: %s\n' "$*" >&2; exit 1; }

# Running this as root would put Nextflow in /root/.local/bin and write the env contract
# into root's bashrc, where the pipeline user never sees it. Catch it early.
if [ "$(id -u)" -eq 0 ]; then
  die "run as the pipeline user, not root:  wsl -d \${WSL_DISTRO_NAME:-Ubuntu-24.04} -- bash $0"
fi

# ------------------------------------------------------------------ the contract
BIOINFO_HOME_V="${BIOINFO_HOME:-/mnt/d/bioinfo}"
BIOINFO_REFS_V="${BIOINFO_REFS:-/refs}"
WORK_ROOT="${BIOINFO_WORK_ROOT:-/work}"

NXF_HOME_V="$HOME/.nextflow"
# NXF_ASSETS is where `nextflow pull` / `nextflow run nf-core/x` clones pipeline repos.
# Parking it in the reference store's cache tree means one place holds every large,
# machine-local, regenerable artefact — and 05-verify.sh only has to check one root.
NXF_ASSETS_V="$BIOINFO_REFS_V/cache/nf-assets"
NXF_WORK_V="$WORK_ROOT/nextflow"
NXF_TEMP_V="$WORK_ROOT/tmp"
NXF_CONTAINERS_V="$BIOINFO_REFS_V/cache/containers"

# Hard invariant: none of these may resolve under /mnt. drvfs is 5-10x slower than ext4
# and a work directory is nothing but small random I/O. Getting this wrong does not
# error — it just makes every run three times longer, which is worse.
for v in NXF_HOME_V NXF_ASSETS_V NXF_WORK_V NXF_TEMP_V NXF_CONTAINERS_V; do
  case "${!v}" in
    /mnt/*) die "${v%_V}=${!v} is on drvfs. Every NXF_* path must be on ext4." ;;
  esac
done

log "target layout"
info "BIOINFO_HOME  = $BIOINFO_HOME_V   (repo; drvfs is fine, it is only text)"
info "BIOINFO_REFS  = $BIOINFO_REFS_V"
info "NXF_HOME      = $NXF_HOME_V"
info "NXF_ASSETS    = $NXF_ASSETS_V"
info "NXF_WORK      = $NXF_WORK_V"
info "NXF_TEMP      = $NXF_TEMP_V"

for d in "$NXF_HOME_V" "$NXF_ASSETS_V" "$NXF_WORK_V" "$NXF_TEMP_V" "$NXF_CONTAINERS_V" "$HOME/.local/bin"; do
  if ! mkdir -p "$d" 2>/dev/null; then
    die "cannot create $d — check ownership. Root should have run: install -d -o $USER -g $USER $(dirname "$d")"
  fi
done

# ------------------------------------------------------------------ java
log "java"
command -v java >/dev/null 2>&1 || die "no java. Run bootstrap/01-wsl-base.sh as root first."

JAVA_BIN="$(command -v java)"
JAVA_REAL="$(readlink -f "$JAVA_BIN")"
JAVA_HOME_V="$(dirname "$(dirname "$JAVA_REAL")")"
JAVA_VER_RAW="$(java -version 2>&1 | head -1)"
# "openjdk version \"17.0.19\" ..." -> 17
JAVA_MAJOR="$(printf '%s' "$JAVA_VER_RAW" | sed -n 's/.*version "\([0-9]\+\).*/\1/p')"
info "$JAVA_VER_RAW"
info "JAVA_HOME = $JAVA_HOME_V"
if [ -z "$JAVA_MAJOR" ] || [ "$JAVA_MAJOR" -lt 17 ]; then
  die "Nextflow requires Java 17+. Found: $JAVA_VER_RAW"
fi

# ------------------------------------------------------------------ nextflow
log "nextflow"
NXF_BIN="$HOME/.local/bin/nextflow"

if [ -x "$NXF_BIN" ]; then
  info "already installed at $NXF_BIN"
  if [ "$DO_UPDATE" -eq 1 ]; then
    info "self-updating"
    JAVA_HOME="$JAVA_HOME_V" NXF_HOME="$NXF_HOME_V" "$NXF_BIN" self-update
  fi
else
  # The official installer writes ./nextflow into $PWD. Do it in a scratch dir so a
  # failed download cannot leave a stray launcher in whatever directory we were called
  # from (which, on a bad day, is /mnt/d/bioinfo).
  TMPD="$(mktemp -d)"
  trap 'rm -rf "$TMPD"' EXIT
  info "downloading via get.nextflow.io"
  ( cd "$TMPD" && curl -fsSL https://get.nextflow.io | JAVA_HOME="$JAVA_HOME_V" bash ) \
    || die "nextflow installer failed — check network, and that NXF_OFFLINE is not set"
  install -m 0755 "$TMPD/nextflow" "$NXF_BIN"
  info "installed to $NXF_BIN"
fi

export PATH="$HOME/.local/bin:$PATH"
export JAVA_HOME="$JAVA_HOME_V"
export NXF_HOME="$NXF_HOME_V"
export NXF_ASSETS="$NXF_ASSETS_V"
unset NXF_OFFLINE || true

# ------------------------------------------------------------------ nf-core tools
log "nf-core tools"
#
# WHY pipx AND NOT conda / pip --user / a bare venv:
#   - Ubuntu 24.04 ships PEP 668 "externally managed" python. `pip install --user nf-core`
#     is refused outright, and --break-system-packages earns exactly what it says.
#   - conda is explicitly off the table for this repo, and would drag in a second python
#     and a second package resolver that fights with the distro's.
#   - pipx is a venv underneath — the same isolation — but it owns the launcher shim in
#     ~/.local/bin, so `nf-core` is on PATH without any activate step, and `pipx upgrade
#     nf-core` is a one-liner. A hand-rolled venv needs a manual symlink and a manual
#     upgrade dance for zero benefit.
# The hand-rolled venv below is a fallback only, for a distro where apt's pipx is absent.
#
NFCORE_BIN="$HOME/.local/bin/nf-core"

if command -v nf-core >/dev/null 2>&1 && [ "$DO_UPDATE" -eq 0 ]; then
  info "already installed: $(nf-core --version 2>&1 | head -1)"
elif command -v pipx >/dev/null 2>&1; then
  export PIPX_HOME="${PIPX_HOME:-$HOME/.local/pipx}"
  export PIPX_BIN_DIR="${PIPX_BIN_DIR:-$HOME/.local/bin}"
  if pipx list --short 2>/dev/null | awk '{print $1}' | grep -qx nf-core; then
    if [ "$DO_UPDATE" -eq 1 ]; then
      info "upgrading via pipx"
      pipx upgrade nf-core || info "pipx upgrade reported nothing to do"
    fi
  else
    info "installing via pipx"
    pipx install nf-core
  fi
else
  VENV="$HOME/.local/venvs/nf-core"
  info "pipx unavailable — falling back to a venv at $VENV"
  [ -d "$VENV" ] || python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet --upgrade nf-core
  ln -sfn "$VENV/bin/nf-core" "$NFCORE_BIN"
fi

# ------------------------------------------------------------------ env contract file
# Written to $HOME (ext4) rather than into the repo on /mnt/d: a login shell must not
# depend on a Windows drive being mounted, and drvfs stats on every shell start are
# a real, if small, tax. The repo owns the *content* — this file is generated, never
# hand-edited, and 03 rewrites it wholesale on every run.
ENVDIR="$HOME/.config/bioinfo"
ENVFILE="$ENVDIR/env.sh"
mkdir -p "$ENVDIR"

log "writing $ENVFILE"
cat > "$ENVFILE" <<EOF
# GENERATED by bioinfo bootstrap/03-nextflow.sh — do not edit, re-run the script.
# Sourced from ~/.bashrc. The environment contract every pipeline run assumes.

export BIOINFO_HOME="$BIOINFO_HOME_V"
export BIOINFO_REFS="$BIOINFO_REFS_V"

export JAVA_HOME="$JAVA_HOME_V"
export PATH="\$HOME/.local/bin:\$PATH"

# --- Nextflow. Every one of these is on ext4. Never point them at /mnt/*.
export NXF_HOME="$NXF_HOME_V"
export NXF_ASSETS="$NXF_ASSETS_V"
export NXF_WORK="$NXF_WORK_V"
export NXF_TEMP="$NXF_TEMP_V"

# Container image caches. Docker keeps its own store under /var/lib/docker (already on
# the ext4 VHDX); these two only matter if a pipeline is run with -profile singularity
# or apptainer, but setting them costs nothing and prevents a surprise 30 GB in \$HOME.
export NXF_SINGULARITY_CACHEDIR="$NXF_CONTAINERS_V"
export NXF_APPTAINER_CACHEDIR="$NXF_CONTAINERS_V"

# Head-JVM heap. The box has 63.5 GB; 8 GB is generous for the orchestrator and leaves
# the rest for the tasks. Raise only if the head process OOMs on a >10k-task DAG.
export NXF_OPTS="-Xms1g -Xmx8g"

# NXF_OFFLINE must stay UNSET: nf-core pipelines resolve revisions and pull containers
# on first run. Explicitly clear it in case a parent shell set it.
unset NXF_OFFLINE

# Sanity net, interactive shells only — silence in scp/rsync/non-tty sessions, where
# stray stdout output breaks the protocol.
case \$- in
  *i*)
    for __v in NXF_HOME NXF_ASSETS NXF_WORK NXF_TEMP; do
      case "\${!__v}" in
        /mnt/*) printf 'bioinfo WARNING: %s=%s is on drvfs — expect 5-10x slower I/O\n' "\$__v" "\${!__v}" >&2 ;;
      esac
    done
    unset __v
    ;;
esac
EOF
chmod 0644 "$ENVFILE"
info "written"

# Hook it into .bashrc between markers so re-runs replace rather than accumulate.
BASHRC="$HOME/.bashrc"
MARK_A='# >>> bioinfo env >>>'
MARK_B='# <<< bioinfo env <<<'
touch "$BASHRC"
if grep -qF "$MARK_A" "$BASHRC"; then
  info "~/.bashrc hook already present"
else
  {
    printf '\n%s\n' "$MARK_A"
    printf '[ -f "%s" ] && . "%s"\n' "$ENVFILE" "$ENVFILE"
    printf '%s\n' "$MARK_B"
  } >> "$BASHRC"
  info "~/.bashrc hook added"
fi

# ------------------------------------------------------------------ verify
log "verify"
# shellcheck disable=SC1090
. "$ENVFILE"

NXF_VER="$(nextflow -version 2>&1 | sed -n 's/.*version \([0-9][^ ]*\).*/\1/p' | head -1)"
if [ -z "$NXF_VER" ]; then
  nextflow -version || true
  die "nextflow -version produced nothing parseable"
fi
info "nextflow    $NXF_VER"

if command -v nf-core >/dev/null 2>&1; then
  NFC_VER="$(nf-core --version 2>&1 | head -1)"
  info "nf-core     $NFC_VER"
else
  die "nf-core not on PATH after install — check $HOME/.local/bin"
fi

info "java        $JAVA_VER_RAW"
info "docker      $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'NOT RESPONDING — run 02-docker.sh')"

echo
cat <<EOF
============================================================================
  Installed. Open a new shell (or: . $ENVFILE) to pick up the environment.

  Record these versions in every run record — nf-core CLI subcommands and
  pipeline schemas both move between majors. nf-core v3 renamed the command
  groups (e.g. 'nf-core pipelines list' where v2 had 'nf-core list'), so
  confirm against your installed version before scripting anything:

      nf-core --help
      nextflow run nf-core/rnaseq -r <rev> --help
      cat \$NXF_ASSETS/nf-core/rnaseq/assets/schema_input.json

  Next:  bash \$BIOINFO_HOME/bootstrap/04-refs.sh
============================================================================
EOF
