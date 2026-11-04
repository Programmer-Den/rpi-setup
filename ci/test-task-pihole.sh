#!/usr/bin/env bash
# test-task-pihole.sh - unit tests for tasks/pihole.sh: the installer runs
# without a question, and a generated container password is printed and saved
# before the container starts (so a failed first start does not lose it).
# Docker, ports and save_secret are stubbed; nothing outside a temp folder changes.
#
# Run: bash ci/test-task-pihole.sh
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
export RPI_SETUP_ROOT="$ROOT"
. "$ROOT/lib/common.sh"
TASKS=()
. "$ROOT/tasks/pihole.sh"

# --- The installer: a warning, never a question --------------------------------
assert_contains "the curl|bash warning is printed" 'curl ... | bash' "$(declare -f run_pihole)"
# shellcheck disable=SC2016 # the literal text of the function
assert_contains "the installer always runs unattended" 'bash "$installer" --unattended' "$(declare -f run_pihole)"
assert_lacks "the installer is never piped into bash" '| bash' "$(declare -f run_pihole | grep -v warn)"
assert_contains "the log records the installer's checksum" 'Pi-hole installer SHA-256' "$(declare -f run_pihole)"
assert_eq "no question is asked" "" "$(grep -n 'read -r -p' "$ROOT/tasks/pihole.sh" || true)"

# --- PIHOLE_DB_INTERVAL: seconds between database writes ---------------------
assert_eq "the interval defaults to 300 seconds" "300" "$(unset PIHOLE_DB_INTERVAL; pihole_db_interval)"
assert_eq "an empty interval is the default" "300" "$(PIHOLE_DB_INTERVAL='' pihole_db_interval)"
assert_eq "a set interval is kept" "600" "$(PIHOLE_DB_INTERVAL=600 pihole_db_interval)"
for bad in 59 3601 0 060 5m -1 'x'; do
  assert_fails "PIHOLE_DB_INTERVAL=$bad is refused" bash -c ". '$ROOT/lib/common.sh'; TASKS=(); . '$ROOT/tasks/pihole.sh'; PIHOLE_DB_INTERVAL='$bad' pihole_db_interval"
done
compose="$(PIHOLE_DB_INTERVAL=900 PIHOLE_QUERY_LOGGING=yes PIHOLE_IMAGE=pihole/pihole:latest pihole_container_compose /opt/pihole pihole lo 8080 1.1.1.1)"
assert_contains "the container gets the interval" 'FTLCONF_database_DBinterval: "900"' "$compose"
assert_contains "the container's admin port keeps the HTTPS listener" 'FTLCONF_webserver_port: "8080o,443os,[::]:8080o,[::]:443os"' "$compose"
assert_contains "the container's host name is quoted" "hostname: \"$(hostname)\"" "$compose"

# --- PIHOLE_WEB_PORT: only the HTTP entries move, TLS stays on 443 -----------
assert_eq "port setting: Pi-hole's default moved to 8080" "8080o,443os,[::]:8080o,[::]:443os" \
  "$(pihole_port_setting '80o,443os,[::]:80o,[::]:443os' 8080)"
assert_eq "port setting: an address keeps its address" "127.0.0.1:8080o,443os" "$(pihole_port_setting '127.0.0.1:80o,443os' 8080)"
assert_eq "port setting: an entry without flags" "8080,[::]:8080" "$(pihole_port_setting '80,[::]:80' 8080)"
assert_eq "port setting: a redirecting HTTP entry moves too" "8080or,443os" "$(pihole_port_setting '80or,443os' 8080)"
assert_eq "port setting: TLS only gets HTTP in front" "8080o,[::]:8080o,443os" "$(pihole_port_setting '443os' 8080)"
assert_eq "port setting: empty gets the port for IPv4 and IPv6" "8080o,[::]:8080o" "$(pihole_port_setting '' 8080)"
assert_eq "port setting: already there changes nothing" "80o,443os,[::]:80o,[::]:443os" \
  "$(pihole_port_setting '80o,443os,[::]:80o,[::]:443os' 80)"
