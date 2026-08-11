#!/usr/bin/env bash
# 03-nextflow.sh — Nextflow + nf-core tooling + the environment contract.
# Run as the PIPELINE USER, not root:
#
#   wsl -d Ubuntu-24.04 -- bash /mnt/d/bioinfo-agent/bootstrap/03-nextflow.sh
#
# Flags:  --update   also self-update an existing Nextflow and upgrade nf-core
#         --help
#
# Idempotent. Re-running rewrites the env file and re-verifies; it does not reinstall.
#
# CRLF guard — see the long comment in 01-wsl-base.sh. Trailing `#` swallows the CR.
if [ -z "${BIOINFO_CRLF_REEXEC:-}" ] && grep -q $'\r' "$0" 2>/dev/null; then export BIOINFO_CRLF_REEXEC=1 BIOINFO_BOOTSTRAP_DIR="$(cd "$(dirname "$0")" && pwd)"; exec bash <(tr -d '\r' < "$0") "$@"; fi  # CRLF self-heal
set -euo pipefail

SELFDIR="${BIOINFO_BOOTSTRAP_DIR:-$(cd "$(dirname "$0")" && pwd)}"
unset BIOINFO_CRLF_REEXEC BIOINFO_BOOTSTRAP_DIR   # this script only — see 01-wsl-base.sh

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
# config/host.env — per-machine overrides, read before every default below so the values
# here are genuine fallbacks. Parsed, not sourced: host.env is gitignored and world-
# writable on drvfs, so it must never execute. load_host_env always returns 0, so a
# malformed host.env cannot take the bootstrap down.
HOST_ENV="${BIOINFO_HOME:-/mnt/d/bioinfo-agent}/config/host.env"
. "$SELFDIR/lib/host-env.sh"      # parses; never executes host.env
load_host_env "$HOST_ENV"

BIOINFO_HOME_V="${BIOINFO_HOME:-/mnt/d/bioinfo-agent}"
BIOINFO_REFS_V="${BIOINFO_REFS:-/refs}"
WORK_ROOT="${BIOINFO_WORK:-/work}"
BIOINFO_RUNS_V="${BIOINFO_RUNS:-/runs}"
BIOINFO_RUNLOG_V="${BIOINFO_RUNLOG:-$BIOINFO_HOME_V/runs}"

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
info "BIOINFO_RUNS  = $BIOINFO_RUNS_V   (legacy reserve; not an active --outdir)"
info "BIOINFO_RUNLOG= $BIOINFO_RUNLOG_V   (run record + copied deliverables; drvfs on purpose)"
info "NXF_HOME      = $NXF_HOME_V"
info "NXF_ASSETS    = $NXF_ASSETS_V"
info "NXF_WORK      = $NXF_WORK_V"
info "NXF_TEMP      = $NXF_TEMP_V"

for d in "$NXF_HOME_V" "$NXF_ASSETS_V" "$NXF_WORK_V" "$NXF_TEMP_V" "$NXF_CONTAINERS_V" \
         "$BIOINFO_RUNS_V" "$BIOINFO_RUNLOG_V" "$HOME/.local/bin"; do
  if ! mkdir -p "$d" 2>/dev/null; then
    die "cannot create $d — check ownership. Root should have run: install -d -o $USER -g $USER $(dirname "$d")"
  fi
done

# Publish the COMPUTED values into this script's own environment, here, before anything
# spawns a child. load_host_env() above exported whatever NXF_* config/host.env carries, and
# those are not necessarily these: an older or hand-edited host.env may carry an
# NXF_TEMP this script never created. The nextflow installer below reads NXF_TEMP from the
# environment and mktemp's in it — an inherited path this script never created fails the
# download with a misleading "Cannot download nextflow required file / check your internet".
# Only the directories created in the loop above are guaranteed to exist, so only the values
# that named them may reach a child.
export NXF_HOME="$NXF_HOME_V" \
       NXF_ASSETS="$NXF_ASSETS_V" \
       NXF_WORK="$NXF_WORK_V" \
       NXF_TEMP="$NXF_TEMP_V" \
       NXF_SINGULARITY_CACHEDIR="$NXF_CONTAINERS_V" \
       NXF_APPTAINER_CACHEDIR="$NXF_CONTAINERS_V"

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
#
# `curl https://get.nextflow.io | bash` was what this used to do. On a host that
# bootstrap/06-tls-trust.sh exists to fix — get.nextflow.io is the exact domain that was
# found intercepted here — piping an unauthenticated response straight into a shell is
# the worst available option. Download first, check what landed, then run it.
#
# WHAT THIS DOES AND DOES NOT GUARANTEE. It catches a truncated or empty download, a
# response that is not a shell script at all (a proxy login page, an error blob), and a
# launcher whose version is not the one pinned. It does NOT establish authenticity: the
# project publishes no checksum for the installer, so a middlebox that can rewrite the
# response can also serve a valid-looking launcher reporting the pinned version. The only
# real defence is a digest obtained out of band — set BIOINFO_NXF_SHA256 to one and this
# enforces it.
log "nextflow"
NXF_BIN="$HOME/.local/bin/nextflow"
NXF_PIN="${BIOINFO_NXF_VERSION:-24.10.5}"     # move the pin in config/host.env
NXF_SHA="${BIOINFO_NXF_SHA256:-}"             # sha256 of the get.nextflow.io installer

