#!/usr/bin/env bash
# Shared helpers for rpi-setup.
set -euo pipefail

# Repository root (the directory holding setup.sh, lib/, tasks/ and config/).
RPI_SETUP_ROOT="${RPI_SETUP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

readonly C_RESET=$'\033[0m'
readonly C_RED=$'\033[31m'
readonly C_GREEN=$'\033[32m'
readonly C_YELLOW=$'\033[33m'
readonly C_CYAN=$'\033[36m'

say()  { printf '%s[+]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
info() { printf '%s[*]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
hr()   { printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '-'; }

# The user who invoked setup (resolves properly through sudo).
real_user() { printf '%s' "${SUDO_USER:-${USER:-root}}"; }

# Board model string, e.g. "Raspberry Pi 5 Model B Rev 1.0" (empty off a Pi).
# RPI_SETUP_MODEL_FILE lets the unit tests pretend to be a given board.
pi_model() {
  local f="${RPI_SETUP_MODEL_FILE:-/proc/device-tree/model}"
  [[ -r "$f" ]] || return 0
  tr -d '\0' <"$f"
}

# Loose Raspberry Pi detection (also true when an OS image boots on similar arm boards).
is_pi() { [[ "$(pi_model)" == *[Rr]aspberry* ]]; }

# True on the BCM2712 boards: Pi 5, Pi 500 and Compute Module 5.
is_pi5() { [[ "$(pi_model)" =~ Raspberry\ Pi\ (5|500|Compute\ Module\ 5) ]]; }

# The firmware's config.txt: /boot/firmware since Bookworm, /boot before.
boot_config_file() {
  if [[ -f /boot/firmware/config.txt ]]; then
    printf '%s\n' /boot/firmware/config.txt
  elif [[ -f /boot/config.txt ]]; then
    printf '%s\n' /boot/config.txt
  else
    return 1
  fi
}

# Replace rpi-setup's block at the end of config.txt ($1) with the lines on
# stdin (no lines removes the block). Returns 0 if the file changed.
boot_config_block() {
  local conf="$1" body new
  body="$(cat)"
  if [[ -z "$body" ]] && ! grep -q '^# BEGIN rpi-setup$' "$conf"; then return 1; fi
  new="$(awk '/^# BEGIN rpi-setup$/ {skip = 1} !skip {print} /^# END rpi-setup$/ {skip = 0}' "$conf")"
  if [[ -n "$body" ]]; then
    new+=$'\n# BEGIN rpi-setup\n# Managed by rpi-setup (config/base.env); re-run "setup.sh base" to change.\n[all]\n'
    new+="$body"$'\n# END rpi-setup'
  fi
  printf '%s\n' "$new" | write_if_changed "$conf"
}

# True inside a container (systemd-nspawn, Docker, ...) rather than on real hardware.
in_container() { [[ -f /run/systemd/container ]] || grep -q 'container' /proc/1/cgroup 2>/dev/null; }

# Dies unless run as root; $1 names the command to repeat with sudo (default:
# setup.sh).
need_root() { [[ $EUID -eq 0 ]] || die "Please run as root: sudo bash ${1:-setup.sh [task ...]}"; }

# True when this run came in over the network (SSH), so a change to the
# address or to sshd can end it. sudo's env_reset strips SSH_CONNECTION, so
# logind and "who -m" (which shows the remote host in parentheses) are asked
# as well.
remote_session() {
  [[ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ]] && return 0
  [[ "$(loginctl show-session self -p Remote --value 2>/dev/null)" == yes ]] && return 0
  [[ "$(who -m 2>/dev/null)" == *'('*')'* ]]
}

# True if command $1 is available.
have() { command -v "$1" >/dev/null 2>&1; }

# True if systemd unit $1 exists on this system (installed, whatever its
# state). A bare name is a service; give "name.timer" for a timer.
unit_exists() {
  local unit="$1"
  [[ "$unit" == *.* ]] || unit+=.service
  [[ -n "$(systemctl list-unit-files --no-legend "$unit" 2>/dev/null)" ]]
}

# Refresh apt lists at most once an hour per run. The stamp file records the
# last refresh; RPI_SETUP_APT_STAMP moves it (the unit tests).
apt_update() {
  local stamp="${RPI_SETUP_APT_STAMP:-/var/lib/rpi-setup/apt-updated}"
  if [[ ! -f "$stamp" ]] ||
     [[ $(( $(date +%s) - $(stat -c %Y "$stamp") )) -gt 3600 ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y
    install -m 0755 -d "$(dirname "$stamp")"
    touch "$stamp"
  fi
}

# Refresh apt lists now, ignoring the hourly cache. Needed right after adding
# an apt source: lists fetched a minute ago (e.g. by "base") don't know it yet.
apt_update_now() {
  rm -f "${RPI_SETUP_APT_STAMP:-/var/lib/rpi-setup/apt-updated}"
  apt_update
}

# Never stop at a dpkg "configuration file modified" prompt: keep the local
# version when one exists, take the package default otherwise.
APT_DPKG_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

apt_install() {
  apt_update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_DPKG_OPTS[@]}" "$@"
}

apt_installed() { dpkg -s "$1" >/dev/null 2>&1; }

# --- Networking helpers ------------------------------------------------

# First LAN IP of this host, or non-zero exit (and empty output) if none.
pi_ip() {
  local ip
  ip="$(hostname -I 2>/dev/null || true)"
  [[ -n "$ip" ]] || return 1
  printf '%s\n' "$ip" | awk '{print $1}'
}

# URL of a web UI on this Pi at TCP port $1 ("" or 80 is left out of the
# URL): on the LAN address (else the host name), or on localhost when its
# bind address $2 is 127.0.0.1 or localhost.
service_url() {
  local port="$1" bind="${2:-}" host
  if [[ "$bind" == 127.0.0.1 || "$bind" == localhost ]]; then
    host=localhost
  else
    host="$(pi_ip)" || host="$(hostname)"
  fi
  if [[ -z "$port" || "$port" == 80 ]]; then
    printf 'http://%s\n' "$host"
  else
    printf 'http://%s:%s\n' "$host" "$port"
  fi
}

# Name of the process listening on TCP $1 (e.g. "nginx", "pihole-FTL"), or
# non-zero exit if nothing listens there.
port_owner() {
  local port="$1" line
  line="$(ss -H -ltnp "sport = :$port" 2>/dev/null | head -n1)" || true
  [[ -n "$line" ]] || return 1
  if [[ "$line" =~ users:\(\(\"([^\"]+)\" ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf 'unknown\n'
  fi
}

# Interface of the default route, e.g. "eth0" or "wlan0".
default_iface() {
  local iface
  iface="$(ip route show default 2>/dev/null | awk '
    /^default/ { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
  [[ -n "$iface" ]] || return 1
  printf '%s\n' "$iface"
}

# Detect the LAN network + interface from the default route, e.g. "192.168.1.0/24 --interface=eth0".
detect_subnet() {
  local iface cidr
  iface="$(default_iface)" || return 1
  # The kernel's own route for the interface's network (e.g. 192.168.1.0/24).
  cidr="$(ip -4 -o route show dev "$iface" proto kernel scope link 2>/dev/null | awk '{print $1; exit}')"
  [[ -n "$cidr" ]] || return 1
  printf '%s --interface=%s' "$cidr" "$iface"
}

# True if $1 is a dotted IPv4 address: four numbers 0-255 without leading
# zeros (tools disagree whether 010 means 8 or 10).
valid_ipv4() {
  local ip="$1" o
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  for o in ${ip//./ }; do
    [[ "$o" == 0 || "$o" != 0* ]] || return 1
    (( o <= 255 )) || return 1
  done
}

# --- Docker task helpers -----------------------------------------------

# Die with a helpful message if Docker and the Compose plugin are missing.
require_docker() {
  have docker || die 'Docker is required. Run first: sudo bash setup.sh docker'
  docker compose version >/dev/null 2>&1 || die 'Docker Compose is required. Run first: sudo bash setup.sh docker'
}

# Folder of task $1's compose project. RPI_SETUP_CONTAINER_ROOT moves it (tests).
container_dir() { printf '%s/%s\n' "${RPI_SETUP_CONTAINER_ROOT:-/opt}" "$1"; }

# True if task $1 runs in its own container (<TASK>_DOCKER=yes): it has a
# compose file in /opt/<task> and Docker knows a container of that name.
# Switching the task back to native removes the container, so this turns false.
task_in_container() {
  [[ -f "$(container_dir "$1")/docker-compose.yml" ]] || return 1
  have docker || return 1
  docker inspect --type container "$1" >/dev/null 2>&1
}

# Run pihole-FTL with arguments "$@" where Pi-hole runs: in its container
# (PIHOLE_DOCKER=yes) or on the host.
pihole_ftl() {
  if task_in_container pihole; then docker exec pihole pihole-FTL "$@"
  else pihole-FTL "$@"
  fi
}

# Ports of Pi-hole's admin web server in the order configured, one per line,
# from its "80o,443os,[::]:80o" style setting. Prints nothing when Pi-hole
# cannot be asked.
pihole_web_ports() {
  local cfg e
  cfg="$(pihole_ftl --config webserver.port 2>/dev/null)" || return 0
  for e in ${cfg//,/ }; do
    e="${e##*:}"
    e="${e%%[!0-9]*}"
    [[ -z "$e" ]] || printf '%s\n' "$e"
  done | awk '!seen[$0]++'
}

# Pi-hole's own webserver.port: HTTP on 80 and HTTPS on 443, IPv4 and IPv6
# ("o" = optional, so a taken port does not stop FTL; "s" = TLS).
PH_DEFAULT_PORTS='80o,443os,[::]:80o,[::]:443os'

# Pi-hole's webserver.port list $1 without its HTTPS entries (flag "s"), so
# its admin page keeps plain HTTP and leaves 443 to another program.
pihole_without_tls() {
  local e out=""
  for e in ${1//,/ }; do
    [[ "$e" =~ ^(.*:)?[0-9]+[A-Za-z]*$ && "${e##*[0-9]}" == *s* ]] && continue
    out+="${out:+,}$e"
  done
  printf '%s\n' "$out"
}

# The webserver.port list Pi-hole starts from: PH_DEFAULT_PORTS, without the
# HTTPS entries when the DATA-DEN gateway (the dataden task) has port 443.
pihole_default_ports() {
  if [[ -f "$(container_dir dataden)/docker-compose.yml" ]]; then
    pihole_without_tls "$PH_DEFAULT_PORTS"
  else
    printf '%s\n' "$PH_DEFAULT_PORTS"
  fi
}

# Pi-hole's webserver.port list $1 with every plain HTTP entry moved to
# port $2; the TLS entries ("s" flag, the admin UI's HTTPS listener on 443)
# keep their port. A list without an HTTP entry gets $2 for IPv4 and IPv6
# in front. Entries look like [address:]port[flags].
pihole_port_setting() {
  local cfg="$1" want="$2" e out="" http=0
  for e in ${cfg//,/ }; do
    if [[ "$e" =~ ^(.*:)?([0-9]+)([A-Za-z]*)$ && "${BASH_REMATCH[3]}" != *s* ]]; then
      e="${BASH_REMATCH[1]}${want}${BASH_REMATCH[3]}"
      http=1
    fi
    out+="${out:+,}$e"
  done
  (( http )) || out="${want}o,[::]:${want}o${out:+,$out}"
  printf '%s\n' "$out"
}

# Grep container logs until a pattern matches (default: 30 tries, 1s apart).
# Prints the last matching line, or the empty string on timeout.
wait_for_log() {
  local name="$1" pattern="$2" tries="${3:-30}" i line=""
  for i in $(seq 1 "$tries"); do
    line="$(docker logs "$name" 2>&1 | grep -i "$pattern" | tail -1)" || true
    [[ -n "$line" ]] && break
    sleep 1
  done
  printf '%s\n' "$line"
}

# Find an unused UID/GID >= 10000 that isn't a system account and hasn't been
# assigned to another rpi-setup service. Returns the first available ID.
find_free_uid() {
  local start=10000 used=""
  install -m 0755 -d /var/lib/rpi-setup/uids
  used="$(cat /var/lib/rpi-setup/uids/* 2>/dev/null || true)"
  while getent passwd "$start" >/dev/null 2>&1 ||
        getent group "$start" >/dev/null 2>&1 ||
        grep -qx "$start" <<<"$used"; do
    start=$((start + 1))
  done
  printf '%s\n' "$start"
}

# Assign (or recall) a stable UID/GID for a named service, persisted under
# /var/lib/rpi-setup/uids/. Re-runs reuse the same ID so container data keeps a
# consistent owner and services never collide.
assign_uid() {
  local name="$1"
  local file="/var/lib/rpi-setup/uids/$name" uid
  if [[ -r "$file" ]] && [[ "$(<"$file")" =~ ^[0-9]+$ ]]; then
    uid="$(<"$file")"
    if ! getent passwd "$uid" >/dev/null 2>&1 &&
       ! getent group "$uid" >/dev/null 2>&1; then
      printf '%s\n' "$uid"
      return
    fi
    warn "Stored UID $uid for $name is now owned by a system account; reassigning."
  fi
  uid="$(find_free_uid)"
  printf '%s\n' "$uid" >"$file"
  printf '%s\n' "$uid"
}

# --- Task settings ------------------------------------------------------
#
# config/rpi-setup.env.example  every setting with its default (committed)
# config/rpi-setup.env          your copy with your values (git-ignored)
# config/tasks/<task>.env       names of the settings each task reads (committed)
# config/local/<task>.env       split_config's output, read by setup.sh (git-ignored)
#
# On the Pi the two files can live in /etc/rpi-setup instead (root only,
# outside the git checkout); setup.sh --move-config puts them there.

# The system settings folder; RPI_SETUP_SYSTEM_CONFIG_DIR only exists for tests.
system_config_dir() { printf '%s\n' "${RPI_SETUP_SYSTEM_CONFIG_DIR:-/etc/rpi-setup}"; }

# Folder holding rpi-setup.env and local/: RPI_SETUP_CONFIG_DIR if set, else
# /etc/rpi-setup once it holds rpi-setup.env, else config/ in the checkout.
config_dir() {
  if [[ -n "${RPI_SETUP_CONFIG_DIR:-}" ]]; then
    printf '%s\n' "$RPI_SETUP_CONFIG_DIR"
  elif [[ -f "$(system_config_dir)/rpi-setup.env" ]]; then
    system_config_dir
  else
    printf '%s\n' "$RPI_SETUP_ROOT/config"
  fi
}

# True when the settings live in the root-only system folder.
config_is_system() { [[ "$(config_dir)" == "$(system_config_dir)" ]]; }

# The central settings file.
central_config() { printf '%s/rpi-setup.env\n' "$(config_dir)"; }

# The value part of a KEY=value line: surrounding whitespace, a matching pair
# of quotes and a trailing " # comment" are removed; "NAME=   # comment" is
# an empty value. Nothing is expanded, so $, backticks and backslashes reach
# the task literally. Quote a value that contains " #" or starts with #; a
# value with a double quote in it goes in single quotes.
config_value() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  [[ "$v" != '#'* ]] || v=''
  if [[ "$v" =~ ^\"([^\"]*)\"[[:space:]]*(#.*)?$ ]] || [[ "$v" =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return
  fi
  v="${v%%[[:space:]]#*}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

# Quote $1 so config_value reads it back unchanged.
config_quote() {
  local v="$1"
  if [[ "$v" != *\'* ]]; then
    printf "'%s'" "$v"
  elif [[ "$v" != *\"* ]]; then
    printf '"%s"' "$v"
  else
    die "A setting value cannot contain both ' and \" (a password?); pick another."
  fi
}

# Call "$2 LINE_NO KEY VALUE" for every KEY=value line of file $1; comments
# and blank lines are skipped. A malformed line dies naming its number only,
# since the line itself may hold a password.
config_each() {
  local file="$1" fn="$2" line n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] ||
      die "$file, line $n: expected KEY=value"
    "$fn" "$n" "${BASH_REMATCH[2]}" "$(config_value "${BASH_REMATCH[3]}")"
  done <"$file"
}

# Warn if file $1 holds a non-empty password or token and other users can
# read it.
config_warn_perms() {
  local file="$1" mode
  mode="$(stat -c %a "$file" 2>/dev/null)" || return 0
  [[ "$mode" =~ ^[0-7]+$ ]] && (( 8#$mode & 077 )) || return 0
  if grep -Eq '^[[:space:]]*(export[[:space:]]+)?[A-Z0-9_]*(PASSWORD|TOKEN)=[[:space:]]*[^[:space:]#]' "$file"; then
    warn "$file holds a password but other users can read it; run: chmod 600 $file"
  fi
}

# The setting names task $1 reads, from config/tasks/<task>.env, one per line.
task_setting_names() {
  local file="$RPI_SETUP_ROOT/config/tasks/$1.env"
  [[ -f "$file" ]] || return 0
  sed -nE 's/^[[:space:]]*([A-Z][A-Z0-9_]*)=.*/\1/p' "$file"
}

# The split files in config/local/ are only ever written from the central
# file, so when that file is gone they are left over from an earlier run and
# would keep its values in force. Warn and have load_task_config ignore them
# (every task then uses its defaults). setup.sh calls this when the central
# file is missing. Returns 0 either way.
_LOCAL_CONFIG_STALE=0
ignore_stale_local_config() {
  local dir
  dir="$(config_dir)/local"
  [[ -n "$(ls "$dir"/*.env 2>/dev/null)" ]] || return 0
  _LOCAL_CONFIG_STALE=1
  warn "$(central_config) does not exist, but $dir still holds settings split from it; they are ignored and every task uses its defaults."
  warn "Delete $dir, or create the file again with: bash setup.sh --init-config"
}

# Read task $1's settings from $2 (default: config/local/<task>.env) into
# shell variables. Only keys named <TASK>_... are accepted, so a settings file
# can never change PATH or another task's settings. A variable that is already
# set (e.g. "sudo SAMBA_PASSWORD=... bash setup.sh samba") wins over the file.
# A missing file is fine: every setting has a default.
load_task_config() {
  local task="$1" file="${2:-}"
  if [[ -z "$file" ]]; then
    [[ $_LOCAL_CONFIG_STALE -eq 0 ]] || return 0
    file="$(config_dir)/local/$task.env"
  fi
  [[ -f "$file" ]] || return 0
  [[ -r "$file" ]] || die "Cannot read $file"
  config_warn_perms "$file"
  info "Loading settings from $file"
  _LOAD_TASK="$task" _LOAD_FILE="$file"
  config_each "$file" _load_setting
}
_load_setting() {
  local n="$1" key="$2" value="$3" prefix="${_LOAD_TASK^^}_"
  [[ "$key" == "$prefix"* ]] ||
    die "$_LOAD_FILE, line $n: '$key' is not a setting of the $_LOAD_TASK task (they all start with $prefix)"
  [[ -n "${!key+x}" ]] && return 0
  printf -v "$key" '%s' "$value"
}

# Split the central file $1 (default: config/rpi-setup.env) into one file per
# task under config/local/, each listing every name from config/tasks/<task>.env
# with its value (empty = the task's default). An unknown name in the central
# file stops the split, so a typo never goes unnoticed. The output is private
# (0600) and owned by the invoking user.
split_config() {
  local central="${1:-}"
  [[ -n "$central" ]] || central="$(central_config)"
  local out tpl task key u
  [[ -f "$central" ]] || die "$central not found. Create it with: bash setup.sh --init-config"
  config_warn_perms "$central"
  out="$(config_dir)/local"
  declare -gA _SPLIT_VALUES=() _SPLIT_KNOWN=()
  _SPLIT_FILE="$central"
  for tpl in "$RPI_SETUP_ROOT"/config/tasks/*.env; do
    [[ -f "$tpl" ]] || continue
    while IFS= read -r key; do _SPLIT_KNOWN[$key]=1; done < <(task_setting_names "$(basename "$tpl" .env)")
  done
  config_each "$central" _split_setting

  u="$(real_user)"
  config_is_system && u=root
  install -m 0700 -d "$out"
  for tpl in "$RPI_SETUP_ROOT"/config/tasks/*.env; do
    [[ -f "$tpl" ]] || continue
    task="$(basename "$tpl" .env)"
    {
      printf '# Generated from %s by split_config - edit that file instead.\n' "$central"
      while IFS= read -r key; do
        printf '%s=%s\n' "$key" "$(config_quote "${_SPLIT_VALUES[$key]:-}")"
      done < <(task_setting_names "$task")
    } | write_if_changed "$out/$task.env" 0600 || true
  done
  if [[ $EUID -eq 0 && "$u" != root ]] && id "$u" >/dev/null 2>&1; then
    chown -R "$u:$(id -gn "$u")" "$out"
  fi
  say "Split $central into $out/<task>.env"
}

# Settings that were removed (fixed values or removed tasks). A central file
# copied from an older example still has them, so they only warn.
RETIRED_SETTINGS=' BASE_FAIL2BAN_MAXRETRY BASE_FAIL2BAN_BANTIME BASE_AUTO_REBOOT_TIME DOCKER_LOG_MAX_SIZE DOCKER_LOG_MAX_FILE PIHOLE_CONFIRM PIHOLE_UNATTENDED '
# The tailscale and monitoring tasks were removed (they need outside accounts).
RETIRED_SETTINGS+='TAILSCALE_DOCKER TAILSCALE_IMAGE TAILSCALE_AUTHKEY TAILSCALE_HOSTNAME TAILSCALE_SSH TAILSCALE_ADVERTISE_EXIT_NODE TAILSCALE_ADVERTISE_ROUTES TAILSCALE_ACCEPT_DNS MONITORING_PORT MONITORING_BIND MONITORING_TELEMETRY MONITORING_DOCKER MONITORING_IMAGE '
# Prefixes of renamed tasks' settings, old=new: the usagecontrol task is now
# denwatcher. A central file with the old names keeps working, with a warning.
RENAMED_SETTINGS='USAGECONTROL_=DENWATCHER_'
_split_setting() {
  local n="$1" key="$2" value="$3" pair to
  for pair in $RENAMED_SETTINGS; do
    [[ "$key" == "${pair%%=*}"* ]] || continue
    to="${pair#*=}${key#"${pair%%=*}"}"
    [[ -n "${_SPLIT_KNOWN[$to]+x}" ]] || break
    warn "$_SPLIT_FILE, line $n: '$key' is now called '$to'; rename the line"
    # The new name wins when the file has both.
    [[ -n "${_SPLIT_VALUES[$to]+x}" ]] && return 0
    key="$to"
    break
  done
  if [[ -z "${_SPLIT_KNOWN[$key]+x}" && "$RETIRED_SETTINGS" == *" $key "* ]]; then
    warn "$_SPLIT_FILE, line $n: '$key' is no longer a setting and is ignored; delete the line"
    return 0
  fi
  [[ -n "${_SPLIT_KNOWN[$key]+x}" ]] ||
    die "$_SPLIT_FILE, line $n: unknown setting '$key' (see config/rpi-setup.env.example for the names)"
  config_quote "$value" >/dev/null
  _SPLIT_VALUES[$key]="$value"
}

# Create config/rpi-setup.env from the example unless it already exists:
# private (0600) and owned by the invoking user, since passwords go in it.
init_config() {
  local dst u
  dst="$(central_config)"
  u="$(real_user)"
  if [[ -e "$dst" ]]; then
    info "Keeping existing $dst"
  else
    if config_is_system; then
      u=root
      install -m 0700 -d "$(dirname "$dst")"
    else
      install -m 0755 -d "$(dirname "$dst")"
    fi
    install -m 0600 "$RPI_SETUP_ROOT/config/rpi-setup.env.example" "$dst"
    if [[ $EUID -eq 0 && "$u" != root ]] && id "$u" >/dev/null 2>&1; then
      chown "$u:$(id -gn "$u")" "$dst"
    fi
    say "Created $dst"
  fi
  say "Fill in $dst, then run: sudo bash setup.sh <task ...>"
}

# Move config/rpi-setup.env out of the git checkout into /etc/rpi-setup
# (root, 0600) and drop the split files next to it; setup.sh, update.sh and
# check.sh find it there from then on. Refuses to overwrite a file already
# in /etc/rpi-setup.
move_config() {
  local src="$RPI_SETUP_ROOT/config/rpi-setup.env" dir
  dir="$(system_config_dir)"
  [[ -z "${RPI_SETUP_CONFIG_DIR:-}" ]] || die 'RPI_SETUP_CONFIG_DIR is set; unset it to use the system folder.'
  [[ -f "$src" ]] || die "$src not found; nothing to move."
  [[ ! -e "$dir/rpi-setup.env" ]] || die "$dir/rpi-setup.env already exists; merge $src into it by hand, then delete $src."
  install -m 0700 -o root -g root -d "$dir"
  install -m 0600 -o root -g root "$src" "$dir/rpi-setup.env"
  rm -f "$src"
  rm -rf "$RPI_SETUP_ROOT/config/local"
  say "Moved your settings to $dir/rpi-setup.env (only root can read it)."
  say "Edit it with: sudo nano $dir/rpi-setup.env"
}

# Warn when config/rpi-setup.env sits in the checkout but /etc/rpi-setup wins.
warn_shadowed_config() {
  local repo="$RPI_SETUP_ROOT/config/rpi-setup.env"
  if config_is_system && [[ -f "$repo" ]]; then
    warn "$repo is ignored: settings are read from $(central_config). Delete $repo to avoid confusion."
  fi
  return 0
}

# True for yes/true/on/1, false for no/false/off/0 (any case). Dies naming the
# setting on anything else, so a typo never silently picks a behaviour.
setting_on() {
  local name="$1" v="${!1:-}"
  case "${v,,}" in
    yes|true|on|1) return 0 ;;
    no|false|off|0) return 1 ;;
    *) die "$name must be yes or no (got '$v')" ;;
  esac
}

# Dies unless setting $1 holds a TCP/UDP port number (1-65535).
require_port() {
  local name="$1" v="${!1:-}"
  if [[ "$v" =~ ^[0-9]{1,5}$ ]] && (( 10#$v >= 1 && 10#$v <= 65535 )); then return 0; fi
  die "$name must be a port number between 1 and 65535 (got '$v')"
}

# RFC 1123 host name label: letters, digits and inner '-', at most 63 characters.
valid_hostname() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; }

# Dies unless setting $1 looks like a Docker image reference (name[:tag]).
require_image_ref() {
  local name="$1" v="${!1:-}"
  [[ "$v" =~ ^[a-z0-9][a-z0-9._/:-]*(@sha256:[0-9a-f]{64})?$ ]] ||
    die "$name must be a Docker image such as repo/name:tag (got '$v')"
}

# A random alphanumeric password, $1 characters long (default 20).
gen_secret() {
  local n="${1:-20}" s=""
  while (( ${#s} < n )); do
    s+="$(head -c 64 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
  done
  printf '%s\n' "${s:0:n}"
}

# Record a generated secret in /var/lib/rpi-setup/secrets/<task>.env (root
# only, 0600) so it can be looked up after the console output is gone.
save_secret() {
  local task="$1" key="$2" value="$3" dir=/var/lib/rpi-setup/secrets file
  file="$dir/$task.env"
  install -m 0700 -d "$dir"
  touch "$file"
  chmod 0600 "$file"
  { grep -v "^${key}=" "$file" || true; printf '%s=%s\n' "$key" "$value"; } >"$file.new"
  chmod 0600 "$file.new"
  mv -f "$file.new" "$file"
}

# Print the value of KEY ($2) that save_secret recorded for task $1; false if
# there is none (or it is empty).
load_secret() {
  local v
  v="$(sed -nE "s/^$2=//p" "/var/lib/rpi-setup/secrets/$1.env" 2>/dev/null | head -n1)" || v=""
  [[ -n "$v" ]] || return 1
  printf '%s\n' "$v"
}

# Generate a password of $5 characters (default 20) into variable $1 for
# setting $3 of task $2, record it with save_secret and print it once as
# "Generated <$4>: <password>".
new_secret() {
  local -n _new_secret="$1"
  local task="$2" key="$3" label="$4"
  _new_secret="$(gen_secret "${5:-20}")"
  save_secret "$task" "$key" "$_new_secret"
  say "Generated $label: $_new_secret"
  info "Saved in /var/lib/rpi-setup/secrets/$task.env; set $key to choose your own."
}

# Write stdin to $1 (mode $2, default 0644) only if the content differs.
# Returns 0 if the file was written, 1 if it already had this content, so a
# task can restart a service only when its configuration really changed.
write_if_changed() {
  local dest="$1" mode="${2:-}" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    [[ -z "$mode" ]] || chmod "$mode" "$dest"
    return 1
  fi
  if [[ -f "$dest" && -z "$mode" ]]; then
    cat "$tmp" >"$dest"
  else
    install -m "${mode:-0644}" "$tmp" "$dest"
  fi
  rm -f "$tmp"
  return 0
}

