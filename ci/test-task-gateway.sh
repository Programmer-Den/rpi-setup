#!/usr/bin/env bash
# test-task-gateway.sh - unit tests for tasks/gateway.sh: the settings it
# checks before anything changes, the Caddyfile and compose file it writes,
# the pinning of the app's certificate and freeing 443 from Pi-hole.
#
# Run: bash ci/test-task-gateway.sh
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
. "$ROOT/lib/common.sh"
TASKS=()
. "$ROOT/tasks/gateway.sh"

# --- gateway_domain -----------------------------------------------------------------
assert_eq "domain: lowercased" "app.example.org" "$(gateway_domain APP.Example.org)"
assert_eq "domain: router DDNS name" "my-app.asuscomm.com" "$(gateway_domain my-app.asuscomm.com)"
for bad in '' nas localhost 192.168.1.10 'app.example.org:443' 'https://app.example.org' '-a.example.org' \
  'a..example.org' 'app.example.org.' 'nas example.org' 'nas.example.1'; do
  assert_fails "domain: '$bad' refused" gateway_domain "$bad"
done

# --- gateway_fingerprint_norm -------------------------------------------------------
hex="ab01$(printf '%060d' 0)"
colons="$(sed 's/../&:/g; s/:$//' <<<"${hex^^}")"
assert_eq "fingerprint: bare hex" "$hex" "$(gateway_fingerprint_norm "$hex")"
assert_eq "fingerprint: colons and upper case" "$hex" "$(gateway_fingerprint_norm "$colons")"
assert_eq "fingerprint: as openssl prints it" "$hex" "$(gateway_fingerprint_norm "sha256 Fingerprint=$colons")"
for bad in '' abc "${hex}00" "${hex:2}" "zz${hex:2}"; do
  assert_fails "fingerprint: '$bad' refused" gateway_fingerprint_norm "$bad"
done

# --- pihole_without_tls / pihole_default_ports (lib/common.sh) ----------------------
assert_eq "pihole: HTTPS entries dropped" "80o,[::]:80o" "$(pihole_without_tls "$PH_DEFAULT_PORTS")"
assert_eq "pihole: moved HTTP port kept" "8080o,[::]:8080o" "$(pihole_without_tls '8080o,443os,[::]:8080o,[::]:443os')"
assert_eq "pihole: no HTTPS entry, unchanged" "80,8080r" "$(pihole_without_tls '80,8080r')"
assert_eq "pihole: defaults without the gateway keep HTTPS" "$PH_DEFAULT_PORTS" "$(RPI_SETUP_CONTAINER_ROOT="$TMP/none" pihole_default_ports)"
mkdir -p "$TMP/opt/gateway" && touch "$TMP/opt/gateway/docker-compose.yml"
assert_eq "pihole: defaults with the gateway leave 443 to it" "80o,[::]:80o" "$(RPI_SETUP_CONTAINER_ROOT="$TMP/opt" pihole_default_ports)"

# --- gateway_caddyfile / gateway_compose --------------------------------------------
cf="$(gateway_caddyfile app.example.org 192.168.1.30 8443 me@example.org app)"
assert_contains "caddyfile: the domain on 443" $'\napp.example.org:443 {' "$cf"
assert_contains "caddyfile: no admin API" $'\tadmin off' "$cf"
assert_contains "caddyfile: no redirect from port 80" $'\tauto_https disable_redirects' "$cf"
assert_contains "caddyfile: Let's Encrypt over 443 only" 'disable_http_challenge' "$cf"
assert_contains "caddyfile: email" $'\temail me@example.org' "$cf"
assert_contains "caddyfile: no HTTP/3, as UDP 443 is not open" $'\t\tprotocols h1 h2' "$cf"
assert_contains "caddyfile: forwards to the app over HTTPS" 'reverse_proxy https://192.168.1.30:8443 {' "$cf"
assert_contains "caddyfile: trusts only the pinned certificate" 'tls_trust_pool file /etc/caddy/upstream-cert.pem' "$cf"
assert_contains "caddyfile: the name in the app's certificate" 'tls_server_name app' "$cf"
assert_lacks "caddyfile: no email line without one" 'email' "$(gateway_caddyfile app.example.org app-host 8443)"
assert_lacks "caddyfile: no server name without one (the address is checked)" 'tls_server_name' "$(gateway_caddyfile app.example.org app-host 8443)"
if command -v caddy >/dev/null 2>&1; then
  gateway_caddyfile app.example.org 192.168.1.30 8443 me@example.org app >"$TMP/Caddyfile"
  assert_ok "caddy accepts the Caddyfile" caddy adapt --config "$TMP/Caddyfile"
else
  skip "caddy adapt (caddy missing)"
