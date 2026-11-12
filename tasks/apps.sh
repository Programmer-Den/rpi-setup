#!/usr/bin/env bash
# Task: apps - your own web apps from container images (Docker), such as a
# static site or a game built by your repository's CI.
# Settings: APPS_* in config/rpi-setup.env (names in config/tasks/apps.env).
set -euo pipefail
. "$RPI_SETUP_ROOT/lib/containers.sh"

TASKS+=("apps|Your own web apps from container images, each with a card on the start page")

# Containers the other rpi-setup tasks run; an app cannot take their names.
apps_reserved_names='pihole samba teamspeak teamspeak-usage netalertx web den-watcher'

# apps_parse LIST - check APPS_LIST and print one "name port container-port
# image" line per app. LIST holds name:port=image entries, or
# name:port:container-port=image when the app does not listen on 8080,
# separated by spaces or commas. Dies naming the entry that is wrong. A name
# is the compose service, the container name and the card's name: lowercase
# letters, digits and -, at least two characters with a letter, so that it
# is a string to YAML (not 123, 1e3, 0x1f, true, null) and a container
# name to Docker (two characters at least), and none of the names the
# other tasks' containers have.
apps_parse() {
  local entry name ports image port cport names=" " used=" "
  local re='^([a-z0-9][a-z0-9-]{1,30}):([0-9]{1,5})(:([0-9]{1,5}))?=(.+)$'
  for entry in ${1//,/ }; do
    [[ "$entry" =~ $re ]] ||
      die "APPS_LIST entries must look like name:port=image, such as game:8091=ghcr.io/you/game:latest, with a name of at least two characters (got '$entry')"
    name="${BASH_REMATCH[1]}" port="${BASH_REMATCH[2]}" cport="${BASH_REMATCH[4]:-8080}" image="${BASH_REMATCH[5]}"
    [[ "$name" == *[a-z]* ]] ||
      die "APPS_LIST: the name '$name' needs a letter (digits alone are a number to the compose file)"
    case "$name" in
      true|false|yes|no|on|off|null)
        die "APPS_LIST: '$name' means something else to the compose file; pick another name" ;;
    esac
    [[ ! "$name" =~ ^(0x[0-9a-f]+|0o[0-7]+|0b[01]+|[0-9]+e-?[0-9]+)$ ]] ||
      die "APPS_LIST: '$name' means a number to the compose file; pick another name"
    [[ " $apps_reserved_names " != *" $name "* && "$name" != den-watcher-* ]] ||
      die "APPS_LIST: '$name' is the name of a container another rpi-setup task runs; pick another name"
    for ports in "$port" "$cport"; do
      (( 10#$ports >= 1 && 10#$ports <= 65535 )) ||
        die "APPS_LIST: the ports of '$name' must be between 1 and 65535 (got '$entry')"
    done
    [[ "$image" =~ ^[a-z0-9][a-z0-9._/:-]*(@sha256:[0-9a-f]{64})?$ ]] ||
      die "APPS_LIST: the image of '$name' must be a Docker image such as repo/name:tag (got '$image')"
    [[ "$names" != *" $name "* ]] || die "APPS_LIST names '$name' twice"
    [[ "$used" != *" $((10#$port)) "* ]] || die "APPS_LIST: port $port is used by two apps"
    names+="$name " used+="$((10#$port)) "
    printf '%s %s %s %s\n' "$name" "$((10#$port))" "$((10#$cport))" "$image"
  done
}

# apps_data_parse DATA NAMES - check APPS_DATA against the app names in
# NAMES (space separated) and print the apps that keep data, one per line.
# DATA holds app names separated by spaces or commas.
apps_data_parse() {
  local name seen=" "
  for name in ${1//,/ }; do
    [[ " $2 " == *" $name "* ]] ||
      die "APPS_DATA: '$name' is not an app in APPS_LIST; list only apps that APPS_LIST runs"
    [[ "$seen" != *" $name "* ]] || continue
    seen+="$name "
    printf '%s\n' "$name"
  done
}

# apps_compose UID [DATA] < "name port container-port image" lines - the
# compose file: one container per app, named after it, published on its port,
# with labels that give it a card on the web task's start page. Every app runs
# as UID (not root), with no capabilities, a read-only file system and only
# /tmp writable (in memory), so it keeps nothing between restarts; an app
# named in DATA (space separated) also gets its folder under DIR/data as /data.
apps_compose() {
  local uid="$1" data=" ${2:-} " name port cport image
  echo 'services:'
  while read -r name port cport image; do
    cat <<EOF2
  $name:
    image: "$image"
    container_name: $name
    restart: unless-stopped
    labels:
      rpi-setup.link.name: "$name"
      rpi-setup.link.description: "App from $image"
      rpi-setup.link.port: "$port"
    ports:
      - "0.0.0.0:$port:$cport"
    user: "$uid:$uid"
    read_only: true
    tmpfs:
      - "/tmp:mode=1700,uid=$uid,gid=$uid,rw,nosuid,nodev,noexec"
    volumes:
      - /etc/localtime:/etc/localtime:ro
EOF2
    if [[ "$data" == *" $name "* ]]; then
      printf '      - "./data/%s:/data"\n' "$name"
    fi
    cat <<EOF2
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
EOF2
  done
}

# apps_port_container PORT - prints the name of the container that publishes
# PORT (its docker-proxy holds the port); false if Docker knows none.
apps_port_container() { container_port_holder "$1"; }

run_apps() {
  local apps dir
  dir="$(container_dir apps)"
  apps="$(apps_parse "${APPS_LIST:-}")"
  if [[ -z "$apps" ]]; then
    # An emptied list takes the apps down; the compose file is renamed so
    # update.sh, the firewall and check.sh no longer see them. With none
    # running there is nothing to do: a deploy that still lists the task
    # must not fail.
    if [[ -f "$dir/docker-compose.yml" ]]; then
      docker compose -f "$dir/docker-compose.yml" down --remove-orphans ||
        die "Could not stop the apps in $dir; stop them with: cd $dir && sudo docker compose down"
      mv -f "$dir/docker-compose.yml" "$dir/docker-compose.yml.disabled"
      say 'APPS_LIST is empty: stopped the apps'
      return 0
    fi
    info 'APPS_LIST is empty and no apps are running; to run some, list them as name:port=image, such as game:8091=ghcr.io/you/game:latest'
    return 0
  fi

  # The port may already be ours (Docker's proxy for one of the apps);
  # another container's proxy or anything else holds it. Found here, not at
  # "up", which would take every app down.
  local name port cport image owner holder names=" "
  while read -r name port cport image; do names+="$name "; done <<<"$apps"
  local data
  data="$(apps_data_parse "${APPS_DATA:-}" "$names")"
  while read -r name port cport image; do
    owner="$(port_owner "$port")" || owner=""
    if [[ "$owner" == docker-proxy ]]; then
      holder="$(apps_port_container "$port")" || holder=""
      [[ -z "$holder" || " $names " == *" $holder "* ]] ||
        die "Port $port of '$name' is published by the $holder container; pick a free port in APPS_LIST"
    elif [[ -n "$owner" ]]; then
      die "Port $port of '$name' is used by $owner; pick a free port in APPS_LIST"
    fi
  done <<<"$apps"

  container_require_64bit APPS_LIST
  container_require_docker

  local uid
  uid="$(assign_uid apps)"
  install -m 0755 -d "$dir"
  # Each app that keeps data gets its own folder, only for its user. It stays
  # when the app leaves APPS_DATA or APPS_LIST; the backup task saves it with
  # the rest of $dir.
  for name in $data; do
    install -m 0700 -o "$uid" -g "$uid" -d "$dir/data/$name"
  done
  apps_compose "$uid" "${data//$'\n'/ }" <<<"$apps" | write_if_changed "$dir/docker-compose.yml" 0644 || true

  # Pulling every run brings a moving tag such as :latest up to date; "up"
  # then recreates only the apps whose image or settings changed, and
  # --remove-orphans takes down the ones no longer listed.
  container_pull "$dir"
  container_up "$dir" "$(head -n1 <<<"$apps" | cut -d' ' -f1)"
  while read -r name port cport image; do
    container_wait_stable "$name" ||
      container_fail "$dir" "$name" "The $name container does not stay up"
    say "$name is running: $(service_url "$port")"
  done <<<"$apps"
}
