#!/usr/bin/env bash
# Task: log2ram - keep /var/log in RAM to spare the SD card.
# Settings: LOG2RAM_* in config/rpi-setup.env (names in config/tasks/log2ram.env).
set -euo pipefail

TASKS+=("log2ram|log2ram: /var/log in RAM, written to the SD card every hour")

L2R_CONF=/etc/log2ram.conf
L2R_JOURNALD_CONF=/etc/systemd/journald.conf.d/20-log2ram.conf
L2R_TIMER_CONF=/etc/systemd/system/log2ram-daily.timer.d/10-rpi-setup.conf
L2R_APT_LIST=/etc/apt/sources.list.d/azlux.list
L2R_APT_PIN=/etc/apt/preferences.d/rpi-setup-azlux

run_log2ram() {
  : "${LOG2RAM_SIZE:=128M}" "${LOG2RAM_JOURNAL_MAX_SIZE:=64M}" "${LOG2RAM_SYNC:=hourly}"
  local size_k journal_k used_k changed=no

  # Validate every setting before changing anything.
  size_k="$(log2ram_size_k "$LOG2RAM_SIZE")" ||
    die "LOG2RAM_SIZE must be a size like 128M or 1G (got '$LOG2RAM_SIZE')"
  journal_k="$(log2ram_size_k "$LOG2RAM_JOURNAL_MAX_SIZE")" ||
    die "LOG2RAM_JOURNAL_MAX_SIZE must be a size like 64M (got '$LOG2RAM_JOURNAL_MAX_SIZE')"
  (( size_k >= 16 * 1024 )) || die "LOG2RAM_SIZE must be at least 16M (got '$LOG2RAM_SIZE')"
  (( journal_k * 4 <= size_k * 3 )) ||
    die "LOG2RAM_JOURNAL_MAX_SIZE ($LOG2RAM_JOURNAL_MAX_SIZE) must be at most 3/4 of LOG2RAM_SIZE ($LOG2RAM_SIZE), or the journal fills the RAM disk"
  log2ram_valid_sync "$LOG2RAM_SYNC" ||
    die "LOG2RAM_SYNC must be hourly, daily or a systemd calendar time such as *:0/30 (got '$LOG2RAM_SYNC')"

  if ! apt_installed log2ram; then
    log2ram_add_repo
  fi
  # Also on a Pi that got the repository from an earlier run.
  if [[ -f "$L2R_APT_LIST" ]]; then
    install -m 0755 -d "${L2R_APT_PIN%/*}"
    if log2ram_pin | write_if_changed "$L2R_APT_PIN" 0644; then
      info "Wrote $L2R_APT_PIN: only log2ram comes from packages.azlux.fr"
    fi
  fi
  apt_installed log2ram || apt_update_now
  apt_install log2ram rsync
  [[ -f "$L2R_CONF" ]] || die "log2ram is installed but $L2R_CONF is missing; reinstall it: sudo apt-get install --reinstall log2ram"

  if log2ram_set_conf "$L2R_CONF" "$LOG2RAM_SIZE"; then
    changed=yes
    say "log2ram RAM disk set to $LOG2RAM_SIZE ($L2R_CONF)"
  fi
  if log2ram_journald "$LOG2RAM_JOURNAL_MAX_SIZE"; then
    say "Journal limited to $LOG2RAM_JOURNAL_MAX_SIZE so it fits in the RAM disk ($L2R_JOURNALD_CONF)"
    if in_container; then
      info 'Container detected: not restarting systemd-journald'
    else
      systemctl restart systemd-journald || warn 'Could not restart systemd-journald; the journal limit applies after a reboot.'
    fi
  fi

  log2ram_sync_timer "$LOG2RAM_SYNC"

  # Logs already on disk must fit, or log2ram refuses to start at boot.
  if ! log2ram_active; then
    used_k="$(du -sk /var/log 2>/dev/null | cut -f1)" || used_k=0
    if (( ${used_k:-0} * 4 > size_k * 3 )); then
      warn "/var/log already holds $((used_k / 1024))M, close to LOG2RAM_SIZE ($LOG2RAM_SIZE); log2ram will not start unless it fits. Clean up old logs (sudo journalctl --vacuum-size=$LOG2RAM_JOURNAL_MAX_SIZE) or raise LOG2RAM_SIZE."
    fi
  fi

  systemctl enable log2ram >/dev/null 2>&1 || warn 'Could not enable log2ram.service'
  if in_container; then
    info 'Container detected: log2ram takes over /var/log at the next boot'
  elif ! log2ram_active || [[ "$changed" == yes ]]; then
    # log2ram mounts /var/log at boot, before anything opens a log file.
    touch "${RPI_SETUP_REBOOT_FILE:-/run/reboot-required}" 2>/dev/null || true
    say 'log2ram is set up; it keeps /var/log in RAM after the next reboot (sudo reboot)'
  else
    say "log2ram keeps /var/log in RAM ($LOG2RAM_SIZE); see it with: df -h /var/log"
  fi
}

