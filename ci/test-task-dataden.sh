#!/usr/bin/env bash
# test-task-dataden.sh - unit tests for tasks/dataden.sh: the settings it
# checks before anything changes, the Caddyfile and compose file it writes,
# the pinning of the storage VM's certificate and the Pi-hole port hint.
#
# Run: bash ci/test-task-dataden.sh
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
. "$ROOT/lib/common.sh"
TASKS=()
. "$ROOT/tasks/dataden.sh"

# --- dataden_domain -----------------------------------------------------------------
assert_eq "domain: lowercased" "nas.example.org" "$(dataden_domain NAS.Example.org)"
assert_eq "domain: router DDNS name" "my-nas.asuscomm.com" "$(dataden_domain my-nas.asuscomm.com)"
for bad in '' nas localhost 192.168.1.10 'nas.example.org:443' 'https://nas.example.org' '-a.example.org' \
  'a..example.org' 'nas.example.org.' 'nas example.org' 'nas.example.1'; do
  assert_fails "domain: '$bad' refused" dataden_domain "$bad"
done

# --- dataden_fingerprint_norm -------------------------------------------------------
hex="ab01$(printf '%060d' 0)"
colons="$(sed 's/../&:/g; s/:$//' <<<"${hex^^}")"
assert_eq "fingerprint: bare hex" "$hex" "$(dataden_fingerprint_norm "$hex")"
assert_eq "fingerprint: colons and upper case" "$hex" "$(dataden_fingerprint_norm "$colons")"
assert_eq "fingerprint: as openssl prints it" "$hex" "$(dataden_fingerprint_norm "sha256 Fingerprint=$colons")"
for bad in '' abc "${hex}00" "${hex:2}" "zz${hex:2}"; do
  assert_fails "fingerprint: '$bad' refused" dataden_fingerprint_norm "$bad"
done

# --- dataden_pihole_without_tls -----------------------------------------------------
assert_eq "pihole: HTTPS entries dropped" "80o,[::]:80o" "$(dataden_pihole_without_tls "$PH_DEFAULT_PORTS")"
assert_eq "pihole: moved HTTP port kept" "8080o,[::]:8080o" "$(dataden_pihole_without_tls '8080o,443os,[::]:8080o,[::]:443os')"
assert_eq "pihole: no HTTPS entry, unchanged" "80,8080r" "$(dataden_pihole_without_tls '80,8080r')"

# --- dataden_caddyfile / dataden_compose --------------------------------------------
cf="$(dataden_caddyfile nas.example.org 192.168.1.30 8443 me@example.org)"
assert_contains "caddyfile: the domain on 443" $'\nnas.example.org:443 {' "$cf"
assert_contains "caddyfile: no admin API" $'\tadmin off' "$cf"
assert_contains "caddyfile: no redirect from port 80" $'\tauto_https disable_redirects' "$cf"
assert_contains "caddyfile: Let's Encrypt over 443 only" 'disable_http_challenge' "$cf"
assert_contains "caddyfile: email" $'\temail me@example.org' "$cf"
assert_contains "caddyfile: forwards to the VM over HTTPS" 'reverse_proxy https://192.168.1.30:8443 {' "$cf"
assert_contains "caddyfile: trusts only the pinned certificate" 'tls_trust_pool file /etc/caddy/vm-cert.pem' "$cf"
assert_contains "caddyfile: the name in the VM's certificate" 'tls_server_name data-den' "$cf"
assert_lacks "caddyfile: no email line without one" 'email' "$(dataden_caddyfile nas.example.org vm 8443)"
if command -v caddy >/dev/null 2>&1; then
  dataden_caddyfile nas.example.org 192.168.1.30 8443 me@example.org >"$TMP/Caddyfile"
  assert_ok "caddy accepts the Caddyfile" caddy adapt --config "$TMP/Caddyfile"
else
  skip "caddy adapt (caddy missing)"
fi

compose="$(dataden_compose caddy:2)"
assert_contains "compose: image" 'image: "caddy:2"' "$compose"
assert_contains "compose: container name" 'container_name: dataden' "$compose"
assert_contains "compose: host network" 'network_mode: host' "$compose"
assert_contains "compose: read-only" 'read_only: true' "$compose"
assert_contains "compose: only binding low ports" $'cap_add:\n      - NET_BIND_SERVICE' "$compose"
assert_contains "compose: Caddyfile read-only" './Caddyfile:/etc/caddy/Caddyfile:ro' "$compose"
assert_contains "compose: pinned certificate read-only" './vm-cert.pem:/etc/caddy/vm-cert.pem:ro' "$compose"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  assert_eq "compose: valid YAML" "dataden" \
    "$(printf '%s\n' "$compose" | python3 -c 'import sys,yaml; print(yaml.safe_load(sys.stdin)["services"]["dataden"]["container_name"])')"
else
  skip "compose YAML parse (python3 yaml module missing)"
fi