if [ -x "$NXF_BIN" ]; then
  info "already installed at $NXF_BIN"
  if [ "$DO_UPDATE" -eq 1 ]; then
    info "self-updating"
    JAVA_HOME="$JAVA_HOME_V" NXF_HOME="$NXF_HOME_V" "$NXF_BIN" self-update
  fi
else
  # The official installer writes ./nextflow into $PWD. Do it in a scratch dir so a
  # failed download cannot leave a stray launcher in whatever directory we were called
  # from (which, on a bad day, is /mnt/d/bioinfo-agent).
  TMPD="$(mktemp -d)"
  trap 'rm -rf "$TMPD"' EXIT

  info "downloading get.nextflow.io installer (pinning nextflow $NXF_PIN)"
  curl -fsSL -o "$TMPD/install.sh" https://get.nextflow.io \
    || die "could not download the installer. If curl reported a certificate problem, run bootstrap/06-tls-trust.sh."

  [ -s "$TMPD/install.sh" ] || die "downloaded installer is empty"
  head -1 "$TMPD/install.sh" | grep -q '^#!.*sh' \
    || die "downloaded installer is not a shell script — first bytes: $(head -c 80 "$TMPD/install.sh" | tr -d '\n')"

  if [ -n "$NXF_SHA" ]; then
    GOT_SHA="$(sha256sum "$TMPD/install.sh" | awk '{print $1}')"
    [ "$GOT_SHA" = "$NXF_SHA" ] \
      || die "installer sha256 mismatch. expected $NXF_SHA, got $GOT_SHA — do not proceed"
    info "installer sha256 matches BIOINFO_NXF_SHA256"
  else
    info "BIOINFO_NXF_SHA256 unset — the download is sanity-checked, NOT authenticated"
  fi

  # `bash < install.sh`, NOT `bash install.sh` — and this is not a style choice.
  # get.nextflow.io serves ONE script that is both the installer and the nextflow launcher.
  # It picks a mode by inspecting $0:
  #
  #     if [ "$0" = "bash" ] || [[ "$0" =~ .*/bash ]]; then   # ... install ...
  #
  # Redirecting the file on stdin leaves $0 as "bash", which is the install branch and what
  # the upstream `curl -s https://get.nextflow.io | bash` recipe actually relies on. Passing
  # the file as an argument makes $0 "install.sh", which silently takes the LAUNCHER branch:
  # it prints nextflow's help, exits 0, and creates no launcher at all. Verified all three
  # forms on Ubuntu 22.04 — only the stdin and pipe forms produce ./nextflow.
  # Feeding it on stdin from a file we have already downloaded and checksummed keeps the
  # download-verify-then-execute ordering that piping straight from curl gives up.
  ( cd "$TMPD" && JAVA_HOME="$JAVA_HOME_V" NXF_VER="$NXF_PIN" bash < install.sh ) \
    || die "nextflow installer failed — check network, and that NXF_OFFLINE is not set"
  [ -x "$TMPD/nextflow" ] || die "installer exited 0 but left no ./nextflow launcher"

  # `|| true`: pipefail would otherwise abort here silently on a failed -v, and the case
  # below gives a far better message than a bare exit.
  GOT_VER="$(JAVA_HOME="$JAVA_HOME_V" NXF_HOME="$NXF_HOME_V" NXF_VER="$NXF_PIN" \
             "$TMPD/nextflow" -v 2>&1 | sed -n 's/.*version \([0-9][^ ]*\).*/\1/p' | head -1 || true)"
  # -v reports the build too (24.10.5.5928), so match on the pin as a prefix.
  case "$GOT_VER" in
    "$NXF_PIN"|"$NXF_PIN".*) info "launcher reports $GOT_VER — matches the pin" ;;
    *) die "launcher reports '$GOT_VER', pin is $NXF_PIN. Set BIOINFO_NXF_VERSION to move the pin deliberately." ;;
  esac

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
  info "already installed: $(nf-core --version 2>&1 | grep -E '[0-9]+\.[0-9]+' | tail -1 | sed 's/^[[:space:]]*//')"
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

