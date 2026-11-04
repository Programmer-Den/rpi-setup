#!/usr/bin/env bash
# Task: teamspeak - TeamSpeak 6 voice chat server (official Docker image, native arm64).
# Settings: TEAMSPEAK_* in config/rpi-setup.env (names in config/tasks/teamspeak.env).
set -euo pipefail
. "$RPI_SETUP_ROOT/lib/containers.sh"

TASKS+=("teamspeak|TeamSpeak 6 voice server (voice :9987, file :30033, web :10080)")

# teamspeak_server_port DIR FRESH PORT - print the UDP port the server listens
# on inside the container and record it in DIR/voice-port. TSSERVER_DEFAULT_PORT
# only sets the port of the first virtual server when its database is created;
# after that the server keeps that port. So a new server (FRESH=1) takes PORT
# and an existing one keeps the recorded port. A server set up before the port
# was recorded falls back to TSSERVER_DEFAULT_PORT in DIR/docker-compose.yml
# (what it was started with), else 9987.
teamspeak_server_port() {
  local file="$1/voice-port" fresh="$2" port="$3"
  if [[ "$fresh" -ne 1 ]]; then
    if [[ -f "$file" ]]; then
      port="$(tr -d '[:space:]' <"$file")"
    else
      port="$(sed -n 's/^ *TSSERVER_DEFAULT_PORT: *"\{0,1\}\([0-9]*\)"\{0,1\} *$/\1/p' \
        "$1/docker-compose.yml" 2>/dev/null | tail -n1)"
      port="${port:-9987}"
    fi
    if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
      die "$file must hold the server's voice port (got '$port'); fix or delete it"
    fi
  fi
  printf '%s\n' "$port" | write_if_changed "$file" 0644 || true
  printf '%s\n' "$port"
}