# Print a size like 128M, 512K or 1G (as tmpfs and journald take it) in KiB.
log2ram_size_k() {
  [[ "$1" =~ ^([1-9][0-9]{0,5})([KkMmGg])$ ]] || return 1
  local n="${BASH_REMATCH[1]}"
  case "${BASH_REMATCH[2]^^}" in
    K) echo "$n" ;;
    M) echo $((n * 1024)) ;;
    G) echo $((n * 1024 * 1024)) ;;
  esac
}

# True when log2ram's RAM disk is mounted on /var/log.
log2ram_active() {
  findmnt -n -o SOURCE /var/log 2>/dev/null | grep -qx log2ram
}

# Add the log2ram maintainer's apt repository (packages.azlux.fr), so
# apt-get upgrade (and update.sh) keeps log2ram current.
log2ram_add_repo() {
  local codename key=/usr/share/keyrings/azlux-archive-keyring.gpg tmp
  codename=$( . /etc/os-release && echo "${VERSION_CODENAME:-}" ) || true
  [[ -n "$codename" ]] || die 'Could not determine the OS release (VERSION_CODENAME); the log2ram apt repository needs it.'
  apt_install ca-certificates curl gnupg
  tmp="$(mktemp)"
  curl -fsSL https://azlux.fr/repo.gpg -o "$tmp" ||
    { rm -f "$tmp"; die 'Could not download the log2ram repository key from https://azlux.fr/repo.gpg; check the Pi'\''s internet connection and re-run: sudo bash setup.sh log2ram'; }
  if grep -q -- '-----BEGIN PGP' "$tmp"; then
    gpg --dearmor --yes -o "$key" <"$tmp"
  else
    install -m 0644 "$tmp" "$key"
  fi
  rm -f "$tmp"
  chmod a+r "$key"
  echo "deb [signed-by=$key] http://packages.azlux.fr/debian/ $codename main" >"$L2R_APT_LIST"
  info "Added the log2ram apt repository for $codename"
}

# The apt preferences for the azlux repository: log2ram from there, every
# other package never (priority 1: only installed if asked for by name and
# found nowhere else), so the repository cannot replace a system package
# such as openssh-server or sudo.
log2ram_pin() {
  printf '%s\n' \
    '# Managed by rpi-setup (tasks/log2ram.sh): take only log2ram from packages.azlux.fr.' \
    'Package: log2ram' \
    'Pin: origin packages.azlux.fr' \
    'Pin-Priority: 500' \
    '' \
    'Package: *' \
    'Pin: origin packages.azlux.fr' \
    'Pin-Priority: 1'
}

# Set SIZE= in log2ram.conf $1 to $2 and turn off its error mails (a Pi has
# no mail setup): NOTIFICATION= in current log2ram, MAIL= in versions before
# 1.7. The package's other defaults stay. Returns 0 if it changed.
log2ram_set_conf() {
  local conf="$1" size="${2^^}"
  {
    sed -E -e "s/^SIZE=.*/SIZE=$size/" -e 's/^NOTIFICATION=.*/NOTIFICATION=false/' -e 's/^MAIL=.*/MAIL=false/' "$conf"
    grep -q '^SIZE=' "$conf" || echo "SIZE=$size"
  } | write_if_changed "$conf" 0644
}

# journald drop-in that keeps the persistent journal (in /var/log/journal,
# so in RAM) below $1 (its suffix upper-cased: journald takes 64M, not 64m).
# It sorts after base's 10-rpi-setup.conf and wins. Returns 0 if it changed.
log2ram_journald() {
  install -m 0755 -d "${L2R_JOURNALD_CONF%/*}"
  printf '# Managed by rpi-setup (LOG2RAM_JOURNAL_MAX_SIZE); re-run "setup.sh log2ram" to change.\n[Journal]\nSystemMaxUse=%s\n' "${1^^}" |
    write_if_changed "$L2R_JOURNALD_CONF" 0644
}

# True if $1 is a valid LOG2RAM_SYNC: daily, or a systemd OnCalendar time
# (hourly, *:0/30, ...). systemd-analyze checks it where it exists.
log2ram_valid_sync() {
  [[ "$1" =~ ^[A-Za-z0-9*:/,.~\ -]+$ ]] || return 1
  [[ "$1" == daily ]] && return 0
  ! have systemd-analyze || systemd-analyze calendar "$1" >/dev/null 2>&1
}

# Drop-in for log2ram-daily.timer that copies the logs to the SD card at $1
# instead of once a day; "daily" removes it and keeps the package's time.
# Returns 0 if it changed.
log2ram_timer_dropin() {
  if [[ "$1" == daily ]]; then
    [[ -f "$L2R_TIMER_CONF" ]] || return 1
    rm -f "$L2R_TIMER_CONF"
    return 0
  fi
  install -m 0755 -d "${L2R_TIMER_CONF%/*}"
  printf '# Managed by rpi-setup (LOG2RAM_SYNC); re-run "setup.sh log2ram" to change.\n[Timer]\nOnCalendar=\nOnCalendar=%s\n' "$1" |
    write_if_changed "$L2R_TIMER_CONF" 0644
}

# Apply LOG2RAM_SYNC $1 and restart the timer when it changed.
log2ram_sync_timer() {
  if log2ram_timer_dropin "$1"; then
    say "log2ram copies the logs to the SD card: $1 ($L2R_TIMER_CONF)"
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart log2ram-daily.timer 2>/dev/null || true
  fi
}
