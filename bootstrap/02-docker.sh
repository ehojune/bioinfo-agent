#!/usr/bin/env bash
# 02-docker.sh — Docker engine inside the WSL distro. Run as root.
#
# Docker *engine*, not Docker Desktop: no licence question, no GUI overhead, and the
# daemon lives inside the distro so its data-root is already on whatever drive the
# distro's ext4.vhdx sits on. Nothing to relocate.
set -euo pipefail

# config/host.env — per-machine overrides, sourced before the defaults so BIOINFO_USER
# here is a genuine fallback and the docker group cannot land on the wrong account.
# Parsed, not sourced: host.env is gitignored and sits on 0777 drvfs, and this runs as root.
HOST_ENV="${BIOINFO_HOME:-/mnt/d/bioinfo-agent}/config/host.env"
. "$(dirname "$0")/lib/host-env.sh"      # parses; never executes host.env
load_host_env "$HOST_ENV"

TARGET_USER="${BIOINFO_USER:-ehojune}"

log() { printf '\n[02-docker] %s\n' "$*"; }

# Runs on both paths below. Docker group membership is root access: the socket runs as
# root and 'docker run -v /:/host' rewrites the whole filesystem. 01-wsl-base.sh
# discloses this alongside the sudoers drop-in.
ensure_docker_group() {
  id "$TARGET_USER" >/dev/null 2>&1 || { log "user $TARGET_USER does not exist — skipping docker group"; return 0; }
  if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
    log "$TARGET_USER already in the docker group"
  else
    log "adding $TARGET_USER to the docker group (root-equivalent — see 01-wsl-base.sh)"
    usermod -aG docker "$TARGET_USER"
  fi
}

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  log "docker already up: $(docker version --format '{{.Server.Version}}')"
  ensure_docker_group
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive

log "adding docker apt repository"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
  "$(dpkg --print-architecture)" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list

log "installing packages"
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

ensure_docker_group

# systemd is enabled via /etc/wsl.conf in 01-wsl-base.sh. If the distro was not restarted
# after that, PID 1 is still wsl-init and systemctl will not work — fall back to dockerd.
if [ "$(ps -p 1 -o comm=)" = "systemd" ]; then
  log "starting docker via systemd"
  systemctl enable --now docker
else
  log "systemd not PID 1 (distro needs 'wsl --terminate'); starting dockerd directly"
  (dockerd >/var/log/dockerd.log 2>&1 &)
fi

for _ in $(seq 1 30); do
  docker info >/dev/null 2>&1 && break
  sleep 1
done

log "verifying"
echo "  pid1       = $(ps -p 1 -o comm=)"
echo "  server     = $(docker version --format '{{.Server.Version}}')"
echo "  data-root  = $(docker info --format '{{.DockerRootDir}}')"
# A failed verification is a failed script. Exiting 0 here made 02 look successful to
# anything chaining the bootstrap steps together, with no working container runtime.
RC=0
if docker run --rm hello-world >/dev/null 2>&1; then
  echo "  hello-world OK"
else
  echo "  hello-world FAILED — check: journalctl -u docker -n 50, or /var/log/dockerd.log"
  RC=1
fi
log "done"
exit "$RC"