# The ext4 scratch root. config/local.config and the skill both compose per-run work
# directories as \$BIOINFO_WORK/<run-id>, so this MUST be exported — an unset value
# expands to nothing and -work-dir becomes /<run-id>, i.e. a write attempt at /.
export BIOINFO_WORK="$WORK_ROOT"

# Legacy ext4 results root, retained for existing host.env files. Active --outdir
# lives under \${NXF_WORKROOT:-\${BIOINFO_WORK:-/work}/nxf}/<run-id>/results;
# never compose a launch path from BIOINFO_RUNS. BIOINFO_RUNLOG holds the run
# record and copied deliverables.
export BIOINFO_RUNS="$BIOINFO_RUNS_V"
export BIOINFO_RUNLOG="$BIOINFO_RUNLOG_V"

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

# config/local.config states in two places that it REQUIRES the v1 config parser, because it
# mixes top-level \`def\` with config blocks and v2 rejects that. Nothing was actually setting
# it: it worked only because v1 is still the default. Pin it, so the day the default flips the
# failure is not "every run aborts at config-parse time" with no clue why.
export NXF_SYNTAX_PARSER=v1

# These two used to live only in config/host.env, on the theory that a login shell would
# source that file. It does not: the hook this script installs in .bashrc sources THIS
# file and nothing else, so both were unset in every shell a run was launched from —
# measured on this host, \`NXF_ANSI_LOG=UNSET NXF_DISABLE_CHECK_LATEST=UNSET\` in a fresh
# login shell despite host.env setting both. The launch template passes -ansi-log false
# explicitly so the log stayed readable, but every nextflow invocation was still making
# the phone-home version check. Written here, where the contract actually reaches a run.
export NXF_ANSI_LOG=false
export NXF_DISABLE_CHECK_LATEST=true

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

# Machine-local additions this script must not clobber. 03 rewrites env.sh wholesale on
# every run, so anything appended to env.sh is lost at the next run; env.local.sh is the
# place for it. bootstrap/06-tls-trust.sh writes the certifi/Python trust vars there.
# Sourced last so it can override anything above.
[ -f "$ENVDIR/env.local.sh" ] && . "$ENVDIR/env.local.sh"

# Set last, so the .bashrc / .profile guards can tell "already loaded" from "never loaded".
# Both files carry the hook because non-interactive login shells read .profile but bail out
# of Ubuntu's stock .bashrc before reaching its end.
export BIOINFO_ENV_LOADED=1
EOF
chmod 0644 "$ENVFILE"
info "written"

# Hook the contract into BOTH ~/.bashrc and ~/.profile, between markers so re-runs replace
# rather than accumulate.
#
# ~/.bashrc alone is not enough, and the failure is silent. Ubuntu's stock .bashrc opens with
#
#     case $- in *i*) ;; *) return;; esac
#
# so a NON-INTERACTIVE shell returns before ever reaching a hook appended at the end. That is
# precisely how this stack gets driven: `wsl -d Ubuntu-24.04 -- bash -lc '<cmd>'` is a login
# shell but not an interactive one. Every variable would come back unset, -work-dir would
# expand to /<run-id>, and $BIOINFO_REFS paths would resolve to nothing — with no error saying
# why. ~/.profile IS read by non-interactive login shells, so the hook must live there too.
#
# Guard against double-sourcing since .profile also sources .bashrc for interactive shells.
MARK_A='# >>> bioinfo env >>>'
MARK_B='# <<< bioinfo env <<<'

for rc in "$HOME/.bashrc" "$HOME/.profile"; do
  touch "$rc"
  if grep -qF "$MARK_A" "$rc"; then
    info "$(basename "$rc") hook already present"
  else
    {
      printf '\n%s\n' "$MARK_A"
      printf '[ -z "${BIOINFO_ENV_LOADED:-}" ] && [ -f "%s" ] && . "%s"\n' "$ENVFILE" "$ENVFILE"
      printf '%s\n' "$MARK_B"
    } >> "$rc"
    info "$(basename "$rc") hook added"
  fi
done

# ------------------------------------------------------------------ verify
log "verify"
# shellcheck disable=SC1090
. "$ENVFILE"

NXF_VER="$( { nextflow -version 2>&1 || true; } | sed -n 's/.*version \([0-9][^ ]*\).*/\1/p' | head -1)"
if [ -z "$NXF_VER" ]; then
  nextflow -version || true
  die "nextflow -version produced nothing parseable"
fi
info "nextflow    $NXF_VER"

if command -v nf-core >/dev/null 2>&1; then
  NFC_VER="$( { nf-core --version 2>&1 || true; } | grep -E '[0-9]+\.[0-9]+' | tail -1 | sed 's/^[[:space:]]*//')"
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
      find \$NXF_ASSETS -path '*nf-core/rnaseq*' -name schema_input.json | head -1

  Next:  bash \$BIOINFO_HOME/bootstrap/04-refs.sh
============================================================================
EOF
