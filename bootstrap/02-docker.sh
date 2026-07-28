#!/usr/bin/env bash
# 02-docker.sh — Docker engine inside the WSL distro. Run as root.
#
# Docker *engine*, not Docker Desktop: no licence question, no GUI overhead, and the
# daemon lives inside the distro so its data-root is already on whatever drive the
# distro's ext4.vhdx sits on. Nothing to relocate.
set -euo pipefail

log() { printf '\n[02-docker] %s\n' "$*"; }

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  log "docker already up: $(docker version --format '{{.Server.Version}}')"
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

TARGET_USER="${BIOINFO_USER:-ehojune}"
if id "$TARGET_USER" >/dev/null 2>&1; then
  log "adding $TARGET_USER to docker group"
  usermod -aG docker "$TARGET_USER"
fi

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
docker run --rm hello-world >/dev/null 2>&1 && echo "  hello-world OK" || echo "  hello-world FAILED"
log "done"
