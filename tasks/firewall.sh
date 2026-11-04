#!/usr/bin/env bash
# Task: firewall - nftables input filter that only lets in what the Pi's
# rpi-setup services need (SSH is always allowed).
# Settings: FIREWALL_* in config/rpi-setup.env (names in config/tasks/firewall.env).
#
# The rules live in their own table (inet rpi_setup), loaded by a dedicated
# systemd unit, so Docker's and Tailscale's own tables are never flushed.
set -euo pipefail

TASKS+=("firewall|Firewall (nftables): allow SSH and the installed services, drop the rest")

FW_NFT_FILE=/etc/rpi-setup/firewall.nft
FW_UNIT=rpi-setup-firewall.service
FW_UNIT_DIR=/etc/systemd/system

run_firewall() {
  : "${FIREWALL_SSH_PORT:=22}" "${FIREWALL_AUTO_PORTS:=yes}"
  require_port FIREWALL_SSH_PORT
  setting_on FIREWALL_AUTO_PORTS || true
  local extra allow
  extra="$(firewall_port_specs FIREWALL_EXTRA_PORTS "${FIREWALL_EXTRA_PORTS:-}")" || exit 1
  allow="$(firewall_allow_from "${FIREWALL_ALLOW_FROM:-}")" || exit 1

  if ! command -v nft >/dev/null 2>&1; then
    apt_install nftables
  fi

  # SSH: the configured port plus every port sshd really listens on, so a
  # wrong FIREWALL_SSH_PORT can never lock you out.
  local ssh="$FIREWALL_SSH_PORT" p
  for p in $(firewall_sshd_ports); do
    if [[ " $ssh " != *" $p "* ]]; then
      warn "sshd also listens on port $p; allowing it too (FIREWALL_SSH_PORT=$FIREWALL_SSH_PORT)"
      ssh+=" $p"
    fi
  done

  # "port/proto kind service [docker]" lines: kind "open" (anyone) or "lan"
  # (FIREWALL_ALLOW_FROM); "docker" marks a port Docker publishes itself,
  # which the forward chain limits (Docker forwards it past the input chain).
  local services="" open="" lan="" dlan="" spec kind svc note
  if setting_on FIREWALL_AUTO_PORTS; then
    services="$(firewall_service_ports)" || exit 1
  fi
  while read -r spec kind svc note; do
    [[ -n "$spec" ]] || continue
    if [[ "$kind" == lan ]]; then
      lan+=" $spec"
      [[ "$note" != docker ]] || dlan+=" $spec"
      info "Allowing $spec for $svc${allow:+ (from $allow only)}"
    else
      open+=" $spec"
      info "Allowing $spec for $svc"
    fi
  done <<<"$services"
  [[ -z "$extra" ]] || info "Allowing FIREWALL_EXTRA_PORTS: $extra"
  open+=" $extra"
  local tailscale=""
  if command -v tailscale >/dev/null 2>&1; then tailscale=1; fi

  # /etc/rpi-setup also holds the root-only settings (0700): create it only
  # when missing, so an existing folder's mode is never loosened.
  [[ -d "$(dirname "$FW_NFT_FILE")" ]] || install -m 0700 -d "$(dirname "$FW_NFT_FILE")"
  local tmp out
  tmp="$(mktemp)"
  firewall_ruleset "$ssh" "$open" "$lan" "$allow" "$dlan" "$tailscale" >"$tmp"
  if ! out="$(nft -c -f "$tmp" 2>&1)"; then
    if in_container && [[ "$out" == *"Operation not permitted"* ]]; then
      warn 'This container may not check nftables rules; skipping the check'
    else
      printf '%s\n' "$out" >&2
      rm -f "$tmp"
      die 'The generated firewall rules failed "nft -c"; nothing was changed'
    fi
  fi

  local changed=0
  if write_if_changed "$FW_NFT_FILE" 0644 <"$tmp"; then
    changed=1
    say "Wrote $FW_NFT_FILE"
  fi
  rm -f "$tmp"
  if firewall_unit_file | write_if_changed "$FW_UNIT_DIR/$FW_UNIT" 0644; then
    changed=1
    systemctl daemon-reload 2>/dev/null || true
  fi

  if in_container; then
    info "Container detected: generated and checked $FW_NFT_FILE but did not load it"
    return
  fi

  systemctl enable "$FW_UNIT" >/dev/null 2>&1 || die "Could not enable $FW_UNIT"
  if ! systemctl is-active --quiet "$FW_UNIT"; then
    systemctl start "$FW_UNIT" || die "Could not start $FW_UNIT; see: journalctl -u $FW_UNIT"
    say 'Firewall is on'
  elif [[ $changed -eq 1 ]]; then
    systemctl reload "$FW_UNIT" || die "Could not reload $FW_UNIT; see: journalctl -u $FW_UNIT"
    say 'Firewall rules updated'
  elif ! firewall_table_loaded; then
    # The unit is oneshot with RemainAfterExit, so it stays "active" after
    # something else flushed the ruleset (nft flush ruleset, a restart of
    # nftables.service with Debian's stock /etc/nftables.conf).
    warn "$FW_UNIT is active but the table inet rpi_setup is gone (something flushed the ruleset); loading it again"
    systemctl reload "$FW_UNIT" || die "Could not reload $FW_UNIT; see: journalctl -u $FW_UNIT"
    say 'Firewall rules loaded again'
  else
    say 'Firewall is already on with these rules'
  fi

  firewall_docker_note
  info 'Re-run "setup.sh firewall" after adding a task, so its ports are opened.'
  info "Show the rules: sudo nft list table inet rpi_setup; turn off: sudo systemctl disable --now $FW_UNIT"
}

