#!/usr/bin/env bash
# test-task-log2ram.sh - unit tests for the helpers in tasks/log2ram.sh and
# its setting checks. Config files are written to a temp folder; nothing is
# installed.
#
# Run: bash ci/test-task-log2ram.sh
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
. "$ROOT/lib/common.sh"
declare -a TASKS=()
. "$ROOT/tasks/log2ram.sh"

assert_eq "log2ram registers its task" "log2ram" "${TASKS[0]%%|*}"

# --- log2ram_size_k -----------------------------------------------------------
assert_eq    "size 128M"               "131072"  "$(log2ram_size_k 128M)"
assert_eq    "size lower-case m"       "65536"   "$(log2ram_size_k 64m)"
assert_eq    "size 512K"               "512"     "$(log2ram_size_k 512K)"
assert_eq    "size 1G"                 "1048576" "$(log2ram_size_k 1G)"
assert_fails "size without unit"       log2ram_size_k 128
assert_fails "size with MB"            log2ram_size_k 128MB
assert_fails "size zero"               log2ram_size_k 0M
assert_fails "size leading zero"       log2ram_size_k 064M
assert_fails "size percent"            log2ram_size_k 10%
assert_fails "size empty"              log2ram_size_k ''
assert_fails "size injection"          log2ram_size_k '1M;rm'

# --- log2ram_set_conf ---------------------------------------------------------
conf="$TMP/log2ram.conf"
printf '# Size\nSIZE=40M\nUSE_RSYNC=true\nNOTIFICATION=true\nPATH_DISK="/var/log"\n' >"$conf"
assert_ok "conf: changing the size reports a change" log2ram_set_conf "$conf" 128M
assert_eq "conf: size set and notifications off, rest kept" \
  "$(printf '# Size\nSIZE=128M\nUSE_RSYNC=true\nNOTIFICATION=false\nPATH_DISK="/var/log"\n')" "$(cat "$conf")"
assert_fails "conf: same size again changes nothing" log2ram_set_conf "$conf" 128M
assert_fails "conf: the same size in lower case changes nothing" log2ram_set_conf "$conf" 128m
log2ram_set_conf "$conf" 256m || true
assert_contains "conf: a lower-case suffix is written upper-case" "SIZE=256M" "$(cat "$conf")"
printf 'MAIL=true\n' >"$conf"
log2ram_set_conf "$conf" 256M || true
assert_eq "conf: missing SIZE is added, MAIL of an old log2ram turned off" "$(printf 'MAIL=false\nSIZE=256M\n')" "$(cat "$conf")"

# --- log2ram_journald ---------------------------------------------------------
L2R_JOURNALD_CONF="$TMP/journald.conf.d/20-log2ram.conf"
assert_ok "journald: first write reports a change" log2ram_journald 64M
assert_contains "journald: SystemMaxUse set" "SystemMaxUse=64M" "$(cat "$L2R_JOURNALD_CONF")"
assert_fails "journald: same limit changes nothing" log2ram_journald 64M
assert_fails "journald: the same limit in lower case changes nothing" log2ram_journald 64m
log2ram_journald 32m || true
assert_contains "journald: a lower-case suffix is written upper-case (journald rejects 32m)" "SystemMaxUse=32M" "$(cat "$L2R_JOURNALD_CONF")"

# --- log2ram_valid_sync / log2ram_timer_dropin -------------------------------
assert_ok    "sync accepts hourly"          log2ram_valid_sync hourly
assert_ok    "sync accepts daily"           log2ram_valid_sync daily
assert_ok    "sync accepts every 30 min"    log2ram_valid_sync '*:0/30'
assert_fails "sync rejects empty"           log2ram_valid_sync ''
assert_fails "sync rejects a newline"       log2ram_valid_sync $'hourly\nExecStart=/bin/sh'
assert_fails "sync rejects a semicolon"     log2ram_valid_sync 'hourly;reboot'
if have systemd-analyze; then
  assert_fails "sync rejects nonsense"      log2ram_valid_sync 'every-now-and-then'
else
  skip "systemd-analyze not installed: calendar syntax not checked"
fi
L2R_TIMER_CONF="$TMP/log2ram-daily.timer.d/10-rpi-setup.conf"
assert_ok "timer: hourly writes the drop-in" log2ram_timer_dropin hourly
assert_eq "timer: drop-in resets and sets OnCalendar" "$(printf 'OnCalendar=\nOnCalendar=hourly')" \
  "$(grep '^OnCalendar' "$L2R_TIMER_CONF")"
assert_fails "timer: same time changes nothing" log2ram_timer_dropin hourly
assert_ok "timer: daily removes the drop-in" log2ram_timer_dropin daily
assert_eq "timer: drop-in gone" "no" "$([[ -e "$L2R_TIMER_CONF" ]] && echo yes || echo no)"
assert_fails "timer: daily again changes nothing" log2ram_timer_dropin daily

# --- run_log2ram rejects bad settings before changing anything ---------------
apt_installed() { echo "apt_installed called" >&2; return 1; }
check() { (LOG2RAM_SIZE="$1" LOG2RAM_JOURNAL_MAX_SIZE="$2" LOG2RAM_SYNC="${3:-}" run_log2ram) 2>&1 || true; }
assert_contains "run: bad size"             "LOG2RAM_SIZE must be a size"   "$(check 128 64M)"
assert_contains "run: bad journal size"     "LOG2RAM_JOURNAL_MAX_SIZE must" "$(check 128M 1T)"
assert_contains "run: size below 16M"       "at least 16M"                  "$(check 8M 4M)"
assert_contains "run: journal too large"    "at most 3/4"                   "$(check 128M 100M)"
assert_contains "run: bad sync time"        "LOG2RAM_SYNC must be"          "$(check 128M 64M 'hourly;x')"
assert_lacks    "run: nothing installed on bad settings" "apt_installed called" "$(check 128M 100M)"

# --- the azlux repository may only bring log2ram ---------------------------------
pin="$(log2ram_pin)"
assert_contains "pin: log2ram from azlux" $'Package: log2ram\nPin: origin packages.azlux.fr\nPin-Priority: 500' "$pin"
assert_contains "pin: nothing else from azlux" $'Package: *\nPin: origin packages.azlux.fr\nPin-Priority: 1' "$pin"

finish_tests
