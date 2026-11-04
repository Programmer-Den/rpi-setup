#!/usr/bin/env bash
# check.sh - read-only health check for a Pi provisioned with rpi-setup.
#
# Usage: sudo bash check.sh
#
# Prints one line per check (OK / WARN / FAIL) and a summary line, and exits
# 1 if any check failed. Nothing on the Pi is changed. Only tasks that look
# installed are checked, so it works on a Pi with just some tasks set up.
# Ports come from the same settings the tasks use (config/local/<task>.env,
# with the same defaults). No password or key is ever printed.
set -euo pipefail

CHECK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$CHECK_ROOT/lib/common.sh"

CHECK_OK=0
CHECK_WARN=0
CHECK_FAIL=0
CHECK_LANIP=""

# --- Output -------------------------------------------------------------------

# report STATUS NAME DETAIL: one aligned line, e.g. "OK    ssh              active".
report() {
  local status="$1" name="$2" detail="${3:-}"
  case "$status" in
    OK)   CHECK_OK=$((CHECK_OK + 1)) ;;
    WARN) CHECK_WARN=$((CHECK_WARN + 1)) ;;
    FAIL) CHECK_FAIL=$((CHECK_FAIL + 1)) ;;
    *) die "report: unknown status '$status'" ;;
  esac
  printf '%-4s  %-22s %s\n' "$status" "$name" "$detail"
}

# The last line; returns 1 if any check failed.
summary() {
  printf 'Summary: %d OK, %d WARN, %d FAIL\n' "$CHECK_OK" "$CHECK_WARN" "$CHECK_FAIL"
  [[ $CHECK_FAIL -eq 0 ]]
}

# --- Pure helpers (unit tested in ci/test-task-check.sh) ------------------------