fi

compose="$(gateway_compose caddy:2)"
assert_contains "compose: image" 'image: "caddy:2"' "$compose"
assert_contains "compose: container name" 'container_name: gateway' "$compose"
assert_contains "compose: host network" 'network_mode: host' "$compose"
assert_contains "compose: read-only" 'read_only: true' "$compose"
assert_contains "compose: only binding low ports" $'cap_add:\n      - NET_BIND_SERVICE' "$compose"
assert_contains "compose: Caddyfile read-only" './Caddyfile:/etc/caddy/Caddyfile:ro' "$compose"
assert_contains "compose: pinned certificate read-only" './upstream-cert.pem:/etc/caddy/upstream-cert.pem:ro' "$compose"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  assert_eq "compose: valid YAML" "gateway" \
    "$(printf '%s\n' "$compose" | python3 -c 'import sys,yaml; print(yaml.safe_load(sys.stdin)["services"]["gateway"]["container_name"])')"
else
  skip "compose YAML parse (python3 yaml module missing)"
fi

# --- settings are checked before anything changes -----------------------------------
container_require_docker() { echo "docker needed" >"$TMP/reached"; exit 1; }
port_owner() { return 1; }
run_with() { rm -f "$TMP/reached"; ( for kv in "$@"; do export "${kv?}"; done; run_gateway ) >/dev/null 2>"$TMP/err" || true; }
run_with GATEWAY_UPSTREAM=192.168.1.30
assert_contains "no domain stops the task" "Set GATEWAY_DOMAIN" "$(cat "$TMP/err")"
assert_ok "no domain: Docker was not touched" test ! -e "$TMP/reached"
run_with GATEWAY_DOMAIN=app.example.org
assert_contains "no upstream stops the task" "Set GATEWAY_UPSTREAM" "$(cat "$TMP/err")"
run_with GATEWAY_DOMAIN=app.example.org GATEWAY_UPSTREAM='1.2.3.4;rm'
assert_contains "a bad upstream address stops the task" "Set GATEWAY_UPSTREAM" "$(cat "$TMP/err")"
run_with GATEWAY_DOMAIN=app.example.org GATEWAY_UPSTREAM=192.168.1.30 GATEWAY_UPSTREAM_PORT=70000
assert_contains "a bad upstream port stops the task" "GATEWAY_UPSTREAM_PORT must be a port number" "$(cat "$TMP/err")"
run_with GATEWAY_DOMAIN=app.example.org GATEWAY_UPSTREAM=192.168.1.30 GATEWAY_UPSTREAM_NAME='a b'
assert_contains "a bad certificate name stops the task" "GATEWAY_UPSTREAM_NAME must be" "$(cat "$TMP/err")"
run_with GATEWAY_DOMAIN=app.example.org GATEWAY_UPSTREAM=192.168.1.30 GATEWAY_UPSTREAM_FINGERPRINT=abc
assert_contains "a bad fingerprint stops the task" "GATEWAY_UPSTREAM_FINGERPRINT must be" "$(cat "$TMP/err")"
run_with GATEWAY_DOMAIN=app.example.org GATEWAY_UPSTREAM=192.168.1.30 GATEWAY_EMAIL='a b@c'
assert_contains "a bad email stops the task" "GATEWAY_EMAIL must be" "$(cat "$TMP/err")"
assert_ok "bad settings: Docker was not touched" test ! -e "$TMP/reached"
run_with GATEWAY_DOMAIN=app.example.org GATEWAY_UPSTREAM=app-host GATEWAY_UPSTREAM_NAME=app GATEWAY_UPSTREAM_FINGERPRINT="$colons" GATEWAY_EMAIL=me@example.org
assert_ok "good settings go on to Docker" test -e "$TMP/reached"
port_owner() { echo nginx; }
run_with GATEWAY_DOMAIN=app.example.org GATEWAY_UPSTREAM=192.168.1.30
assert_contains "a taken port 443 stops the task" "Port 443 is used by 'nginx'" "$(cat "$TMP/err")"
assert_ok "a taken port: Docker was not touched" test ! -e "$TMP/reached"
port_owner() { echo caddy; }
task_in_container() { return 1; }
run_with GATEWAY_DOMAIN=app.example.org GATEWAY_UPSTREAM=192.168.1.30
assert_contains "another Caddy on 443 stops the task" "Port 443 is used by 'caddy'" "$(cat "$TMP/err")"
task_in_container() { [[ "$1" == gateway ]]; }
run_with GATEWAY_DOMAIN=app.example.org GATEWAY_UPSTREAM=192.168.1.30
assert_ok "the gateway's own Caddy on 443 is fine" test -e "$TMP/reached"