run_teamspeak() {
  : "${TEAMSPEAK_VOICE_PORT:=9987}" "${TEAMSPEAK_FILE_PORT:=30033}" "${TEAMSPEAK_QUERY_PORT:=10080}"
  : "${TEAMSPEAK_QUERY_HTTP:=no}" "${TEAMSPEAK_ACCEPT_LICENSE:=yes}"
  : "${TEAMSPEAK_IMAGE:=teamspeaksystems/teamspeak6-server:latest}"
  : "${TEAMSPEAK_USAGE:=yes}" "${TEAMSPEAK_USAGE_DAYS:=90}" "${TEAMSPEAK_USAGE_CONNECTIONS:=no}"
  : "${TEAMSPEAK_PUBLIC_ADDRESS:=}" "${TEAMSPEAK_PUBLIC_PORT:=${TEAMSPEAK_VOICE_PORT}}"
  require_port TEAMSPEAK_VOICE_PORT
  require_port TEAMSPEAK_PUBLIC_PORT
  require_port TEAMSPEAK_FILE_PORT
  require_port TEAMSPEAK_QUERY_PORT
  require_image_ref TEAMSPEAK_IMAGE
  local query="" query_port="" admin_pw="${TEAMSPEAK_QUERY_ADMIN_PASSWORD:-}"
  # A set TSSERVER_QUERY_HTTP_ENABLED may count as "on" whatever its value,
  # so "no" leaves the variable out instead of setting it to false. Without
  # the query API its port is not published either, so it is closed.
  if setting_on TEAMSPEAK_QUERY_HTTP; then
    query='      TSSERVER_QUERY_HTTP_ENABLED: "true"'
    query_port="      - \"${TEAMSPEAK_QUERY_PORT}:${TEAMSPEAK_QUERY_PORT}/tcp\"   # Web query"
  fi
  setting_on TEAMSPEAK_ACCEPT_LICENSE ||
    die 'The TeamSpeak server only starts once you accept its license; set TEAMSPEAK_ACCEPT_LICENSE=yes'
  [[ "$admin_pw" != *[\"\\\$]* ]] ||
    die 'TEAMSPEAK_QUERY_ADMIN_PASSWORD cannot contain ", \ or $'
  local usage=0 connections=no
  if setting_on TEAMSPEAK_USAGE; then usage=1; fi
  if setting_on TEAMSPEAK_USAGE_CONNECTIONS; then connections=yes; fi
  if ! [[ "$TEAMSPEAK_USAGE_DAYS" =~ ^[0-9]{1,4}$ ]] || (( 10#$TEAMSPEAK_USAGE_DAYS < 1 )); then
    die "TEAMSPEAK_USAGE_DAYS must be a number of days from 1 to 9999 (got '$TEAMSPEAK_USAGE_DAYS')"
  fi
  local public
  public="$(teamspeak_public_address "$TEAMSPEAK_PUBLIC_ADDRESS")" ||
    die "TEAMSPEAK_PUBLIC_ADDRESS must be a host name or IP address, or no (got '$TEAMSPEAK_PUBLIC_ADDRESS')"

  # The official image is published for amd64 and arm64 only, so a Pi on a
  # 32-bit OS (armhf) cannot run it.
  local arch
  arch="$(dpkg --print-architecture)"
  [[ "$arch" == arm64 || "$arch" == amd64 ]] ||
    die "The TeamSpeak 6 image needs a 64-bit OS (this one is $arch). Flash Raspberry Pi OS Lite (64-bit)."

  container_require_docker

  local dir name=teamspeak ip=""
  dir="$(container_dir teamspeak)"

  # The usage logger logs in to the SSH query as serveradmin, so that account
  # needs a password: a generated one unless TEAMSPEAK_QUERY_ADMIN_PASSWORD is
  # set. The SSH query port is not published; the logger reaches it over the
  # compose network.
  # A password generated earlier stays in use when the logger is turned off,
  # since the server keeps it.
  local usage_service="" ssh_query=""
  if [[ -z "$admin_pw" ]]; then admin_pw="$(load_secret teamspeak TEAMSPEAK_QUERY_ADMIN_PASSWORD)" || admin_pw=""; fi
  if [[ $usage -eq 1 ]]; then
    if [[ -z "$admin_pw" ]]; then
      new_secret admin_pw teamspeak TEAMSPEAK_QUERY_ADMIN_PASSWORD 'serveradmin query password'
    fi
    ssh_query='      TSSERVER_QUERY_SSH_ENABLED: "true"'
    usage_service="$(teamspeak_usage_service "$dir" "$TEAMSPEAK_USAGE_DAYS" "$admin_pw" \
      "$TEAMSPEAK_VOICE_PORT" "$public" "$TEAMSPEAK_PUBLIC_PORT" "$connections")"
  fi

  # The official image runs as uid:gid 9987 and ignores PUID/PGID, so the data
  # directory must stay owned by 9987 for the bind mount to be writable.
  install -m 0755 -d "$dir" "$dir/data"
  chown 9987:9987 "$dir/data"

  # The privilege key is only printed when the server creates its database.
  local fresh=0 token="" inner
  [[ -n "$(ls -A "$dir/data" 2>/dev/null)" ]] || fresh=1
  inner="$(teamspeak_server_port "$dir" "$fresh" "$TEAMSPEAK_VOICE_PORT")"

  # The file transfer and query ports are the same inside and outside:
  # TeamSpeak tells clients which file transfer port to use, so the two must
  # match. The voice port inside stays the one the server was created with
  # and TEAMSPEAK_VOICE_PORT is published on the host. The query password is
  # in secrets.env (root only), which both services read with env_file.
  # The image runs as 9987 from the start and its ports are unprivileged, so
  # the server needs no capability and no privilege escalation.
  local changed=0 secrets=0
  if [[ -n "$admin_pw" ]]; then
    container_write_secrets "$dir" "TSSERVER_QUERY_ADMIN_PASSWORD=$admin_pw" "TS_QUERY_PASSWORD=$admin_pw" && secrets=1
  elif [[ -f "$dir/secrets.env" ]]; then
    rm -f "$dir/secrets.env"
    secrets=1
  fi
  local env_file=""
  [[ -z "$admin_pw" ]] || env_file=$'    env_file: ./secrets.env'
  if write_if_changed "$dir/docker-compose.yml" 0600 <<EOF
services:
  teamspeak:
    image: "$TEAMSPEAK_IMAGE"
    container_name: $name
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
${env_file}
    ports:
      - "${TEAMSPEAK_VOICE_PORT}:${inner}/udp"   # Voice
      - "${TEAMSPEAK_FILE_PORT}:${TEAMSPEAK_FILE_PORT}/tcp"     # File transfer
${query_port}
    environment:
      TSSERVER_LICENSE_ACCEPTED: "accept"
      TSSERVER_DEFAULT_PORT: "${inner}"
      TSSERVER_FILE_TRANSFER_PORT: "${TEAMSPEAK_FILE_PORT}"
      TSSERVER_QUERY_HTTP_PORT: "${TEAMSPEAK_QUERY_PORT}"
${query}
${ssh_query}
    volumes:
      - type: bind
        source: $dir/data
        target: /var/tsserver
${usage_service}
EOF
  then
    changed=1
  fi

  container_pull "$dir"
  if [[ $usage -eq 1 ]]; then
    info 'Building the TeamSpeak usage logger image'
    docker compose -f "$dir/docker-compose.yml" build --pull --quiet usage ||
      die 'Could not build the TeamSpeak usage logger; check the network, or set TEAMSPEAK_USAGE=no'
  fi
  local started
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Compose does not notice a changed secrets.env, so recreate then.
  container_up "$dir" "$name" "$secrets"
  if [[ $usage -eq 1 ]]; then
    # The logger retries on its own when it cannot log in, so look for its
    # "Connected" line rather than only whether the container stays up: one
    # from this run, since a container that was not recreated keeps the
    # lines of earlier logins in its log.
    if ! container_wait_stable teamspeak-usage; then
      warn 'The TeamSpeak usage logger does not stay up; see: sudo docker logs teamspeak-usage'
    elif [[ -z "$(teamspeak_wait_log teamspeak-usage 'Connected;' 30 "$started")" ]]; then
      warn 'The TeamSpeak usage logger could not log in to the server query yet; see: sudo docker logs teamspeak-usage'
    fi
  fi

  ip="$(pi_ip)" || true
  if [[ $fresh -eq 0 ]]; then
    if [[ "$inner" != "$TEAMSPEAK_VOICE_PORT" ]]; then
      info "Host UDP port ${TEAMSPEAK_VOICE_PORT} forwards to the server's own voice port ${inner} (fixed when it was created)."
    fi
    if [[ $changed -eq 1 ]]; then
      say "TeamSpeak 6 restarted with the new settings at ${ip:-<pi-ip>}:${TEAMSPEAK_VOICE_PORT}"
    else
      say "TeamSpeak 6 is running with these settings. Connect to ${ip:-<pi-ip>}:${TEAMSPEAK_VOICE_PORT}"
    fi
    return
  fi
  wait_for_log "$name" 'token=' >/dev/null
  token="$(teamspeak_token "$name")"

  say "TeamSpeak 6 server ready at ${ip:-<pi-ip>}:${TEAMSPEAK_VOICE_PORT} (file transfer :${TEAMSPEAK_FILE_PORT}, web query :${TEAMSPEAK_QUERY_PORT})"
  if [[ -n "$token" ]]; then
    say "ServerAdmin privilege key (needed for first login, shown only once):"
    printf '  %s\n' "$token"
  else
    warn "Could not spot the ServerAdmin privilege key in the logs yet."
    say "Find it later with: sudo docker logs $name 2>&1 | grep -A6 'privilege key'"
  fi
  say "Connect with the TeamSpeak 6 client and enter the privilege key when asked."
}

# TEAMSPEAK_PUBLIC_ADDRESS $1 as the usage logger takes it: empty (look up the
# public IP), "no" (for no, off, false or 0) or a host name or IP address.
# Returns 1 for anything else.
teamspeak_public_address() {
  case "${1,,}" in
    no|off|false|0) echo no ;;
    *) [[ -z "$1" || "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.:-]{0,252})$ ]] || return 1
       printf '%s\n' "$1" ;;
  esac
}

# Copy the usage logger (templates/teamspeak-usage) to DIR/usage and print the
# compose service that runs it, keeping DAYS days of visits, with the
# serveradmin password PW (from secrets.env; only checked here), the voice
# port VOICE on the Pi and, for the start page, the internet address PUBLIC
# (see teamspeak_public_address) with its port PUBLIC_PORT, and with
# CONNECTIONS=yes the "Same connection" list. Its data folder gets its own UID.
teamspeak_usage_service() {
  local dir="$1" days="$2" pw="$3" voice="${4:-9987}" public="${5:-}" public_port="${6:-${4:-9987}}" connections="${7:-no}"
  [[ -n "$pw" ]] || die 'teamspeak_usage_service: the query password is missing'
  local src="$RPI_SETUP_ROOT/templates/teamspeak-usage" uid
  uid="$(assign_uid teamspeak-usage)"
  # The data folder holds visitors' IP addresses: the logger's user and root
  # only (the web task's timer copies usage.json as root).
  install -m 0755 -d "$dir/usage"
  install -m 0700 -d "$dir/usage/data"
  chown "$uid:$uid" "$dir/usage/data"
  write_if_changed "$dir/usage/Dockerfile" 0644 <"$src/Dockerfile" || true
  write_if_changed "$dir/usage/tsusage.py" 0755 <"$src/tsusage.py" || true
  cat <<EOF
  usage:
    build:
      context: ./usage
      args:
        UID: "$uid"
    container_name: teamspeak-usage
    restart: unless-stopped
    depends_on:
      - teamspeak
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    env_file: ./secrets.env
    environment:
      TS_HOST: teamspeak
      USAGE_DAYS: "$((10#$days))"
      TS_CONNECTIONS: "$connections"
      TS_VOICE_PORT: "$((10#$voice))"
      TS_PUBLIC_ADDRESS: "$public"
      TS_PUBLIC_PORT: "$((10#$public_port))"
    volumes:
      - type: bind
        source: $dir/usage/data
        target: /data
EOF
}

# Like wait_for_log (lib/common.sh): the last line of container $1's log
# matching $2, waiting up to $3 seconds (default 30) for it, but only among
# the lines logged since $4 (a UTC time as date +%Y-%m-%dT%H:%M:%SZ prints
# it), so a line from an earlier run does not count.
teamspeak_wait_log() {
  local name="$1" pattern="$2" tries="${3:-30}" since="$4" i line=""
  for i in $(seq 1 "$tries"); do
    line="$(docker logs --since "$since" "$name" 2>&1 | grep -i "$pattern" | tail -n1)" || true
    [[ -n "$line" ]] && break
    sleep 1
  done
  printf '%s\n' "$line"
}

# The ServerAdmin privilege key from container $1's log. The server prints it a
# few lines below its "privilege key created" banner, as token=<key>.
teamspeak_token() {
  docker logs "$1" 2>&1 | grep -oE 'token=[^[:space:]]+' | tail -n1 | cut -d= -f2-
  return 0
}