# Decode "vcgencmd get_throttled" (e.g. "throttled=0x50005" or "0x0") into
# "STATUS|detail". Under-voltage or throttling right now is a FAIL; anything
# that only happened since boot is a WARN (a Pi 5 needs a 5V/5A supply).
throttle_status() {
  local raw="${1#throttled=}" val flags=() status=OK entry bit sev label
  [[ "$raw" =~ ^0[xX][0-9a-fA-F]+$ ]] || { printf 'WARN|cannot read "%s"\n' "$1"; return 0; }
  val=$((raw))
  for entry in '0x1:FAIL:under-voltage now' '0x2:WARN:CPU frequency capped now' \
      '0x4:FAIL:throttled now' '0x8:WARN:soft temperature limit now' \
      '0x10000:WARN:under-voltage since boot' '0x20000:WARN:frequency capped since boot' \
      '0x40000:WARN:throttled since boot' '0x80000:WARN:soft temperature limit since boot'; do
    IFS=: read -r bit sev label <<<"$entry"
    (( val & bit )) || continue
    flags+=("$label")
    [[ $status == FAIL ]] || status="$sev"
  done
  if [[ ${#flags[@]} -eq 0 ]]; then
    printf 'OK|%s (no under-voltage or throttling)\n' "$raw"
    return 0
  fi
  local detail
  detail="$(IFS=,; printf '%s' "${flags[*]}")"
  detail="${detail//,/, }"
  if (( val & 0x10001 )); then detail+="; check the power supply (Pi 5: 5V 5A)"; fi
  printf '%s|%s: %s\n' "$status" "$raw" "$detail"
}

# Temperature in millidegrees C -> STATUS: below 70 C OK, below 80 C WARN
# (the Pi 5 starts to throttle at 80 C), else FAIL.
temp_status() {
  local m="$1"
  [[ "$m" =~ ^[0-9]+$ ]] || { echo WARN; return 0; }
  if (( m < 70000 )); then echo OK; elif (( m < 80000 )); then echo WARN; else echo FAIL; fi
}

# Disk usage percent -> STATUS: below 80 OK, below 90 WARN, else FAIL.
disk_status() {
  local p="${1%\%}"
  [[ "$p" =~ ^[0-9]+$ ]] || { echo WARN; return 0; }
  if (( p < 80 )); then echo OK; elif (( p < 90 )); then echo WARN; else echo FAIL; fi
}

# HTTP status code -> STATUS. "000" means no connection. With "any", every
# answer counts (e.g. an API that answers 401/404 without a key).
http_status() {
  local code="$1" mode="${2:-}"
  if [[ ! "$code" =~ ^[0-9]{3}$ || "$code" == 000 ]]; then echo FAIL
  elif [[ "$mode" == any ]]; then echo OK
  elif (( 10#$code < 400 )); then echo OK
  else echo WARN
  fi
}

# Value of port setting $1, or $2 if it is unset or not a valid port.
port_setting() {
  local v="${!1:-}"
  if [[ "$v" =~ ^[0-9]{1,5}$ ]] && (( 10#$v >= 1 && 10#$v <= 65535 )); then
    printf '%s\n' "$((10#$v))"
  else
    printf '%s\n' "$2"
  fi
}

# --- System helpers -------------------------------------------------------------

# Load task $1's settings like setup.sh does; a broken file is a WARN and the
# task's defaults are used. Output is dropped so nothing from it is printed.
check_config() {
  local task="$1"
  if ( load_task_config "$task" ) >/dev/null 2>&1; then
    load_task_config "$task" >/dev/null 2>&1 || true
  else
    report WARN "config $task" "config/local/$task.env could not be read; using defaults"
  fi
}

# Report "<svc> active/enabled" for a systemd service.
check_service() {
  local svc="$1" label="${2:-$1}" active enabled
  if ! have systemctl; then report WARN "$label" "systemctl not found"; return 0; fi
  active="$(systemctl is-active "$svc" 2>/dev/null)" || true
  enabled="$(systemctl is-enabled "$svc" 2>/dev/null)" || true
  : "${active:=unknown}" "${enabled:=unknown}"
  if [[ "$active" == active && ( "$enabled" == enabled || "$enabled" == static || "$enabled" == alias ) ]]; then
    report OK "$label" "service $svc active, $enabled"
  elif [[ "$active" == active ]]; then
    report WARN "$label" "service $svc active but $enabled (will not start after reboot)"
  else
    report FAIL "$label" "service $svc $active, $enabled (see: journalctl -u $svc -b)"
  fi
}

# Report whether URL $2 answers (see http_status for $3).
check_http() {
  local label="$1" url="$2" mode="${3:-}" code status
  if ! have curl; then report WARN "$label" "curl not found; open $url in a browser"; return 0; fi
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 8 "$url" 2>/dev/null)" || true
  [[ -n "$code" ]] || code=000
  status="$(http_status "$code" "$mode")"
  if [[ "$status" == FAIL ]]; then
    report FAIL "$label" "$url not reachable"
  else
    report "$status" "$label" "$url answers HTTP $code"
  fi
}

# Report whether something listens on port $2 ($3 = tcp or udp).
check_listen() {
  local label="$1" port="$2" proto="${3:-tcp}" flag=-ltn
  [[ "$proto" == udp ]] && flag=-lun
  if ! have ss; then report WARN "$label" "ss not found"; return 0; fi
  if [[ -n "$(ss -H "$flag" "sport = :$port" 2>/dev/null)" ]]; then
    report OK "$label" "listening on $proto port $port"
  else
    report FAIL "$label" "nothing listens on $proto port $port"
  fi
}

# Report whether container $1 is running.
check_container() {
  local name="$1" state
  state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null)" || state="missing"
  if [[ "$state" == running ]]; then
    report OK "container $name" "running"
  else
    report FAIL "container $name" "$state (see: sudo docker logs $name)"
  fi
}

# --- Checks -------------------------------------------------------------------

check_system() {
  local model os arch kernel pagesize
  model="$(pi_model)"
  if is_pi5; then report OK board "$model"
  elif is_pi; then report WARN board "$model (rpi-setup targets the Pi 5)"
  else report WARN board "${model:-unknown} (not a Raspberry Pi)"
  fi

  os="$( . /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}" )" || os=""
  report OK os "${os:-unknown}"
  arch="$(uname -m)"
  kernel="$(uname -r)"
  if [[ "$arch" == aarch64 ]]; then report OK kernel "$kernel ($arch)"
  else report WARN kernel "$kernel ($arch; rpi-setup expects 64-bit Raspberry Pi OS, aarch64)"
  fi
  pagesize="$(getconf PAGESIZE 2>/dev/null)" || pagesize=""
  report OK "page size" "${pagesize:-unknown} bytes"
  report OK uptime "$(uptime -p 2>/dev/null || echo unknown)"
  if [[ -e "$CHECK_ROOT/.git" ]] && have git; then
    report OK "rpi-setup version" "$(git -c safe.directory="$CHECK_ROOT" -C "$CHECK_ROOT" log -1 --format='%h %cs' 2>/dev/null || echo unknown)"
  fi
}

check_firmware() {
  local out
  if have rpi-eeprom-update; then
    out="$(rpi-eeprom-update 2>/dev/null)" || true
    local cur
    cur="$(sed -nE 's/^[[:space:]]*CURRENT:[[:space:]]*(.*)$/\1/p' <<<"$out" | head -n1)"
    if grep -q 'BOOTLOADER: up to date' <<<"$out"; then
      report OK eeprom "${cur:-up to date}"
    elif grep -q 'BOOTLOADER: update available' <<<"$out"; then
      report WARN eeprom "${cur:-unknown}; update available (base task with BASE_EEPROM_UPDATE=yes)"
    else
      report WARN eeprom "${cur:-could not read the bootloader version}"
    fi
  elif have vcgencmd; then
    report OK eeprom "$(vcgencmd bootloader_version 2>/dev/null | head -n1 || echo unknown)"
  else
    report WARN eeprom "rpi-eeprom-update not found"
  fi

  if have vcgencmd; then
    local t
    t="$(throttle_status "$(vcgencmd get_throttled 2>/dev/null || echo unknown)")"
    report "${t%%|*}" throttling "${t#*|}"
  else
    report WARN throttling "vcgencmd not found"
  fi

  local m=""
  [[ -r /sys/class/thermal/thermal_zone0/temp ]] && m="$(</sys/class/thermal/thermal_zone0/temp)"
  if [[ "$m" =~ ^[0-9]+$ ]]; then
    report "$(temp_status "$m")" temperature "$((m / 1000)).$(((m % 1000) / 100)) C"
  else
    report WARN temperature "not available"
  fi

  local line pct avail
  line="$(df -P / 2>/dev/null | awk 'NR == 2 {print $5, $4}')" || line=""
  pct="${line%% *}"
  avail="${line##* }"
  if [[ -n "$line" ]]; then
    report "$(disk_status "$pct")" "disk /" "$pct used, $((avail / 1024)) MiB free"
  else
    report WARN "disk /" "df failed"
  fi
}

check_network() {
  CHECK_LANIP="$(pi_ip)" || CHECK_LANIP=""
  if [[ -n "$CHECK_LANIP" ]]; then
    report OK "lan address" "$CHECK_LANIP ($(default_iface 2>/dev/null || echo 'no default route'))"
  else
    report FAIL "lan address" "no LAN address (hostname -I is empty); endpoints are checked on localhost"
  fi
  if unit_exists ssh; then check_service ssh ssh
  else report FAIL ssh "openssh-server is not installed"
  fi
}

check_tasks() {
  local found=0 host="${CHECK_LANIP:-localhost}"

  if apt_installed fail2ban; then
    found=1; check_service fail2ban "base: fail2ban"
  fi

  if have docker; then
    found=1; check_service docker "docker"
    if docker compose version >/dev/null 2>&1; then report OK "docker compose" "$(docker compose version --short 2>/dev/null || echo present)"
    else report FAIL "docker compose" "the compose plugin is missing (sudo bash setup.sh docker)"
    fi
  fi

  if task_in_container web || unit_exists nginx; then
    found=1; check_config web
    local wport site=/etc/nginx/sites-available/default
    task_in_container web && site="$(container_dir web)/conf/default.conf"
    wport="$(sed -nE 's/^[[:space:]]*listen[[:space:]]+([0-9]+)([[:space:];]).*/\1/p' \
      "$site" 2>/dev/null | head -n1)" || wport=""
    [[ -n "$wport" ]] || wport="$(port_setting WEB_PORT 80)"
    if task_in_container web; then check_container web
    else check_service nginx "web"
    fi
    check_http "web: page" "http://$host:$wport/"
    # The timers behind the page's service list and its update check, where set up.
    if unit_exists rpi-setup-web-links.timer; then check_service rpi-setup-web-links.timer "web: links timer"; fi
    if unit_exists rpi-setup-updates.timer; then check_service rpi-setup-updates.timer "web: updates timer"; fi
  fi

  if task_in_container pihole || have pihole-FTL || unit_exists pihole-FTL; then
    found=1; check_config pihole
    local pport
    pport="$(pihole_web_ports | head -n1)" || pport=""
    [[ -n "$pport" ]] || pport="$(port_setting PIHOLE_WEB_PORT 80)"
    if task_in_container pihole; then check_container pihole
    else check_service pihole-FTL "pihole"
    fi
    check_listen "pihole: dns" 53 udp
    check_http "pihole: admin" "http://$host:$pport/admin/"
  fi

  if task_in_container samba; then
    found=1; check_config samba
    check_container samba
    check_listen "samba: smb" 445 tcp
    local cshare="${SAMBA_SHARE_NAME:-nas-share}"
    if grep -qF "name: \"$cshare\"" "$(container_dir samba)/data/config.yml" 2>/dev/null; then
      report OK "samba: share" "[$cshare] in the container's config.yml"
    else report WARN "samba: share" "[$cshare] not found in $(container_dir samba)/data/config.yml"
    fi
  elif unit_exists smbd; then
    found=1; check_config samba
    check_service smbd "samba"
    check_listen "samba: smb" 445 tcp
    local share="${SAMBA_SHARE_NAME:-nas-share}"
    if grep -qF "[$share]" /etc/samba/smb.conf 2>/dev/null; then report OK "samba: share" "[$share] in smb.conf"
    else report WARN "samba: share" "[$share] not found in /etc/samba/smb.conf"
    fi
  fi

  if apt_installed log2ram; then
    found=1
    if findmnt -n -o SOURCE /var/log 2>/dev/null | grep -qx log2ram; then
      report OK "log2ram" "/var/log in RAM, $(df -h --output=used,size /var/log 2>/dev/null | awk 'NR == 2 { print $1 " of " $2 }') used"
    else
      report WARN "log2ram" "installed but /var/log is not in RAM (reboot; else see: journalctl -u log2ram -b)"
    fi
  fi

  if [[ -f "$(container_dir netalertx)/docker-compose.yml" ]]; then
    found=1; check_config netalertx
    if have docker; then check_container netalertx; fi
    check_http "netalertx: web" "http://$host:$(port_setting NETALERTX_PORT 20211)/"
  fi

  if [[ -f "$(container_dir teamspeak)/docker-compose.yml" ]]; then
    found=1; check_config teamspeak
    if have docker; then check_container teamspeak; fi
    check_listen "teamspeak: voice" "$(port_setting TEAMSPEAK_VOICE_PORT 9987)" udp
    check_listen "teamspeak: files" "$(port_setting TEAMSPEAK_FILE_PORT 30033)" tcp
    local qhttp="${TEAMSPEAK_QUERY_HTTP:-no}"
    case "${qhttp,,}" in
      yes|true|on|1) check_http "teamspeak: query" "http://$host:$(port_setting TEAMSPEAK_QUERY_PORT 10080)/" any ;;
      no|false|off|0) ;;
      *) report WARN "teamspeak: query" "TEAMSPEAK_QUERY_HTTP must be yes or no (got '$qhttp'); the task stops on it" ;;
    esac
  fi

  if [[ -f "$(container_dir denwatcher)/docker-compose.yml" ]]; then
    found=1; check_config denwatcher
    if have docker; then check_container den-watcher; fi
    check_http "denwatcher: web" "http://$host:$(port_setting DENWATCHER_PORT 9393)/api/metrics"
  fi

  if [[ -f "$(container_dir apps)/docker-compose.yml" ]]; then
    found=1; check_config apps
    local app port
    while read -r app port; do
      if have docker; then check_container "$app"; fi
      check_http "apps: $app" "http://$host:$port/"
    done < <(sed -n 's/^    container_name: \(.*\)$/\1/p; s/^ *- "0\.0\.0\.0:\([0-9]*\):[0-9]*"$/\1/p' "$(container_dir apps)/docker-compose.yml" | paste -d' ' - -)
  fi

  if unit_exists rpi-setup-backup.timer; then
    found=1; check_service rpi-setup-backup.timer "backup: timer"
    if [[ "$(systemctl is-failed rpi-setup-backup.service 2>/dev/null)" == failed ]]; then
      report WARN "backup: last run" "failed (see: journalctl -u rpi-setup-backup -b)"
    fi
  fi

  # actions/runner's svc.sh records the unit it installed in .service in the
  # runner's folder (tasks/runner.sh); RPI_SETUP_RUNNER_DIR only exists for tests.
  local runner_unit runner_dir="${RPI_SETUP_RUNNER_DIR:-/opt/rpi-runner}"
  if runner_unit="$(cat "$runner_dir/.service" 2>/dev/null)" && [[ -n "$runner_unit" ]]; then
    found=1; check_service "$runner_unit" "runner"
  fi

  # The firewall unit is oneshot with RemainAfterExit, so it stays active
  # after anything flushes the ruleset: the table itself is checked too.
  if unit_exists rpi-setup-firewall; then
    found=1; check_service rpi-setup-firewall "firewall"
    if ! have nft; then
      report WARN "firewall: rules" "nft not found"
    elif [[ $EUID -ne 0 ]]; then
      report WARN "firewall: rules" "not run as root; cannot read the rules"
    elif nft list table inet rpi_setup >/dev/null 2>&1; then
      report OK "firewall: rules" "table inet rpi_setup is loaded"
    else
      report FAIL "firewall: rules" "table inet rpi_setup is missing, every port is open (run: sudo systemctl restart rpi-setup-firewall)"
    fi
  fi

  if have docker && docker info >/dev/null 2>&1; then
    local bad
    bad="$(docker ps -a --filter status=exited --filter status=restarting --filter status=dead \
      --format '{{.Names}} ({{.Status}})' 2>/dev/null | paste -sd, - | sed 's/,/, /g')" || bad=""
    local running
    running="$(docker ps -q 2>/dev/null | wc -l)"
    if [[ -n "$bad" ]]; then report WARN "docker: containers" "$running running; not running: $bad"
    else report OK "docker: containers" "$running running"
    fi
  fi

  [[ $found -eq 1 ]] || report WARN tasks "no rpi-setup task looks installed yet"
}

main() {
  case "${1:-}" in
    -h|--help)
      sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      return 0 ;;
    '') ;;
    *) die "unknown option: $1 (usage: sudo bash check.sh)" ;;
  esac
  printf 'rpi-setup health check - %s - %s\n' "$(hostname)" "$(date '+%Y-%m-%d %H:%M %Z')"
  if [[ $EUID -ne 0 ]]; then
    report WARN root "not run as root; some checks are incomplete (use: sudo bash check.sh)"
  fi
  check_system
  check_firmware
  check_network
  check_tasks
  summary
}

# Only run when executed directly; ci/test-task-check.sh sources this file.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