# Pi-hole on 443 is moved to plain HTTP, on the host and in its container.
echo 443 >"$TMP/held"
port_owner() { [[ "$(cat "$TMP/held")" == "$1" ]] && echo pihole-FTL; }
pihole-FTL() { if [[ $# -eq 2 ]]; then echo '8080o,443os,[::]:8080o,[::]:443os'; else echo "$3" >"$TMP/set"; fi; }
systemctl() { echo none >"$TMP/held"; }
task_in_container() { return 1; }
run_with GATEWAY_DOMAIN=app.example.org GATEWAY_UPSTREAM=192.168.1.30
assert_eq "Pi-hole on the host keeps plain HTTP" "8080o,[::]:8080o" "$(cat "$TMP/set" 2>/dev/null)"
assert_ok "and the task goes on" test -e "$TMP/reached"
echo 443 >"$TMP/held"
RPI_SETUP_CONTAINER_ROOT="$TMP/opt"
mkdir -p "$TMP/opt/pihole"
printf 'services:\n  pihole:\n    environment:\n      FTLCONF_webserver_port: "80o,443os,[::]:80o,[::]:443os"\n' >"$TMP/opt/pihole/docker-compose.yml"
docker() { echo none >"$TMP/held"; }
task_in_container() { [[ "$1" == pihole ]]; }
run_with GATEWAY_DOMAIN=app.example.org GATEWAY_UPSTREAM=192.168.1.30
assert_contains "Pi-hole in Docker: its compose file keeps plain HTTP" 'FTLCONF_webserver_port: "80o,[::]:80o"' "$(cat "$TMP/opt/pihole/docker-compose.yml")"
assert_ok "and the task goes on" test -e "$TMP/reached"
unset RPI_SETUP_CONTAINER_ROOT
unset -f pihole-FTL systemctl docker
unset -f container_require_docker port_owner pihole_ftl task_in_container run_with

# --- gateway_upstream_cert ----------------------------------------------------------------
if command -v openssl >/dev/null 2>&1; then
  mkcert() {
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 \
      -subj /CN=app -addext subjectAltName=DNS:app -keyout "$TMP/$1.key" -out "$TMP/$1.pem" 2>/dev/null
  }
  mkcert one; mkcert two
  fp1="$(gateway_fingerprint_of "$TMP/one.pem")"
  fp2="$(gateway_fingerprint_of "$TMP/two.pem")"
  assert_ok "fingerprint_of gives 64 hex digits" test "${#fp1}" -eq 64
  serving=one
  gateway_fetch_cert() { cat "$TMP/$serving.pem"; }
  pin="$TMP/upstream-cert.pem"

  out="$(gateway_upstream_cert "$pin" app-host 8443 "" 2>&1)" && rc=0 || rc=$?
  assert_eq "pin: first run pins what the app shows" "0 $fp1" "$rc $(gateway_fingerprint_of "$pin")"
  assert_contains "pin: first run prints the fingerprint to compare" "$fp1" "$out"
  serving=two
  gateway_upstream_cert "$pin" app-host 8443 "" >/dev/null 2>&1 && rc=0 || rc=$?
  assert_eq "pin: without a fingerprint the pinned one stays" "1 $fp1" "$rc $(gateway_fingerprint_of "$pin")"
  gateway_upstream_cert "$pin" app-host 8443 "$fp1" >/dev/null 2>&1 && rc=0 || rc=$?
  assert_eq "pin: a matching fingerprint keeps it" "1 $fp1" "$rc $(gateway_fingerprint_of "$pin")"
  ( gateway_upstream_cert "$pin" app-host 8443 "$hex" ) >/dev/null 2>"$TMP/err" && rc=0 || rc=$?
  assert_contains "pin: an app with another certificate stops the task" "but GATEWAY_UPSTREAM_FINGERPRINT is $hex" "$(cat "$TMP/err")"
  assert_eq "pin: and keeps the pinned one" "$fp1" "$(gateway_fingerprint_of "$pin")"
  gateway_upstream_cert "$pin" app-host 8443 "$fp2" >/dev/null 2>&1 && rc=0 || rc=$?
  assert_eq "pin: a new fingerprint pins the app's new certificate" "0 $fp2" "$rc $(gateway_fingerprint_of "$pin")"
  rm -f "$pin"
  gateway_fetch_cert() { return 1; }
  ( gateway_upstream_cert "$pin" app-host 8443 "" ) >/dev/null 2>"$TMP/err" || true
  assert_contains "pin: an unreachable app stops the task" "Could not read the certificate of the app at app-host:8443" "$(cat "$TMP/err")"
  assert_ok "pin: nothing pinned then" test ! -e "$pin"
else
  skip "certificate pinning (openssl missing)"
fi

finish_tests
