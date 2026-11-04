#!/usr/bin/env bash
# Task: docker - Docker Engine, buildx and compose as apt-packaged plugins.
# Settings: DOCKER_* in config/rpi-setup.env (names in config/tasks/docker.env).
set -euo pipefail

TASKS+=("docker|Docker Engine and Docker Compose")

run_docker() {
  : "${DOCKER_ADD_USER:=yes}"
  setting_on DOCKER_ADD_USER || true

  if command -v docker >/dev/null 2>&1; then
    if ! docker compose version >/dev/null 2>&1; then
      # Docker from another source (e.g. Debian's docker.io) without Compose v2.
      info 'Docker is installed but the Compose plugin is missing; installing it'
      apt_install docker-compose-plugin 2>/dev/null || apt_install docker-compose ||
        die 'Could not install Docker Compose. Remove the existing Docker packages and re-run: sudo bash setup.sh docker'
      docker compose version >/dev/null 2>&1 || die 'Docker Compose is still unavailable after installing it.'
    fi
    say "Docker is already installed ($(docker --version 2>/dev/null || true))"
  else
    docker_install
  fi

  local restart=0
  if docker_daemon_config; then restart=1; fi
  systemctl enable --now docker || warn 'Docker installed but service not started; run "systemctl enable --now docker" after reboot or re-login.'
  if [[ $restart -eq 1 ]] && systemctl is-active --quiet docker; then
    # Containers with a restart policy come back by themselves.
    systemctl restart docker || warn 'Could not restart Docker to apply /etc/docker/daemon.json'
  fi

  local u
  u="$(real_user)"
  if setting_on DOCKER_ADD_USER && [[ -n "$u" && "$u" != root ]]; then
    if id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
      say "'$u' is already in the docker group"
    else
      usermod -aG docker "$u"
      say "Added '$u' to the docker group (re-login to use it)"
    fi
  fi

  if systemctl is-active --quiet docker; then
    docker --version
    docker compose version
  else
    warn "Docker service not running; skipping version check"
  fi
}

docker_install() {
  local os_id vcode arch
  os_id=$( . /etc/os-release && echo "$ID" ) || true
  vcode=$( . /etc/os-release && echo "$VERSION_CODENAME" ) || true
  arch=$(dpkg --print-architecture)
  if [[ -z "$os_id" || -z "$vcode" ]]; then
    die "Could not determine OS release (ID='${os_id}', VERSION_CODENAME='${vcode}'). Docker's apt repo needs both."
  fi

  apt_install ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  local key
  key="$(mktemp)"
  curl -fsSL -o "$key" "https://download.docker.com/linux/${os_id}/gpg" ||
    { rm -f "$key"; die "Could not download Docker's signing key from https://download.docker.com/linux/${os_id}/gpg; check the network and re-run"; }
  # Only Docker's own release key may sign the packages that run as root.
  if ! docker_key_ok "$key"; then
    rm -f "$key"
    die "The key from download.docker.com is not Docker's release key ($docker_key_fpr); nothing was installed"
  fi
  gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg <"$key"
  rm -f "$key"
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${os_id} ${vcode} stable" >/etc/apt/sources.list.d/docker.list

  apt_update_now
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_DPKG_OPTS[@]}" docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# Fingerprint of Docker's apt release key (docs.docker.com/engine/install/debian).
docker_key_fpr=9DC858229FC7DD38854AE2D88D81803C0EBFCD88

# True if key file $1 holds exactly one primary key: Docker's release key.
docker_key_ok() {
  local fprs
  fprs="$(gpg --batch --show-keys --with-colons "$1" 2>/dev/null | awk -F: '$1 == "pub" { p = 1; next } $1 == "fpr" && p { print $10; p = 0 }')" || return 1
  [[ "$fprs" == "$docker_key_fpr" ]]
}

# Log rotation for every container (3 files of 10 MB), so logs cannot fill
# the SD card. JSON has no comments, so a copy of what we wrote marks
# /etc/docker/daemon.json as ours; a daemon.json edited by hand is left
# alone. Returns 0 if it changed.
docker_daemon_config() {
  local f=/etc/docker/daemon.json copy=/var/lib/rpi-setup/docker-daemon.json
  if [[ -f "$f" ]] && ! { [[ -f "$copy" ]] && cmp -s "$f" "$copy"; }; then
    warn "$f was not written by rpi-setup; leaving it alone (container log rotation not applied)"
    return 1
  fi
  install -m 0755 -d /etc/docker /var/lib/rpi-setup
  if printf '{\n  "log-driver": "json-file",\n  "log-opts": {\n    "max-size": "10m",\n    "max-file": "3"\n  }\n}\n' |
      write_if_changed "$f" 0644; then
    cp -f "$f" "$copy"
    say "Container logs rotate at 10m x 3 ($f)"
    return 0
  fi
  return 1
}
