#!/usr/bin/env bash
# Task: pihole - network-wide ad blocking via the official installer.
# Settings: PIHOLE_* in config/rpi-setup.env (names in config/tasks/pihole.env).
set -euo pipefail
. "$RPI_SETUP_ROOT/lib/containers.sh"

TASKS+=("pihole|Pi-hole ad blocker (official installer, unattended)")

# Pi-hole's configuration file (pre-seeded before the native install).
PH_TOML="${PH_TOML:-/etc/pihole/pihole.toml}"

run_pihole() {
  : "${PIHOLE_DNS:=1.1.1.1,1.0.0.1}" "${PIHOLE_QUERY_LOGGING:=yes}" "${PIHOLE_DOCKER:=no}"
  setting_on PIHOLE_QUERY_LOGGING || true
  [[ -z "${PIHOLE_LISTEN_ALL:-}" ]] || setting_on PIHOLE_LISTEN_ALL || true
  [[ -z "${PIHOLE_WEB_PORT:-}" ]] || require_port PIHOLE_WEB_PORT
  pihole_db_interval >/dev/null
  local -a dns=()
  pihole_dns_list dns
  local iface
  if setting_on PIHOLE_DOCKER; then
    iface="$(pihole_iface)"
    run_pihole_container "$iface" "${dns[@]}"
    return
  fi
  container_leave pihole

  if command -v pihole >/dev/null 2>&1; then
    say "Pi-hole is already installed (run 'pihole -d' to debug)"
    pihole_apply_web_port
    pihole_apply_listening
    pihole_apply_db_interval
    if [[ -n "${PIHOLE_PASSWORD:-}" ]]; then
      pihole setpassword "$PIHOLE_PASSWORD" >/dev/null
      say 'Set the web admin password from PIHOLE_PASSWORD'
    fi
    say "Web admin: $(pihole_admin_url)"
    return
  fi
  warn 'The Pi-hole installer is downloaded from https://install.pi-hole.net and run as root (like "curl ... | bash").'
  warn 'Review it there first, or set PIHOLE_DOCKER=yes to run Pi-hole from its image instead.'

  if in_container; then
    warn 'Pi-hole needs port 53 and is not supported in container environments; skipping'
    return
  fi

  iface="$(pihole_iface)"
  pihole_preseed "$iface" "${dns[@]}"
  info 'Running the official Pi-hole installer unattended (settings from config/rpi-setup.env)'
  # Saved to a file first, so a download cut short never runs half a script
  # and the log records exactly which script ran.
  local installer
  installer="$(mktemp)"
  curl -fsSL -o "$installer" https://install.pi-hole.net ||
    { rm -f "$installer"; die 'Could not download the Pi-hole installer from https://install.pi-hole.net; check the network and re-run'; }
  info "Pi-hole installer SHA-256: $(sha256sum "$installer" | cut -d' ' -f1)"
  bash "$installer" --unattended || { rm -f "$installer"; die 'The Pi-hole installer failed; see its output above'; }
  rm -f "$installer"

  if ! command -v pihole >/dev/null 2>&1; then
    warn 'Pi-hole installer did not complete'
    return
  fi
  pihole_apply_web_port
  pihole_apply_listening
  pihole_apply_db_interval

  local pw="${PIHOLE_PASSWORD:-}"
  if [[ -z "$pw" ]]; then new_secret pw pihole PIHOLE_PASSWORD 'web admin password' 16; fi
  pihole setpassword "$pw" >/dev/null
  say "Pi-hole installed - web admin: $(pihole_admin_url)"
}

# Interface Pi-hole listens on: PIHOLE_INTERFACE, else the default route's.
pihole_iface() {
  local iface="${PIHOLE_INTERFACE:-}"
  if [[ -z "$iface" ]]; then
    iface="$(default_iface)" || die 'Could not detect the network interface; set PIHOLE_INTERFACE (e.g. eth0)'
  fi
  [[ -d "/sys/class/net/$iface" ]] || die "PIHOLE_INTERFACE: no network interface '$iface' on this Pi"
  printf '%s\n' "$iface"
}

