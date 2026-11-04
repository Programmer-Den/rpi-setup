#!/usr/bin/env bash
# Task: samba - a simple password-protected NAS share for one user.
# Settings: SAMBA_* in config/rpi-setup.env (names in config/tasks/samba.env).
set -euo pipefail
. "$RPI_SETUP_ROOT/lib/containers.sh"

TASKS+=("samba|Samba NAS share (read-write, per-user password)")

SMB_CONF="${SMB_CONF:-/etc/samba/smb.conf}"

run_samba() {
  : "${SAMBA_SHARE_NAME:=nas-share}" "${SAMBA_READ_ONLY:=no}" "${SAMBA_DOCKER:=no}"
  local u="${SAMBA_USER:-}" dir="${SAMBA_SHARE_PATH:-}" share="$SAMBA_SHARE_NAME" home ro=no
  if setting_on SAMBA_READ_ONLY; then ro=yes; fi
  [[ "$share" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]] ||
    die "SAMBA_SHARE_NAME must be letters, digits, '.', '_' or '-' (got '$share')"
  [[ "${share,,}" != global && "${share,,}" != homes && "${share,,}" != printers ]] ||
    die "SAMBA_SHARE_NAME '$share' is reserved by Samba; pick another name"

  [[ -n "$u" ]] || u="$(real_user)"
  if [[ "$u" == "root" ]]; then warn 'Recommend running via sudo as a normal user, or set SAMBA_USER'; fi
  id "$u" >/dev/null 2>&1 || die "SAMBA_USER: there is no Linux user '$u' on this Pi"
  home="$(getent passwd "$u" | cut -d: -f6)"
  if [[ -z "$dir" ]]; then
    [[ -n "$home" && -d "$home" ]] || die "Could not find the home directory of '$u'; set SAMBA_SHARE_PATH"
    dir="${home}/${share}"
  fi
  [[ "$dir" == /* ]] || die "SAMBA_SHARE_PATH must be an absolute path (got '$dir')"
  samba_check_path "$dir"
  if setting_on SAMBA_DOCKER; then run_samba_container "$u" "$dir" "$share" "$ro"; return; fi
  container_leave samba

  apt_install samba
  if [[ ! -d "$dir" ]]; then
    install -d -m 0755 -o "$u" -g "$(id -gn "$u")" "$dir"
    say "Created $dir"
  fi

  local conf="$SMB_CONF" changed=0
  if samba_share_section "$conf" "$share" "$dir" "$u" "$ro"; then
    changed=1
    say "Wrote the [$share] share to ${conf}"
  else
    say "smb.conf already has the [$share] share as configured"
  fi
  testparm -s "$conf" >/dev/null 2>&1 || die 'smb.conf failed testparm validation'

  # The password, in the same order as for the container: the setting, the
  # one saved by an earlier run (also the container's), else a new one.
  local pw
  if [[ -z "${SAMBA_PASSWORD:-}" ]] && pdbedit -L -u "$u" >/dev/null 2>&1; then
    say "Samba user '${u}' already exists; keeping its password (set SAMBA_PASSWORD to change it)"
  else
    pw="${SAMBA_PASSWORD:-}"
    if [[ -z "$pw" ]] && pw="$(load_secret samba SAMBA_PASSWORD)"; then
      say "Using the Samba password saved by an earlier run (set SAMBA_PASSWORD to change it)"
    elif [[ -z "$pw" && -f "$(container_dir samba)/password" ]]; then
      pw="$(<"$(container_dir samba)/password")"
      say "Using the Samba password of the samba container (set SAMBA_PASSWORD to change it)"
    fi
    if [[ -z "$pw" ]]; then new_secret pw samba SAMBA_PASSWORD "Samba password for ${u}" 16; fi
    printf '%s\n%s\n' "$pw" "$pw" | smbpasswd -s -a "$u" >/dev/null
    smbpasswd -e "$u" >/dev/null
  fi

  systemctl enable --now smbd
  if [[ $changed -eq 1 ]] && systemctl is-active --quiet smbd; then
    systemctl reload smbd 2>/dev/null || systemctl restart smbd
  fi
  say "Share ready: \\\\$(hostname)\\${share} (user ${u}$([[ $ro == yes ]] && echo ', read-only'))"
}

# Dies unless share folder $1 is a folder of its own: not a system folder
# (with SAMBA_DOCKER=yes the container would get it read-write as root), not
# one with "..", and not a home folder as a whole.
samba_check_path() {
  local d="$1"
  [[ "$d" != *"/../"* && "$d" != *"/.." ]] || die "SAMBA_SHARE_PATH cannot contain '..' (got '$d')"
  while [[ "$d" == */ && "$d" != / ]]; do d="${d%/}"; done
  case "$d" in
    /|/etc|/etc/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib64|/boot|/boot/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*|/root|/var|/var/lib|/var/lib/*|/opt|/home|/tmp)
      die "SAMBA_SHARE_PATH cannot be a system folder like $d; use a folder of its own, e.g. /srv/share or /mnt/usb/share" ;;
  esac
}

# Write the share rpi-setup manages into smb.conf $1 as section [$2]: it
# takes the place of the first section that is either named [$2] or marked
# "Managed by rpi-setup" (a renamed share), every other such section is
# removed, and without one it is appended. Returns 0 if the file changed.
samba_share_section() {
  local conf="$1" share="$2" dir="$3" u="$4" ro="$5" body
  body="$(printf '[%s]\n   # Managed by rpi-setup (SAMBA_* settings); re-run "setup.sh samba" to change.\n   comment = Raspberry Pi share\n   path = %s\n   browseable = yes\n   read only = %s\n   guest ok = no\n   valid users = %s\n' \
    "$share" "$dir" "$ro" "$u")"
  SAMBA_BODY="$body" awk -v sec="$share" '
    BEGIN { body = ENVIRON["SAMBA_BODY"] }
    # A section is kept back until its end, since the marker is inside it.
    function flush(  i) {
      if (!insec) return
      if (same || managed) { if (!done) print body; done = 1 }
      else for (i = 1; i <= n; i++) print buf[i]
      n = 0; same = 0; managed = 0
    }
    /^[[:space:]]*\[.*\][[:space:]]*$/ {
      flush()
      insec = 1
      name = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", name)
      same = (tolower(name) == tolower(sec))
    }
    {
      if (!insec) { print; next }
      buf[++n] = $0
      if ($0 ~ /Managed by rpi-setup/) managed = 1
    }
    END { flush(); if (!done) print body }' "$conf" | write_if_changed "$conf"
}

# SAMBA_DOCKER=yes: Samba in its own container (crazymax/samba, host network
# for port 445), sharing folder $2 as [$3] for Linux user $1 with the same
# uid/gid, read-only if $4 is "yes". The share folder stays where it is. The
# password comes from SAMBA_PASSWORD or the one saved on an earlier run; a
# native smbd's password hash cannot be carried over, so then it must be set.
run_samba_container() {
  local u="$1" dir="$2" share="$3" ro="$4" name=samba cdir owner="" changed=0 pw="${SAMBA_PASSWORD:-}"
  : "${SAMBA_IMAGE:=crazymax/samba:latest}"
  require_image_ref SAMBA_IMAGE
  container_require_64bit SAMBA_DOCKER
  [[ "$u" != root ]] || die 'SAMBA_USER cannot be root for the container; set SAMBA_USER to a normal user'
  container_require_docker
  cdir="$(container_dir samba)"
  owner="$(port_owner 445)" || owner=""
  [[ -z "$owner" || "$owner" == smbd ]] || die "Port 445 is already used by '$owner'; Samba needs it"

  if [[ -z "$pw" ]]; then pw="$(load_secret samba SAMBA_PASSWORD)" || pw=""; fi
  if [[ -z "$pw" && -f "$cdir/password" ]]; then
    pw="$(<"$cdir/password")"
  fi
  if [[ -z "$pw" ]]; then
    if command -v pdbedit >/dev/null 2>&1 && pdbedit -L -u "$u" >/dev/null 2>&1; then
      die "The native Samba password of '$u' cannot be moved into the container; set SAMBA_PASSWORD (it can be the same one) and run again"
    fi
    # Print and save it now: once it is in $cdir/password a later run reads
    # it from there, so a failed first start must not lose it.
    new_secret pw samba SAMBA_PASSWORD "Samba password for ${u}" 16
  fi

  if [[ ! -d "$dir" ]]; then
    install -d -m 0755 -o "$u" -g "$(id -gn "$u")" "$dir"
    say "Created $dir"
  fi
  install -m 0755 -d "$cdir" "$cdir/data"
  if printf '%s' "$pw" | write_if_changed "$cdir/password" 0600; then changed=1; fi
  if samba_container_config "$u" "$share" "$ro" | write_if_changed "$cdir/data/config.yml" 0644; then changed=1; fi
  if samba_container_compose "$cdir" "$name" "$dir" | write_if_changed "$cdir/docker-compose.yml" 0644; then changed=1; fi
  container_pull "$cdir"
  container_stop_native "$cdir" smbd nmbd

  container_up "$cdir" "$name" "$changed"
  say "Samba container running - share: \\\\$(hostname)\\${share} (user ${u}$([[ $ro == yes ]] && echo ', read-only'))"
}

# The image's config.yml: user $1 with its own uid/gid, share $2, read-only $3.
samba_container_config() {
  local u="$1" share="$2" ro="$3" g
  g="$(id -gn "$u")"
  cat <<EOF
# Managed by rpi-setup (tasks/samba.sh, SAMBA_* settings).
auth:
  - user: "$u"
    group: "$g"
    uid: $(id -u "$u")
    gid: $(id -g "$u")
    password_file: /run/secrets/samba_password
global:
  - "server min protocol = SMB2_10"
share:
  - name: "$share"
    comment: Raspberry Pi share
    path: /samba/share
    browsable: yes
    readonly: $ro
    guestok: no
    validusers: "$u"
    writelist: "$u"
EOF
}

# $1 as a double-quoted YAML string (a path with ": ", " #", a quote or a
# backslash would otherwise break the compose file).
samba_yaml_str() {
  local s="${1//\\/\\\\}"
  printf '"%s"' "${s//\"/\\\"}"
}

# Compose file: folder $1, container name $2, share folder $3.
samba_container_compose() {
  local cdir="$1" name="$2" dir="$3"
  cat <<EOF
services:
  samba:
    image: "$SAMBA_IMAGE"
    container_name: $name
    hostname: $(samba_yaml_str "$(hostname)")
    restart: unless-stopped
    network_mode: host
    pids_limit: 512
    security_opt:
      - no-new-privileges:true
    environment:
      TZ: "$(cat /etc/timezone 2>/dev/null || echo UTC)"
    volumes:
      - type: bind
        source: $(samba_yaml_str "$cdir/data")
        target: /data
      - type: bind
        source: $(samba_yaml_str "$cdir/password")
        target: /run/secrets/samba_password
        read_only: true
      - type: bind
        source: $(samba_yaml_str "$dir")
        target: /samba/share
EOF
}