PH_TOML="$TMP/etc/pihole.toml"
(PIHOLE_WEB_PORT=8080 PIHOLE_QUERY_LOGGING=yes pihole_preseed eth0 1.1.1.1 1.0.0.1) >/dev/null
assert_contains "the pre-seeded pihole.toml keeps the HTTPS listener" 'port = "8080o,443os,[::]:8080o,[::]:443os"' "$(cat "$PH_TOML")"
assert_contains "and carries the upstreams" 'upstreams = [ "1.1.1.1", "1.0.0.1" ]' "$(cat "$PH_TOML")"
# The native path: the HTTPS entries of the current setting survive a move.
pihole-FTL() { case "$*" in '--config webserver.port') echo '80o,443os,[::]:80o,[::]:443os' ;; *) printf '%s\n' "$*" >>"$TMP/ftl.log" ;; esac; }
port_owner() { return 1; }
systemctl() { :; }
: >"$TMP/ftl.log"
PIHOLE_WEB_PORT=8080 pihole_apply_web_port >/dev/null
assert_eq "native: the HTTP entries move and the TLS entries stay" "--config webserver.port 8080o,443os,[::]:8080o,[::]:443os" "$(cat "$TMP/ftl.log")"
: >"$TMP/ftl.log"
PIHOLE_WEB_PORT=80 pihole_apply_web_port >/dev/null
assert_eq "native: the current port changes nothing" "" "$(cat "$TMP/ftl.log")"
unset -f pihole-FTL port_owner systemctl

# --- PIHOLE_DNS: real addresses and ports only ---------------------------------
for ok in 1.1.1.1 9.9.9.9#5353 2606:4700:4700::1111 'fe80::1#53' '::1' 2001:db8:0:0:0:0:0:1 '2001:db8::'; do
  assert_ok "upstream '$ok' is accepted" pihole_valid_upstream "$ok"
done
for bad in ..... 1.2.3 1.1.1.1#99999 1.1.1.1#0 1.1.1.1# '1.1.1.1#53#5' 'dns.example' ':1' '1::2::3' '2001:db8:::1' '12345::1' '1:2:3:4:5:6:7:8:9' '1:2:3:4:5:6:7' '1.1.1.1#5a'; do
  assert_fails "upstream '$bad' is refused" pihole_valid_upstream "$bad"
done
assert_contains "a bad PIHOLE_DNS names the entry" "PIHOLE_DNS: '1.2.3' is not an IPv4 or IPv6 address" \
  "$( (PIHOLE_DNS='1.1.1.1,1.2.3'; declare -a d; pihole_dns_list d) 2>&1 || true)"

# --- PIHOLE_DOCKER: generated password saved before the container starts -----
export RPI_SETUP_CONTAINER_ROOT="$TMP/opt"
stub_container_helpers
container_copy_once() { return 1; }
save_secret() { printf '%s=%s\n' "$2" "$3" >>"$TMP/saved"; }
container_up() { echo "container_up saved=[$(cat "$TMP/saved" 2>/dev/null)]"; exit 1; }  # dies like a failed start

out="$( (unset PIHOLE_PASSWORD; PIHOLE_WEB_PORT=8080 run_pihole_container lo 1.1.1.1) 2>&1 || true)"
saved="$(sed -nE 's/^PIHOLE_PASSWORD=//p' "$TMP/saved" 2>/dev/null || true)"
assert_ok "a generated password is saved" test -n "$saved"
assert_contains "it is saved before container_up" "container_up saved=[PIHOLE_PASSWORD=$saved]" "$out"
assert_contains "it is printed even when the start fails" "Generated web admin password: $saved" "$out"

rm -f "$TMP/saved"
out="$( (PIHOLE_PASSWORD=given PIHOLE_WEB_PORT=8080 run_pihole_container lo 1.1.1.1) 2>&1 || true)"
assert_eq "PIHOLE_PASSWORD is not saved as generated" "" "$(cat "$TMP/saved" 2>/dev/null || true)"

# --- the image is pulled first, then native FTL stops, then /etc/pihole is copied
container_pull() { echo pull >>"$TMP/order"; }
container_stop_native() { echo "stop $2" >>"$TMP/order"; }
container_copy_once() { echo copy >>"$TMP/order"; return 1; }
container_up() { echo up >>"$TMP/order"; exit 1; }
(PIHOLE_PASSWORD=given PIHOLE_WEB_PORT=8080 run_pihole_container lo 1.1.1.1) >/dev/null 2>&1 || true
assert_eq "pull, then stop native FTL, then copy its data, then start" \
  $'pull\nstop pihole-FTL\ncopy\nup' "$(cat "$TMP/order")"
assert_eq "secrets.env exists before the pull (Compose needs it)" "600" "$(stat -c %a "$TMP/opt/pihole/secrets.env")"

finish_tests