# Split PIHOLE_DNS ("1.1.1.1,1.0.0.1", commas or spaces) into array $1.
pihole_dns_list() {
  local -n _dns_list="$1"
  local _dns
  read -r -a _dns_list <<<"${PIHOLE_DNS//,/ }"
  [[ ${#_dns_list[@]} -gt 0 ]] || die 'PIHOLE_DNS needs at least one upstream DNS server'
  for _dns in "${_dns_list[@]}"; do
    pihole_valid_upstream "$_dns" ||
      die "PIHOLE_DNS: '$_dns' is not an IPv4 or IPv6 address (with an optional #port, e.g. 1.1.1.1#5353)"
  done
}

# True if $1 is an upstream for Pi-hole: an IPv4 or IPv6 address, with an
# optional "#port" (1-65535) as Pi-hole writes it.
pihole_valid_upstream() {
  local ip="${1%%#*}" port
  if [[ "$1" == *#* ]]; then
    port="${1#*#}"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
  fi
  valid_ipv4 "$ip" || pihole_valid_ipv6 "$ip"
}

# True if $1 is an IPv6 address: hex groups of 1-4 digits, eight of them, or
# fewer with one "::" standing for the rest.
pihole_valid_ipv6() {
  local ip="$1" groups
  [[ "$ip" =~ ^[0-9A-Fa-f:]+$ && "$ip" == *:* && "$ip" != *:::* ]] || return 1
  [[ ! "$ip" =~ [0-9A-Fa-f]{5} ]] || return 1
  [[ "$ip" != :* || "$ip" == ::* ]] || return 1
  [[ "$ip" != *: || "$ip" == *:: ]] || return 1
  read -r -a groups <<<"${ip//:/ }"
  if [[ "$ip" == *::* ]]; then
    [[ "${ip/::/}" != *::* ]] || return 1
    (( ${#groups[@]} <= 7 ))
  else
    (( ${#groups[@]} == 8 ))
  fi
}

# A pihole.toml before installing makes the installer run without dialogs
# ("unattended" needs an existing config); Pi-hole fills in everything else.
# Arguments: the interface, then the upstream DNS servers.
pihole_preseed() {
  local iface="$1" ups="" d log=false port="${PIHOLE_WEB_PORT:-}"
  shift
  for d in "$@"; do ups+="${ups:+, }\"$d\""; done
  if setting_on PIHOLE_QUERY_LOGGING; then log=true; fi
  if [[ -z "$port" ]] && port_owner 80 >/dev/null; then port=8080; fi

  install -m 0755 -d "${PH_TOML%/*}"
  {
    echo '# Pre-seeded by rpi-setup (tasks/pihole.sh); Pi-hole manages this file from here on.'
    echo '[dns]'
    echo "  upstreams = [ $ups ]"
    echo "  interface = \"$iface\""
    echo "  queryLogging = $log"
    if [[ -n "$port" ]]; then
      echo '[webserver]'
      echo "  port = \"$(pihole_port_setting "$PH_DEFAULT_PORTS" "$port")\""
    fi
    echo '[database]'
    echo "  DBinterval = $(pihole_db_interval)"
  } >"$PH_TOML"
  info "Pre-seeded $PH_TOML (interface $iface, upstream DNS ${*})"
}

# Move the admin UI to PIHOLE_WEB_PORT if it is set and differs; the HTTPS
# listener (443) stays as it is.
pihole_apply_web_port() {
  local want="${PIHOLE_WEB_PORT:-}" cur new owner
  [[ -n "$want" ]] || return 0
  cur="$(pihole-FTL --config webserver.port 2>/dev/null)" || cur=""
  new="$(pihole_port_setting "$cur" "$want")"
  [[ "$cur" != "$new" ]] || return 0
  owner="$(port_owner "$want")" || owner=""
  if [[ -n "$owner" && "$owner" != pihole-FTL ]]; then
    die "PIHOLE_WEB_PORT=$want is already used by '$owner'; pick another port"
  fi
  pihole-FTL --config webserver.port "$new" >/dev/null
  systemctl restart pihole-FTL || true
  say "Pi-hole web admin moved to port $want"
}

# Pi-hole's DNS listening mode from PIHOLE_LISTEN_ALL (ALL: any network, e.g.
# the tailnet; LOCAL: only the local subnets). Empty: leave it as it is.
pihole_listening_mode() {
  [[ -n "${PIHOLE_LISTEN_ALL:-}" ]] || return 0
  if setting_on PIHOLE_LISTEN_ALL; then echo ALL; else echo LOCAL; fi
}

# Seconds between Pi-hole's writes of new queries to its database on the SD
# card, from PIHOLE_DB_INTERVAL (Pi-hole's own default is 60). The web UI
# shows the newest queries from memory either way; a power cut loses at most
# this many seconds of the query log.
pihole_db_interval() {
  local s="${PIHOLE_DB_INTERVAL:-300}"
  if [[ ! "$s" =~ ^[1-9][0-9]{0,3}$ ]] || (( s < 60 || s > 3600 )); then
    die "PIHOLE_DB_INTERVAL must be a number of seconds from 60 to 3600 (got '$s')"
  fi
  printf '%s\n' "$s"
}

pihole_apply_db_interval() {
  local want cur
  want="$(pihole_db_interval)"
  cur="$(pihole-FTL --config database.DBinterval 2>/dev/null)" || cur=""
  [[ "$cur" != "$want" ]] || return 0
  pihole-FTL --config database.DBinterval "$want" >/dev/null
  systemctl restart pihole-FTL || true
  say "Pi-hole now writes new queries to its database every $want seconds"
}

pihole_apply_listening() {
  local want cur
  want="$(pihole_listening_mode)"
  [[ -n "$want" ]] || return 0
  cur="$(pihole-FTL --config dns.listeningMode 2>/dev/null)" || cur=""
  [[ "$cur" != "$want" ]] || return 0
  pihole-FTL --config dns.listeningMode "$want" >/dev/null
  systemctl restart pihole-FTL || true
  say "Pi-hole now answers DNS queries from: $([[ $want == ALL ]] && echo 'any network' || echo 'local subnets only')"
}

# Pi-hole v6 serves its admin UI from pihole-FTL, on port 80 unless another
# web server (e.g. the "web" task's nginx) holds it, then on 8080.
pihole_admin_url() { printf '%s/admin\n' "$(service_url "$(pihole_web_ports | head -n1)")"; }

# PIHOLE_DOCKER=yes: Pi-hole's official image on the host network (port 53
# and the real client addresses), with /etc/pihole in /opt/pihole/etc-pihole.
# The PIHOLE_* settings are passed as FTLCONF_* variables, so they apply on
# every run (Pi-hole shows them read-only in its web UI). A native Pi-hole is
# stopped and its /etc/pihole (lists, settings, password) copied once.
# Arguments: the interface, then the upstream DNS servers.
run_pihole_container() {
  : "${PIHOLE_IMAGE:=pihole/pihole:latest}"
  require_image_ref PIHOLE_IMAGE
  container_require_64bit PIHOLE_DOCKER
  local iface="$1" port="${PIHOLE_WEB_PORT:-}" name=pihole dir owner="" changed=0 p
  shift
  container_require_docker
  dir="$(container_dir pihole)"

  # Admin port: PIHOLE_WEB_PORT, else the one used so far, else 80, or 8080
  # when another web server (the web task's nginx) holds 80.
  if [[ -z "$port" ]]; then
    port="$(sed -nE 's/^ *FTLCONF_webserver_port: "([0-9]+)o.*/\1/p' "$dir/docker-compose.yml" 2>/dev/null || true)"
    if [[ -z "$port" ]] && have pihole-FTL; then port="$(pihole_web_ports | head -n1)"; fi
    if [[ -z "$port" ]]; then
      port=80
      owner="$(port_owner 80)" || owner=""
      [[ -z "$owner" || "$owner" == pihole-FTL ]] || port=8080
    fi
  fi
  for p in 53 "$port"; do
    owner="$(port_owner "$p")" || owner=""
    [[ -z "$owner" || "$owner" == pihole-FTL ]] ||
      die "Port $p is already used by '$owner'; Pi-hole needs it (set PIHOLE_WEB_PORT for the admin port)"
  done

  install -m 0755 -d "$dir" "$dir/etc-pihole"
  # Compose reads secrets.env when it parses the file, so it must exist
  # before the pull, even when the password is only known later.
  [[ -f "$dir/secrets.env" ]] || install -m 0600 /dev/null "$dir/secrets.env"
  if pihole_container_compose "$dir" "$name" "$iface" "$port" "$@" | write_if_changed "$dir/docker-compose.yml" 0644; then changed=1; fi
  container_pull "$dir"
  # The native Pi-hole is stopped before its /etc/pihole is copied, so the
  # databases are not copied while FTL writes them (the copy happens once);
  # container_up starts it again if the container does not stay up.
  container_stop_native "$dir" pihole-FTL
  container_copy_once "$dir" /etc/pihole "$dir/etc-pihole" || true

  local pw="${PIHOLE_PASSWORD:-}"
  # No password set: keep the one Pi-hole already has (copied from the native
  # install or set by an earlier run), else generate one.
  if [[ -z "$pw" ]] && ! grep -Eq '^[[:space:]]*pwhash[[:space:]]*=[[:space:]]*"[^"]+' "$dir/etc-pihole/pihole.toml" 2>/dev/null; then
    # Print and save it now: once the container has started, pihole.toml
    # holds its hash and a later run would not show it again.
    new_secret pw pihole PIHOLE_PASSWORD 'web admin password' 16
  fi
  if [[ -n "$pw" ]]; then
    if container_write_secrets "$dir" "FTLCONF_webserver_api_password=$pw"; then changed=1; fi
  fi

  container_up "$dir" "$name" "$changed"
  say "Pi-hole container running - web admin: $(service_url "$port")/admin (DNS on port 53, interface $iface)"
}

# Compose file of the Pi-hole container: folder $1, container name $2,
# interface $3, admin port $4, then the upstream DNS servers. Pi-hole starts
# as root and drops to its own user, so it keeps Docker's default
# capabilities (plus SYS_NICE) instead of the minimal set the others get.
pihole_container_compose() {
  local dir="$1" name="$2" iface="$3" port="$4" ups="" log=false mode tz interval
  shift 4
  interval="$(pihole_db_interval)"
  ups="$(IFS=';'; printf '%s' "$*")"
  if setting_on PIHOLE_QUERY_LOGGING; then log=true; fi
  mode="$(pihole_listening_mode)"
  tz="$(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"
  cat <<EOF
services:
  pihole:
    image: "$PIHOLE_IMAGE"
    container_name: $name
    hostname: "$(hostname)"
    restart: unless-stopped
    network_mode: host
    pids_limit: 512
    cap_add:
      - SYS_NICE
    env_file: ./secrets.env
    environment:
      TZ: "$tz"
      FTLCONF_dns_upstreams: "$ups"
      FTLCONF_dns_interface: "$iface"
      FTLCONF_dns_queryLogging: "$log"
      FTLCONF_webserver_port: "$(pihole_port_setting "$PH_DEFAULT_PORTS" "$port")"
      FTLCONF_database_DBinterval: "$interval"
$([[ -z "$mode" ]] || printf '      FTLCONF_dns_listeningMode: "%s"\n' "$mode")
    volumes:
      - $dir/etc-pihole:/etc/pihole
EOF
}
