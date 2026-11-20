#!/usr/bin/env bash
# Task: gateway - an HTTPS gateway (Caddy in Docker) that takes requests from
# the internet on 443 and passes them on, encrypted, to one app on another
# machine in the LAN, trusting only that app's pinned certificate.
# Settings: GATEWAY_* in config/rpi-setup.env (names in config/tasks/gateway.env).
set -euo pipefail
. "$RPI_SETUP_ROOT/lib/containers.sh"

TASKS+=("gateway|HTTPS gateway: :443 with Let's Encrypt, forwarded encrypted to an app in the LAN")

run_gateway() {
  : "${GATEWAY_UPSTREAM_PORT:=443}" "${GATEWAY_IMAGE:=caddy:2}"
  local domain up name fp="" email="${GATEWAY_EMAIL:-}"
  domain="$(gateway_domain "${GATEWAY_DOMAIN:-}")" ||
    die "Set GATEWAY_DOMAIN to the public name of this Pi, such as app.example.org (got '${GATEWAY_DOMAIN:-}'): it must point to your router's public address, and the router must forward TCP 443 to the Pi"
  up="${GATEWAY_UPSTREAM:-}"
  gateway_host_ok "$up" ||
    die "Set GATEWAY_UPSTREAM to the address of the machine the app runs on, such as 192.168.1.30 (got '$up')"
  require_port GATEWAY_UPSTREAM_PORT
  name="${GATEWAY_UPSTREAM_NAME:-}"
  [[ -z "$name" ]] || [[ "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] ||
    die "GATEWAY_UPSTREAM_NAME must be a host name, such as app, or empty (got '$name')"
  if [[ -n "${GATEWAY_UPSTREAM_FINGERPRINT:-}" ]]; then
    fp="$(gateway_fingerprint_norm "$GATEWAY_UPSTREAM_FINGERPRINT")" ||
      die "GATEWAY_UPSTREAM_FINGERPRINT must be the SHA-256 fingerprint of the app's certificate, 64 hex digits with or without colons (got '$GATEWAY_UPSTREAM_FINGERPRINT')"
  fi
  [[ -z "$email" || "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] ||
    die "GATEWAY_EMAIL must be an email address or empty (got '$email')"
  require_image_ref GATEWAY_IMAGE
  gateway_check_port
  container_require_docker
  have openssl || apt_install openssl

  local dir changed=0
  dir="$(container_dir gateway)"
  install -m 0755 -d "$dir" "$dir/data" "$dir/config"
  gateway_compose "$GATEWAY_IMAGE" | write_if_changed "$dir/docker-compose.yml" 0644 || true
  # Pulled before the files the container mounts change, so a failed pull
  # leaves them as the running container has them, and the next run still
  # sees the change and recreates it.
  container_pull "$dir"
  gateway_upstream_cert "$dir/upstream-cert.pem" "$up" "$GATEWAY_UPSTREAM_PORT" "$fp" "$name" && changed=1
  if gateway_caddyfile "$domain" "$up" "$GATEWAY_UPSTREAM_PORT" "$email" "$name" | write_if_changed "$dir/Caddyfile" 0644; then
    changed=1
  fi
  container_up "$dir" gateway "$changed"

  if have curl; then
    if gateway_probe "$dir/upstream-cert.pem" "$up" "$GATEWAY_UPSTREAM_PORT" "$name" 8; then
      say "The Pi reaches the app at $up:$GATEWAY_UPSTREAM_PORT, encrypted, with the pinned certificate"
    else
      warn "The app at $up:$GATEWAY_UPSTREAM_PORT does not answer yet; the gateway forwards to it as soon as it does"
    fi
  fi
  say "Gateway: https://$domain (the certificate from Let's Encrypt can take a minute; see: docker logs gateway)"
  info 'The router must forward TCP 443 to this Pi; Let'"'"'s Encrypt checks the name over that port too.'
}

# --- gateway helpers (unit tested in ci/test-task-gateway.sh) ----------------

# Print $1 lowercased if it is a fully qualified DNS name (at least one dot,
# a top-level domain of letters); false otherwise.
gateway_domain() {
  local d="${1,,}"
  [[ ${#d} -le 253 && "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || return 1
  printf '%s\n' "$d"
}

# True if $1 is an IPv4 address or a host name.
gateway_host_ok() {
  valid_ipv4 "$1" || [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]
}

# Print SHA-256 fingerprint $1 as 64 lowercase hex digits (colons, spaces and
# an "sha256 Fingerprint=" prefix as openssl prints it are dropped); false if
# it is not one.
gateway_fingerprint_norm() {
  local f="${1#*=}"
  f="${f//[: ]/}"
  f="${f,,}"
  [[ "$f" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$f"
}

# SHA-256 fingerprint of PEM certificate file $1, normalized.
gateway_fingerprint_of() {
  local out
  out="$(openssl x509 -noout -fingerprint -sha256 -in "$1" 2>/dev/null)" || return 1
  gateway_fingerprint_norm "$out"
}

# gateway_probe CERT HOST PORT [NAME] [SECONDS] - true if the app at
# HOST:PORT answers HTTPS with the pinned certificate CERT (checked for NAME,
# or for HOST when NAME is empty). Any HTTP answer counts.
gateway_probe() {
  local cert="$1" host="$2" port="$3" name="${4:-$2}" t="${5:-8}"
  curl -sS -o /dev/null --connect-timeout 3 --max-time "$t" --cacert "$cert" \
    --connect-to "$name:$port:$host:$port" "https://$name:$port/" 2>/dev/null
}

# gateway_upstream_cert FILE HOST PORT FINGERPRINT [NAME] - pin the app's
# certificate in FILE. Kept as it is when it exists and matches FINGERPRINT
# (or FINGERPRINT is empty); otherwise fetched from HOST:PORT and, with
# FINGERPRINT, only accepted when it matches. Without it the first one seen is
# trusted and its fingerprint printed to compare. Returns 0 when FILE changed.
gateway_upstream_cert() {
  local file="$1" host="$2" port="$3" want="$4" name="${5:-}" have_fp="" tmp got
  if [[ -s "$file" ]]; then
    have_fp="$(gateway_fingerprint_of "$file")" || have_fp=""
    if [[ -n "$have_fp" && ( -z "$want" || "$have_fp" == "$want" ) ]]; then
      return 1
    fi
  fi
  tmp="$(mktemp)"
  if ! gateway_fetch_cert "$host" "$port" "$name" >"$tmp" || ! got="$(gateway_fingerprint_of "$tmp")"; then
    rm -f "$tmp"
    die "Could not read the certificate of the app at $host:$port. Check that it runs there, answers HTTPS on that port and lets this Pi in"
  fi
  if [[ -n "$want" && "$got" != "$want" ]]; then
    rm -f "$tmp"
    die "The app at $host:$port shows a certificate with the fingerprint $got, but GATEWAY_UPSTREAM_FINGERPRINT is $want. Compare them with: openssl x509 -noout -fingerprint -sha256 -in <the app's certificate>"
  fi
  install -m 0644 "$tmp" "$file"
  rm -f "$tmp"
  if [[ -n "$want" ]]; then
    say "Pinned the app's certificate ($got, as in GATEWAY_UPSTREAM_FINGERPRINT)"
  else
    warn "Pinned the certificate the app shows now, SHA-256 $got"
    warn 'Compare it on the app'"'"'s machine (openssl x509 -noout -fingerprint -sha256 -in <its certificate>) and put it into GATEWAY_UPSTREAM_FINGERPRINT'
  fi
  return 0
}

# gateway_fetch_cert HOST PORT [NAME] - print the certificate the app at
# HOST:PORT presents (asked for NAME, if given), as PEM.
gateway_fetch_cert() {
  local -a sni=()
  [[ -z "${3:-}" ]] || sni=(-servername "$3")
  timeout 15 openssl s_client -connect "$1:$2" "${sni[@]}" </dev/null 2>/dev/null |
    openssl x509 -outform PEM 2>/dev/null
}

# gateway_caddyfile DOMAIN HOST PORT [EMAIL] [NAME] - Caddy's configuration:
# HTTPS for DOMAIN on 443 with a certificate from Let's Encrypt, proven over
# 443 itself (TLS-ALPN), so port 80 stays with the web task or Pi-hole; no
# redirect from port 80 either. Everything goes to the app at HOST:PORT over
# HTTPS, trusting only the pinned certificate, checked for NAME (or HOST).
# Caddy sets X-Forwarded-For to the client's address (it trusts no incoming
# one), so the app can see who is calling. No admin API.
gateway_caddyfile() {
  local domain="$1" host="$2" port="$3" email="${4:-}" name="${5:-}"
  printf '# Managed by rpi-setup (tasks/gateway.sh); changes are overwritten.\n{\n'
  # Only HTTP/1.1 and HTTP/2: HTTP/3 would need UDP 443 open on the router
  # and the firewall, and browsers would try it first for nothing.
  printf '\tadmin off\n\tauto_https disable_redirects\n\tservers {\n\t\tprotocols h1 h2\n\t}\n'
  [[ -z "$email" ]] || printf '\temail %s\n' "$email"
  cat <<EOF
}

$domain:443 {
	tls {
		issuer acme {
			disable_http_challenge
		}
	}
	reverse_proxy https://$host:$port {
		transport http {
			tls_trust_pool file /etc/caddy/upstream-cert.pem
EOF
  [[ -z "$name" ]] || printf '\t\t\ttls_server_name %s\n' "$name"
  printf '\t\t}\n\t}\n}\n'
}

# gateway_compose IMAGE - the compose file: Caddy on the host's network (it
# needs no published port and sees the clients' real addresses), read-only,
# with only the capability to bind 443, its certificates in data/.
gateway_compose() {
  cat <<EOF
services:
  gateway:
    image: "$1"
    container_name: gateway
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./upstream-cert.pem:/etc/caddy/upstream-cert.pem:ro
      - ./data:/data
      - ./config:/config
    tmpfs:
      - /tmp
    read_only: true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    security_opt:
      - no-new-privileges:true
EOF
}

# Frees TCP 443 for the gateway: Pi-hole's admin page keeps plain HTTP and
# gives up its HTTPS listener, in its container or on the host. Dies when
# another program than the gateway's own Caddy holds the port.
gateway_check_port() {
  local owner
  owner="$(port_owner 443)" || return 0
  if [[ "$owner" == caddy ]] && task_in_container gateway; then
    return 0
  fi
  [[ "$owner" == pihole-FTL ]] ||
    die "Port 443 is used by '$owner'; the gateway needs it. Stop that program, then run this task again"
  gateway_pihole_off_443
}

# Move Pi-hole's admin page off 443: drop the HTTPS entries of its
# webserver.port, where Pi-hole takes it from (FTLCONF_webserver_port in
# its compose file, or its own setting), and restart it.
gateway_pihole_off_443() {
  local dir cur new
  info "Pi-hole's admin page holds port 443 for HTTPS; keeping it on plain HTTP so the gateway gets 443"
  if task_in_container pihole; then
    dir="$(container_dir pihole)"
    cur="$(sed -nE 's/^[[:space:]]*FTLCONF_webserver_port:[[:space:]]*"?([^"]*)"?.*/\1/p' "$dir/docker-compose.yml" | head -n1)" || cur=""
    new="$(pihole_without_tls "${cur:-$PH_DEFAULT_PORTS}")"
    if [[ -n "$cur" ]]; then
      sed -Ei "s/^([[:space:]]*FTLCONF_webserver_port:[[:space:]]*).*/\\1\"${new}\"/" "$dir/docker-compose.yml" ||
        die "Could not change Pi-hole's ports in $dir/docker-compose.yml"
      docker compose -f "$dir/docker-compose.yml" up -d >/dev/null || die 'Could not restart the Pi-hole container'
    else
      docker exec pihole pihole-FTL --config webserver.port "$new" >/dev/null ||
        die "Could not change Pi-hole's ports in its container"
      docker restart pihole >/dev/null || die 'Could not restart the Pi-hole container'
    fi
  else
    cur="$(pihole-FTL --config webserver.port 2>/dev/null)" || cur="$PH_DEFAULT_PORTS"
    new="$(pihole_without_tls "$cur")"
    pihole-FTL --config webserver.port "$new" >/dev/null || die "Could not set Pi-hole's web admin ports to '$new'"
    systemctl restart pihole-FTL || die 'Could not restart pihole-FTL'
  fi
  for _ in $(seq 1 30); do
    [[ "$(port_owner 443 || true)" == pihole-FTL ]] || break
    sleep 1
  done
  [[ "$(port_owner 443 || true)" != pihole-FTL ]] || die 'Pi-hole still holds port 443 after the change; see: sudo pihole-FTL --config webserver.port'
  say "Pi-hole's admin page now uses only plain HTTP ($new); port 443 is free for the gateway"
}
