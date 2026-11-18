#!/usr/bin/env bash
# Task: dataden - the HTTPS gateway of DATA-DEN, the NAS in a storage VM on
# another machine (Caddy in Docker).
# Settings: DATADEN_* in config/rpi-setup.env (names in config/tasks/dataden.env).
set -euo pipefail
. "$RPI_SETUP_ROOT/lib/containers.sh"

TASKS+=("dataden|DATA-DEN gateway: HTTPS on :443 with Let's Encrypt, forwarded to the storage VM")

# The name in the storage VM's certificate (DATA-DEN's deploy/README.md makes
# it with subjectAltName DNS:data-den).
dataden_vm_name=data-den

run_dataden() {
  : "${DATADEN_VM_PORT:=8443}" "${DATADEN_IMAGE:=caddy:2}"
  local domain vm fp="" email="${DATADEN_EMAIL:-}"
  domain="$(dataden_domain "${DATADEN_DOMAIN:-}")" ||
    die "Set DATADEN_DOMAIN to the public name of this Pi, such as nas.example.org (got '${DATADEN_DOMAIN:-}'): it must point to your router's public address, and the router must forward TCP 443 to the Pi"
  vm="${DATADEN_VM:-}"
  valid_ipv4 "$vm" || [[ "$vm" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] ||
    die "Set DATADEN_VM to the storage VM's address, such as 192.168.1.30 (got '$vm')"
  require_port DATADEN_VM_PORT
  if [[ -n "${DATADEN_VM_FINGERPRINT:-}" ]]; then
    fp="$(dataden_fingerprint_norm "$DATADEN_VM_FINGERPRINT")" ||
      die "DATADEN_VM_FINGERPRINT must be the SHA-256 fingerprint of the VM's certificate, 64 hex digits with or without colons (got '$DATADEN_VM_FINGERPRINT')"
  fi
  [[ -z "$email" || "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] ||
    die "DATADEN_EMAIL must be an email address or empty (got '$email')"
  require_image_ref DATADEN_IMAGE
  dataden_check_port
  container_require_docker
  have openssl || apt_install openssl

  local dir changed=0
  dir="$(container_dir dataden)"
  install -m 0755 -d "$dir" "$dir/data" "$dir/config"
  dataden_vm_cert "$dir/vm-cert.pem" "$vm" "$DATADEN_VM_PORT" "$fp" && changed=1
  if dataden_caddyfile "$domain" "$vm" "$DATADEN_VM_PORT" "$email" | write_if_changed "$dir/Caddyfile" 0644; then
    changed=1
  fi
  dataden_compose "$DATADEN_IMAGE" | write_if_changed "$dir/docker-compose.yml" 0644 || true

  container_pull "$dir"
  container_up "$dir" dataden "$changed"

  if have curl; then
    if curl -sS -o /dev/null --max-time 8 --cacert "$dir/vm-cert.pem" \
      --connect-to "$dataden_vm_name:$DATADEN_VM_PORT:$vm:$DATADEN_VM_PORT" \
      "https://$dataden_vm_name:$DATADEN_VM_PORT/api/health"; then
      say "The Pi reaches DATA-DEN in the VM at $vm:$DATADEN_VM_PORT, encrypted, with the pinned certificate"
    else
      warn "DATA-DEN in the VM ($vm:$DATADEN_VM_PORT) does not answer yet; the gateway forwards to it as soon as it does"
    fi
  fi
  say "DATA-DEN: https://$domain (the certificate from Let's Encrypt can take a minute; see: docker logs dataden)"
  info 'The router must forward TCP 443 to this Pi; Let'"'"'s Encrypt checks the name over that port too.'
}

# --- dataden helpers (unit tested in ci/test-task-dataden.sh) ----------------

# Print $1 lowercased if it is a fully qualified DNS name (at least one dot,
# a top-level domain of letters); false otherwise.
dataden_domain() {
  local d="${1,,}"
  [[ ${#d} -le 253 && "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || return 1
  printf '%s\n' "$d"
}

# Print SHA-256 fingerprint $1 as 64 lowercase hex digits (colons, spaces and
# an "sha256 Fingerprint=" prefix as openssl prints it are dropped); false if
# it is not one.
dataden_fingerprint_norm() {
  local f="${1#*=}"
  f="${f//[: ]/}"
  f="${f,,}"
  [[ "$f" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$f"
}

# SHA-256 fingerprint of PEM certificate file $1, normalized.
dataden_fingerprint_of() {
  local out
  out="$(openssl x509 -noout -fingerprint -sha256 -in "$1" 2>/dev/null)" || return 1
  dataden_fingerprint_norm "$out"
}

# Pin the VM's certificate in $1. Kept as it is when it exists and matches
# fingerprint $4 (or $4 is empty); otherwise fetched from $2:$3 and, with $4,
# only accepted when it matches. Without $4 the first one seen is trusted and
# its fingerprint printed to compare. Returns 0 when $1 changed.
dataden_vm_cert() {
  local file="$1" vm="$2" port="$3" want="$4" have_fp="" tmp got
  if [[ -s "$file" ]]; then
    have_fp="$(dataden_fingerprint_of "$file")" || have_fp=""
    if [[ -n "$have_fp" && ( -z "$want" || "$have_fp" == "$want" ) ]]; then
      return 1
    fi
  fi
  tmp="$(mktemp)"
  if ! dataden_fetch_cert "$vm" "$port" >"$tmp" || ! got="$(dataden_fingerprint_of "$tmp")"; then
    rm -f "$tmp"
    die "Could not read the certificate of DATA-DEN at $vm:$port. Check that DATA-DEN runs in the VM (sudo docker compose ps there) and that the VM lets this Pi in (vm/setup-firewall.sh <this Pi's address> in DATA-DEN)"
  fi
  if [[ -n "$want" && "$got" != "$want" ]]; then
    rm -f "$tmp"
    die "The VM at $vm:$port shows a certificate with the fingerprint $got, but DATADEN_VM_FINGERPRINT is $want. Compare them with: openssl x509 -noout -fingerprint -sha256 -in tls/cert.pem (in the VM's DATA-DEN folder)"
  fi
  install -m 0644 "$tmp" "$file"
  rm -f "$tmp"
  if [[ -n "$want" ]]; then
    say "Pinned the VM's certificate ($got, as in DATADEN_VM_FINGERPRINT)"
  else
    warn "Pinned the certificate the VM shows now, SHA-256 $got"
    warn 'Compare it in the VM: openssl x509 -noout -fingerprint -sha256 -in tls/cert.pem, and put it into DATADEN_VM_FINGERPRINT'
  fi
  return 0
}

# Print the certificate DATA-DEN at $1:$2 presents, as PEM.
dataden_fetch_cert() {
  timeout 15 openssl s_client -connect "$1:$2" -servername "$dataden_vm_name" </dev/null 2>/dev/null |
    openssl x509 -outform PEM 2>/dev/null
}

# dataden_caddyfile DOMAIN VM VM_PORT [EMAIL] - Caddy's configuration: HTTPS
# for DOMAIN on 443 with a certificate from Let's Encrypt, proven over 443
# itself (TLS-ALPN), so port 80 stays with the web task or Pi-hole; no
# redirect from port 80 either. Everything goes to DATA-DEN in the VM over
# HTTPS, trusting only the pinned certificate. Caddy sets X-Forwarded-For to
# the client's address (it trusts no incoming one), which DATA-DEN uses for
# its login limit as DATA_DEN_TRUSTED_PROXY says. No admin API.
dataden_caddyfile() {
  local domain="$1" vm="$2" port="$3" email="${4:-}"
  printf '# Managed by rpi-setup (tasks/dataden.sh); changes are overwritten.\n{\n'
  printf '\tadmin off\n\tauto_https disable_redirects\n'
  [[ -z "$email" ]] || printf '\temail %s\n' "$email"
  cat <<EOF
}

$domain:443 {
	tls {
		issuer acme {
			disable_http_challenge
		}
	}
	reverse_proxy https://$vm:$port {
		transport http {
			tls_trust_pool file /etc/caddy/vm-cert.pem
			tls_server_name $dataden_vm_name
		}
	}
}
EOF
}

# dataden_compose IMAGE - the compose file: Caddy on the host's network (it
# needs no published port and sees the clients' real addresses), read-only,
# with only the capability to bind 443, its certificates in data/.
dataden_compose() {
  cat <<EOF
services:
  dataden:
    image: "$1"
    container_name: dataden
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./vm-cert.pem:/etc/caddy/vm-cert.pem:ro
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

# Pi-hole's webserver.port list $1 without its HTTPS entries (flag "s"), so
# its admin page keeps plain HTTP and leaves 443 to the gateway.
dataden_pihole_without_tls() {
  local e out=""
  for e in ${1//,/ }; do
    [[ "$e" =~ ^(.*:)?[0-9]+[A-Za-z]*$ && "${e##*[0-9]}" == *s* ]] && continue
    out+="${out:+,}$e"
  done
  printf '%s\n' "$out"
}

# Dies when another program than the gateway's Caddy holds TCP 443, with the
# command that frees it for Pi-hole's own HTTPS listener.
dataden_check_port() {
  local owner cfg
  owner="$(port_owner 443)" || return 0
  [[ "$owner" != caddy ]] || return 0
  if [[ "$owner" == pihole-FTL ]]; then
    cfg="$(pihole_ftl --config webserver.port 2>/dev/null)" || cfg="$PH_DEFAULT_PORTS"
    local cmd="sudo pihole-FTL"
    task_in_container pihole && cmd="sudo docker exec pihole pihole-FTL"
    die "Pi-hole's admin page holds port 443 for HTTPS, which the gateway needs. Keep it on plain HTTP with: $cmd --config webserver.port '$(dataden_pihole_without_tls "$cfg")', then run this task again"
  fi
  die "Port 443 is used by '$owner'; the DATA-DEN gateway needs it. Stop that program, then run this task again"
}