# Validate a list of "port/proto" or "from-to/proto" entries (spaces or
# commas between them) from setting $1 with value $2; print them normalized
# and space separated. Dies naming the setting on a bad entry.
firewall_port_specs() {
  local name="$1" v="${2//,/ }" s lo hi out=""
  for s in $v; do
    [[ "$s" =~ ^([0-9]{1,5})(-([0-9]{1,5}))?/(tcp|udp)$ ]] ||
      die "$name: '$s' must look like 8123/tcp, 1900/udp or 60000-61000/udp"
    lo=$((10#${BASH_REMATCH[1]}))
    hi=$((10#${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}))
    (( lo >= 1 && hi <= 65535 && lo <= hi )) ||
      die "$name: '$s' is not a port (range) between 1 and 65535"
    if (( lo == hi )); then s="$lo/${BASH_REMATCH[4]}"; else s="$lo-$hi/${BASH_REMATCH[4]}"; fi
    out+="${out:+ }$s"
  done
  printf '%s\n' "$out"
}

# Validate IPv4/IPv6 addresses or subnets (spaces or commas between them) from
# setting $1 with value $2; print them space separated.
firewall_cidrs() {
  local name="$1" v="${2//,/ }" c ip prefix out=""
  for c in $v; do
    ip="${c%/*}" prefix=""
    if [[ "$c" == */* ]]; then
      prefix="${c##*/}"
      [[ "$prefix" =~ ^[0-9]{1,3}$ ]] || die "$name: '$c' needs a prefix length after the /, such as 192.168.1.0/24"
    fi
    if [[ "$ip" =~ ^[0-9.]+$ ]]; then
      valid_ipv4 "$ip" || die "$name: '$c' is not an IPv4 address or subnet"
      [[ -z "$prefix" ]] || { [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && (( 10#$prefix <= 32 )); } ||
        die "$name: '$c' has a bad prefix length (0-32)"
    elif [[ "$ip" =~ ^[0-9A-Fa-f:]+$ && "$ip" == *:*:* ]]; then
      [[ -z "$prefix" ]] || { [[ "$prefix" =~ ^[0-9]{1,3}$ ]] && (( 10#$prefix <= 128 )); } ||
        die "$name: '$c' has a bad prefix length (0-128)"
    else
      die "$name: '$c' must be a subnet such as 192.168.1.0/24 or fd00::/8"
    fi
    out+="${out:+ }$c"
  done
  printf '%s\n' "$out"
}

# FIREWALL_ALLOW_FROM value $1 as the subnets that may reach the LAN
# services, space separated: empty means this Pi's own networks
# (firewall_lan_cidrs), "any" means anyone (prints nothing), anything else
# goes through firewall_cidrs. When no network can be found it warns and
# allows anyone, like "any".
firewall_allow_from() {
  local v="$1" lan
  if [[ "${v,,}" == any ]]; then return 0; fi
  if [[ -n "$v" ]]; then firewall_cidrs FIREWALL_ALLOW_FROM "$v"; return; fi
  lan="$(firewall_lan_cidrs)"
  if [[ -z "$lan" ]]; then
    warn 'FIREWALL_ALLOW_FROM is empty and no local network was found, so the LAN services are open to anyone; set FIREWALL_ALLOW_FROM'
    return 0
  fi
  info "FIREWALL_ALLOW_FROM is empty: the LAN services are limited to this Pi's networks ($lan); set it to any to open them to everyone" >&2
  printf '%s\n' "$lan"
}

# This Pi's own networks, space separated: the IPv4 and IPv6 subnets of the
# kernel routes on its network interfaces (not loopback, Docker or VPN
# interfaces), plus IPv6 link-local (fe80::/10) and unique local (fc00::/7)
# addresses when the Pi has IPv6 routes.
firewall_lan_cidrs() {
  local skip='^(lo|docker|br-|veth|tailscale|wg|tun)' v4 v6 any6
  v4="$(ip -o -4 route show proto kernel scope link 2>/dev/null |
    awk -v skip="$skip" '$2 == "dev" && $3 !~ skip && $1 ~ /^[0-9.]+\/[0-9]+$/ { print $1 }')" || v4=""
  v6="$(ip -o -6 route show proto kernel 2>/dev/null |
    awk -v skip="$skip" '$2 == "dev" && $3 !~ skip && $1 ~ /^[0-9a-f:]+\/[0-9]+$/ && $1 !~ /^fe80:/ { print $1 }')" || v6=""
  any6="$(ip -o -6 route show 2>/dev/null | head -n1)" || any6=""
  [[ -z "$any6" ]] || v6+=$'\nfe80::/10\nfc00::/7'
  printf '%s\n%s\n' "$v4" "$v6" | awk 'NF && !seen[$0]++' | paste -sd' ' -
}

# Comma-joined, de-duplicated ports of protocol $1 from the "port/proto"
# entries in $2, e.g. "tcp" "22/tcp 80/tcp 53/udp" -> "22, 80".
firewall_ports_of() {
  local proto="$1" s out="" seen=" "
  for s in $2; do
    [[ "$s" == */"$proto" ]] || continue
    s="${s%/*}"
    [[ "$seen" != *" $s "* ]] || continue
    seen+="$s "
    out+="${out:+, }$s"
  done
  printf '%s' "$out"
}

# The nftables ruleset (pure: no system access). Arguments:
#   $1 SSH ports, space separated (always allowed from anywhere)
#   $2 open "port/proto" entries (allowed from anywhere)
#   $3 LAN "port/proto" entries (allowed from $4 only; from anywhere if $4 is empty)
#   $4 source subnets for the LAN entries, space separated (IPv4 and/or IPv6)
#   $5 the LAN entries of $3 that Docker publishes: the forward chain drops
#      connections to them from outside $4 (Docker forwards them to the
#      container before the input chain sees them)
#   $6 non-empty: Tailscale is installed, so allow everything over tailscale0
firewall_ruleset() {
  local ssh="$1" open="$2" lan="$3" allow="$4" dlan="${5:-}" tailscale="${6:-}"
  local c v4="" v6="" s proto ports lan_only="" fwd="" tag='comment "Docker port, LAN only"'
  if [[ -z "$allow" ]]; then
    open+=" $lan"
    dlan=""
  else
    for c in $allow; do
      if [[ "$c" == *:* ]]; then v6+="${v6:+, }$c"; else v4+="${v4:+, }$c"; fi
    done
    # A port that is open to anyone anyway needs no extra rule.
    for s in $lan; do
      [[ " $open " == *" $s "* ]] || lan_only+=" $s"
    done
  fi

  cat <<EOF
# Managed by rpi-setup (tasks/firewall.sh); re-run "setup.sh firewall" to change.
# Only this table is replaced: Docker's own rules stay as they are.
table inet rpi_setup
delete table inet rpi_setup
table inet rpi_setup {
  chain input {
    type filter hook input priority filter; policy drop;
    ct state established,related accept
    ct state invalid drop
    iifname "lo" accept
    meta l4proto { icmp, ipv6-icmp } accept
EOF
  [[ -z "$tailscale" ]] || printf '    iifname "tailscale0" accept comment "Tailscale"\n'
  cat <<EOF
    iifname "docker0" meta l4proto { tcp, udp } th dport 53 accept comment "DNS for Docker containers"
    iifname "br-*" meta l4proto { tcp, udp } th dport 53 accept comment "DNS for Docker compose networks"
    udp sport 67 udp dport 68 accept comment "DHCP client"
    meta nfproto ipv6 udp sport 547 udp dport 546 accept comment "DHCPv6 client"
    udp dport 5353 accept comment "mDNS (<host>.local)"
    tcp dport { $(firewall_ports_of tcp "${ssh// //tcp }/tcp") } accept comment "SSH"
EOF
  for proto in tcp udp; do
    ports="$(firewall_ports_of "$proto" "$open")"
    [[ -z "$ports" ]] || printf '    %s dport { %s } accept\n' "$proto" "$ports"
  done
  for proto in tcp udp; do
    ports="$(firewall_ports_of "$proto" "$lan_only")"
    [[ -n "$ports" ]] || continue
    [[ -z "$v4" ]] || printf '    ip saddr { %s } %s dport { %s } accept comment "LAN services"\n' "$v4" "$proto" "$ports"
    [[ -z "$v6" ]] || printf '    ip6 saddr { %s } %s dport { %s } accept comment "LAN services"\n' "$v6" "$proto" "$ports"
  done
  printf '  }\n'
  # Ports Docker publishes, limited before Docker's own forward rules
  # (priority filter) see them. "ct original" is the client's side of the
  # connection, also for the replies.
  for proto in tcp udp; do
    ports="$(firewall_ports_of "$proto" "$dlan")"
    [[ -n "$ports" ]] || continue
    s="ct status dnat meta l4proto $proto ct original proto-dst { $ports }"
    if [[ -n "$v4" ]]; then
      fwd+="    meta nfproto ipv4 $s ct original ip saddr != { $v4 } drop $tag"$'\n'
    else
      fwd+="    meta nfproto ipv4 $s drop $tag"$'\n'
    fi
    if [[ -n "$v6" ]]; then
      fwd+="    meta nfproto ipv6 $s ct original ip6 saddr != { $v6 } drop $tag"$'\n'
    else
      fwd+="    meta nfproto ipv6 $s drop $tag"$'\n'
    fi
  done
  if [[ -n "$fwd" ]]; then
    printf '  chain forward {\n    type filter hook forward priority filter - 1; policy accept;\n%s  }\n' "$fwd"
  fi
  printf '}\n'
}

# systemd unit that loads (and on stop removes) only the rpi_setup table.
# After=nftables.service: a "flush ruleset" in /etc/nftables.conf runs first.
firewall_unit_file() {
  cat <<EOF
# Managed by rpi-setup (tasks/firewall.sh).
[Unit]
Description=rpi-setup firewall (nftables table inet rpi_setup)
Wants=network-pre.target
Before=network-pre.target
After=nftables.service
DefaultDependencies=no
Before=shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f $FW_NFT_FILE
ExecReload=/usr/sbin/nft -f $FW_NFT_FILE
ExecStop=/usr/sbin/nft delete table inet rpi_setup

[Install]
WantedBy=sysinit.target
EOF
}

# True while the kernel holds the table the unit loads.
firewall_table_loaded() {
  nft list table inet rpi_setup >/dev/null 2>&1
}

# TCP ports sshd is reachable on, space separated (empty if none can be
# found): the Port lines of its configuration ("sshd -T"), what really
# listens as sshd (ss), and the ListenStream of ssh.socket, since with a
# socket-activated sshd the listener belongs to systemd, not sshd.
firewall_sshd_ports() {
  {
    sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' || true
    ss -H -ltnp 2>/dev/null | awk '/"sshd/ { n = split($4, a, ":"); print a[n] }' || true
    systemctl show ssh.socket sshd.socket -p Listen 2>/dev/null |
      awk -F'[= ]' '$1 == "Listen" && $3 == "(Stream)" { n = split($2, a, ":"); print a[n] }' || true
  } | grep -Ex '[0-9]+' | sort -un | tr '\n' ' ' || true
}

# Every web server port nginx listens on (from its enabled sites, or the
# site files of the web container).
firewall_nginx_ports() {
  local -a sites=(/etc/nginx/sites-enabled/*)
  if task_in_container web; then sites=("$(container_dir web)"/conf/*.conf); fi
  sed -nE 's/^[[:space:]]*listen[[:space:]]+([^;[:space:]]*:)?([0-9]+)([[:space:];]).*/\2/p' \
    "${sites[@]}" 2>/dev/null | sort -un
}

# "port/proto kind service" lines for the rpi-setup services installed on
# this Pi, using their tasks' settings (and defaults). Runs other tasks'
# load_task_config, so call it in a subshell: $(firewall_service_ports).
firewall_service_ports() {
  local p
  if command -v pihole-FTL >/dev/null 2>&1 || command -v pihole >/dev/null 2>&1 || task_in_container pihole; then
    load_task_config pihole >/dev/null
    printf '53/tcp lan pihole-dns\n53/udp lan pihole-dns\n'
    p="$(pihole_web_ports | sort -un)"
    [[ -n "$p" ]] || p="${PIHOLE_WEB_PORT:-80}"
    for p in $p; do printf '%s/tcp lan pihole-web\n' "$p"; done
    if [[ "$(pihole_ftl --config dhcp.active 2>/dev/null)" == true ]]; then
      printf '67/udp open pihole-dhcp\n'
      if [[ "$(pihole_ftl --config dhcp.ipv6 2>/dev/null)" == true ]]; then
        printf '547/udp open pihole-dhcpv6\n'
      fi
    fi
  fi
  if apt_installed nginx || task_in_container web; then
    load_task_config web >/dev/null
    p="$(firewall_nginx_ports)"
    [[ -n "$p" ]] || p="${WEB_PORT:-80}"
    for p in $p; do printf '%s/tcp lan nginx\n' "$p"; done
  fi
  if [[ -f /opt/netalertx/docker-compose.yml ]]; then
    load_task_config netalertx >/dev/null
    : "${NETALERTX_PORT:=20211}"
    require_port NETALERTX_PORT
    # The web UI's browser code also calls NetAlertX's API server (GRAPHQL_PORT).
    printf '%s/tcp lan netalertx\n20212/tcp lan netalertx-api\n' "$NETALERTX_PORT"
  fi
  if [[ -f /opt/teamspeak/docker-compose.yml ]]; then
    load_task_config teamspeak >/dev/null
    : "${TEAMSPEAK_VOICE_PORT:=9987}" "${TEAMSPEAK_FILE_PORT:=30033}"
    : "${TEAMSPEAK_QUERY_PORT:=10080}" "${TEAMSPEAK_QUERY_HTTP:=no}"
    require_port TEAMSPEAK_VOICE_PORT
    require_port TEAMSPEAK_FILE_PORT
    require_port TEAMSPEAK_QUERY_PORT
    printf '%s/udp open teamspeak-voice docker\n%s/tcp open teamspeak-file docker\n' "$TEAMSPEAK_VOICE_PORT" "$TEAMSPEAK_FILE_PORT"
    if setting_on TEAMSPEAK_QUERY_HTTP; then printf '%s/tcp lan teamspeak-query docker\n' "$TEAMSPEAK_QUERY_PORT"; fi
  fi
  # Den-Watcher, the apps and TeamSpeak publish their ports ("ports:" in
  # the compose file): Docker forwards those to the container before the
  # input chain sees them, so the forward chain limits the "lan" ones.
  if [[ -f "$(container_dir denwatcher)/docker-compose.yml" ]]; then
    load_task_config denwatcher >/dev/null
    : "${DENWATCHER_PORT:=9393}"
    require_port DENWATCHER_PORT
    printf '%s/tcp lan denwatcher docker\n' "$DENWATCHER_PORT"
    # The status page is meant for outside the local network.
    if [[ -n "${DENWATCHER_STATUS_PORT:-}" ]]; then
      require_port DENWATCHER_STATUS_PORT
      printf '%s/tcp open denwatcher-status docker\n' "$DENWATCHER_STATUS_PORT"
    fi
  fi
  # The apps task's ports, from its compose file (one per app).
  if [[ -f "$(container_dir apps)/docker-compose.yml" ]]; then
    sed -n 's/^ *- "0\.0\.0\.0:\([0-9]*\):[0-9]*"$/\1\/tcp lan apps docker/p' "$(container_dir apps)/docker-compose.yml"
  fi
  if apt_installed samba || task_in_container samba; then
    printf '445/tcp lan samba\n139/tcp lan samba\n137/udp lan samba-netbios\n138/udp lan samba-netbios\n'
  fi
  if command -v tailscale >/dev/null 2>&1; then
    printf '41641/udp open tailscale-direct\n'
  fi
}

# Docker's published ports are forwarded to containers before the input
# chain sees them: the forward chain limits those of rpi-setup's tasks, but
# a container started by hand is not limited.
firewall_docker_note() {
  command -v docker >/dev/null 2>&1 || return 0
  local published
  published="$(docker ps --format '{{.Names}}: {{.Ports}}' 2>/dev/null | grep -- '->' || true)"
  [[ -n "$published" ]] || return 0
  info 'Ports published by Docker containers (those of rpi-setup tasks are limited as listed above; others are open to anyone):'
  printf '  %s\n' "$published" >&2
  info 'See "Ports of Docker containers" in docs/tasks/firewall.md.'
}