# --- settings are checked before anything changes -----------------------------------
container_require_docker() { echo "docker needed" >"$TMP/reached"; exit 1; }
port_owner() { return 1; }
run_with() { rm -f "$TMP/reached"; ( for kv in "$@"; do export "${kv?}"; done; run_dataden ) >/dev/null 2>"$TMP/err" || true; }
run_with DATADEN_VM=192.168.1.30
assert_contains "no domain stops the task" "Set DATADEN_DOMAIN" "$(cat "$TMP/err")"
assert_ok "no domain: Docker was not touched" test ! -e "$TMP/reached"
run_with DATADEN_DOMAIN=nas.example.org
assert_contains "no VM stops the task" "Set DATADEN_VM" "$(cat "$TMP/err")"
run_with DATADEN_DOMAIN=nas.example.org DATADEN_VM='1.2.3.4;rm'
assert_contains "a bad VM address stops the task" "Set DATADEN_VM" "$(cat "$TMP/err")"
run_with DATADEN_DOMAIN=nas.example.org DATADEN_VM=192.168.1.30 DATADEN_VM_PORT=70000
assert_contains "a bad VM port stops the task" "DATADEN_VM_PORT must be a port number" "$(cat "$TMP/err")"
run_with DATADEN_DOMAIN=nas.example.org DATADEN_VM=192.168.1.30 DATADEN_VM_FINGERPRINT=abc
assert_contains "a bad fingerprint stops the task" "DATADEN_VM_FINGERPRINT must be" "$(cat "$TMP/err")"
run_with DATADEN_DOMAIN=nas.example.org DATADEN_VM=192.168.1.30 DATADEN_EMAIL='a b@c'
assert_contains "a bad email stops the task" "DATADEN_EMAIL must be" "$(cat "$TMP/err")"
assert_ok "bad settings: Docker was not touched" test ! -e "$TMP/reached"
run_with DATADEN_DOMAIN=nas.example.org DATADEN_VM=data-den-vm DATADEN_VM_FINGERPRINT="$colons" DATADEN_EMAIL=me@example.org
assert_ok "good settings go on to Docker" test -e "$TMP/reached"
port_owner() { echo nginx; }
run_with DATADEN_DOMAIN=nas.example.org DATADEN_VM=192.168.1.30
assert_contains "a taken port 443 stops the task" "Port 443 is used by 'nginx'" "$(cat "$TMP/err")"
assert_ok "a taken port: Docker was not touched" test ! -e "$TMP/reached"
port_owner() { echo pihole-FTL; }
pihole_ftl() { echo '8080o,443os,[::]:8080o,[::]:443os'; }
task_in_container() { return 1; }
run_with DATADEN_DOMAIN=nas.example.org DATADEN_VM=192.168.1.30
assert_contains "Pi-hole on 443: the command that frees it" \
  "sudo pihole-FTL --config webserver.port '8080o,[::]:8080o'" "$(cat "$TMP/err")"
port_owner() { echo caddy; }
run_with DATADEN_DOMAIN=nas.example.org DATADEN_VM=192.168.1.30
assert_ok "the gateway's own Caddy on 443 is fine" test -e "$TMP/reached"
unset -f container_require_docker port_owner pihole_ftl task_in_container run_with

# --- dataden_vm_cert ----------------------------------------------------------------
if command -v openssl >/dev/null 2>&1; then
  mkcert() {
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 \
      -subj /CN=data-den -addext subjectAltName=DNS:data-den -keyout "$TMP/$1.key" -out "$TMP/$1.pem" 2>/dev/null
  }
  mkcert one; mkcert two
  fp1="$(dataden_fingerprint_of "$TMP/one.pem")"
  fp2="$(dataden_fingerprint_of "$TMP/two.pem")"
  assert_ok "fingerprint_of gives 64 hex digits" test "${#fp1}" -eq 64
  serving=one
  dataden_fetch_cert() { cat "$TMP/$serving.pem"; }
  pin="$TMP/vm-cert.pem"

  out="$(dataden_vm_cert "$pin" vm 8443 "" 2>&1)" && rc=0 || rc=$?
  assert_eq "pin: first run pins what the VM shows" "0 $fp1" "$rc $(dataden_fingerprint_of "$pin")"
  assert_contains "pin: first run prints the fingerprint to compare" "$fp1" "$out"
  serving=two
  dataden_vm_cert "$pin" vm 8443 "" >/dev/null 2>&1 && rc=0 || rc=$?
  assert_eq "pin: without a fingerprint the pinned one stays" "1 $fp1" "$rc $(dataden_fingerprint_of "$pin")"
  dataden_vm_cert "$pin" vm 8443 "$fp1" >/dev/null 2>&1 && rc=0 || rc=$?
  assert_eq "pin: a matching fingerprint keeps it" "1 $fp1" "$rc $(dataden_fingerprint_of "$pin")"
  ( dataden_vm_cert "$pin" vm 8443 "$hex" ) >/dev/null 2>"$TMP/err" && rc=0 || rc=$?
  assert_contains "pin: a VM with another certificate stops the task" "but DATADEN_VM_FINGERPRINT is $hex" "$(cat "$TMP/err")"
  assert_eq "pin: and keeps the pinned one" "$fp1" "$(dataden_fingerprint_of "$pin")"
  dataden_vm_cert "$pin" vm 8443 "$fp2" >/dev/null 2>&1 && rc=0 || rc=$?
  assert_eq "pin: a new fingerprint pins the VM's new certificate" "0 $fp2" "$rc $(dataden_fingerprint_of "$pin")"
  rm -f "$pin"
  dataden_fetch_cert() { return 1; }
  ( dataden_vm_cert "$pin" vm 8443 "" ) >/dev/null 2>"$TMP/err" || true
  assert_contains "pin: an unreachable VM stops the task" "Could not read the certificate of DATA-DEN at vm:8443" "$(cat "$TMP/err")"
  assert_ok "pin: nothing pinned then" test ! -e "$pin"
else
  skip "certificate pinning (openssl missing)"
fi

finish_tests
