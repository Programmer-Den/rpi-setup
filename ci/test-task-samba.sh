#!/usr/bin/env bash
# test-task-samba.sh - unit tests for tasks/samba.sh: the smb.conf section,
# the compose file's quoting, the native path's password order, and with
# SAMBA_DOCKER=yes that a generated password is printed and saved before the
# container starts, so a failed first start (after which later runs read it
# from /opt/samba/password) does not lose it. Docker, Samba's tools, ports and
# save_secret are stubbed; nothing outside a temp folder changes. The
# container password case is skipped if this machine has a saved password.
#
# Run: bash ci/test-task-samba.sh
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
export RPI_SETUP_ROOT="$ROOT"
. "$ROOT/lib/common.sh"
TASKS=()
. "$ROOT/tasks/samba.sh"

export RPI_SETUP_CONTAINER_ROOT="$TMP/opt"
stub_container_helpers
pdbedit() { return 1; }
save_secret() { printf '%s=%s\n' "$2" "$3" >>"$TMP/saved"; }
container_up() { echo "container_up saved=[$(cat "$TMP/saved" 2>/dev/null)]"; exit 1; }  # dies like a failed start

u="$(id -un)"
[[ "$u" != root ]] || u=nobody
mkdir -p "$TMP/share"

# --- samba_share_section: one managed share, whatever it was called ----------
conf="$TMP/smb.conf"
printf '[global]\n   workgroup = WORKGROUP\n\n[old-share]\n   # Managed by rpi-setup (SAMBA_* settings); re-run "setup.sh samba" to change.\n   path = /srv/old\n   read only = no\n\n[other]\n   path = /srv/other\n' >"$conf"
assert_ok "a renamed share changes the file" samba_share_section "$conf" new-share /srv/new "$u" no
assert_lacks "the old managed share is gone" "old-share" "$(cat "$conf")"
assert_eq "the new share takes its place, the rest is kept" \
    "$(printf '[global] [new-share] [other]')" "$(grep -o '^\[.*\]' "$conf" | xargs)"
assert_contains "with its settings" "   path = /srv/new" "$(cat "$conf")"
assert_fails "the same share again changes nothing" samba_share_section "$conf" new-share /srv/new "$u" no
printf '[global]\n[old-share]\n   # Managed by rpi-setup\n   path = /srv/old\n[second]\n   # Managed by rpi-setup\n   path = /srv/second\n' >"$conf"
samba_share_section "$conf" nas-share /srv/nas "$u" yes || true
assert_eq "every managed section is replaced by the one share" "[global] [nas-share]" "$(grep -o '^\[.*\]' "$conf" | xargs)"
printf '[global]\n[nas-share]\n   path = /srv/mine\n   comment = hand-written\n' >"$conf"
samba_share_section "$conf" nas-share /srv/nas "$u" no || true
assert_lacks "a section of the same name is replaced" "hand-written" "$(cat "$conf")"
assert_eq "without a managed section the share is appended" "[global] [nas-share]" "$(grep -o '^\[.*\]' "$conf" | xargs)"

# --- samba_container_compose: paths and host name are YAML strings ----------
assert_eq "yaml string: plain" '"/srv/share"' "$(samba_yaml_str /srv/share)"
assert_eq "yaml string: quote and backslash escaped" '"a\\b \"c\""' "$(samba_yaml_str 'a\b "c"')"
SAMBA_IMAGE=crazymax/samba:latest
compose="$(samba_container_compose "$TMP/opt/samba" samba '/srv/my: share #1')"
assert_contains "a share path with ': ' and ' #' is quoted" 'source: "/srv/my: share #1"' "$compose"
assert_contains "the settings folder is quoted" "source: \"$TMP/opt/samba/data\"" "$compose"
assert_contains "the host name is quoted" "hostname: \"$(hostname)\"" "$compose"

if [[ -e /var/lib/rpi-setup/secrets/samba.env ]]; then
  skip "a saved Samba password exists on this machine"
else
  out="$( (unset SAMBA_PASSWORD; run_samba_container "$u" "$TMP/share" share no) 2>&1 || true)"
  saved="$(sed -nE 's/^SAMBA_PASSWORD=//p' "$TMP/saved" 2>/dev/null || true)"
  assert_ok "a generated password is saved" test -n "$saved"
  assert_eq "it is the one in the password file" "$saved" "$(cat "$TMP/opt/samba/password" 2>/dev/null)"
  assert_contains "it is saved before container_up" "container_up saved=[SAMBA_PASSWORD=$saved]" "$out"
  assert_contains "it is printed even when the start fails" "Generated Samba password for $u: $saved" "$out"

  # Re-run after the failed start: the password comes from the file, not new.
  rm -f "$TMP/saved"
  out="$( (unset SAMBA_PASSWORD; run_samba_container "$u" "$TMP/share" share no) 2>&1 || true)"
  assert_eq "a re-run keeps the password from the file" "$saved" "$(cat "$TMP/opt/samba/password")"
  assert_eq "a re-run does not generate another one" "" "$(cat "$TMP/saved" 2>/dev/null || true)"
fi

# --- native path: the setting, then the saved password, then the container's,
# else a new one (so switching back from the container keeps the password).
apt_install() { :; }
testparm() { :; }
systemctl() { :; }
# container_leave (SAMBA_DOCKER=no with the compose file from above) asks
# Docker for the project's containers; here there are none.
docker() { :; }
smbpasswd() { [[ "$1" == -s ]] && head -n1 >"$TMP/smbpasswd-got"; return 0; }
printf '[global]\n' >"$TMP/native.conf"
SMB_CONF="$TMP/native.conf"
# --- samba_check_path: never a system folder ----------------------------------
for bad in / /etc /etc/ssh /usr /var /var/lib/docker /home /root /opt /boot/firmware /srv/../etc /tmp//; do
  assert_fails "share path: $bad is refused" samba_check_path "$bad"
done
for good in /srv/share /mnt/usb/share /home/alex/nas-share /opt/share /var/share; do
  assert_ok "share path: $good is fine" samba_check_path "$good"
done

# shellcheck disable=SC2163  # the NAME=value arguments are exported on purpose
native() { ( SAMBA_DOCKER=no SAMBA_USER="$u" SAMBA_SHARE_PATH="$TMP/share"; [[ $# -eq 0 ]] || export "$@"; run_samba ) 2>&1; }
rm -f "$TMP/saved" "$TMP/smbpasswd-got"
load_secret() { echo saved-pw; }
printf 'container-pw' >"$TMP/opt/samba/password" 2>/dev/null || { mkdir -p "$TMP/opt/samba"; printf 'container-pw' >"$TMP/opt/samba/password"; }
out="$(native)"
assert_eq "native: a saved password is used" "saved-pw" "$(cat "$TMP/smbpasswd-got")"
assert_contains "and said so" "Using the Samba password saved by an earlier run" "$out"
assert_eq "native: nothing new is generated" "" "$(cat "$TMP/saved" 2>/dev/null || true)"
out="$(native SAMBA_PASSWORD=given)"
assert_eq "native: the setting wins" "given" "$(cat "$TMP/smbpasswd-got")"
load_secret() { return 1; }
out="$(native)"
assert_eq "native: the container's password comes next" "container-pw" "$(cat "$TMP/smbpasswd-got")"
assert_contains "and said so" "Using the Samba password of the samba container" "$out"
rm -f "$TMP/opt/samba/password"
out="$(native)"
assert_contains "native: without any, a new one is generated" "Generated Samba password for $u" "$out"
assert_eq "and it is the one set" "$(sed -nE 's/^SAMBA_PASSWORD=//p' "$TMP/saved")" "$(cat "$TMP/smbpasswd-got")"
pdbedit() { return 0; }
rm -f "$TMP/smbpasswd-got"
out="$(native)"
assert_contains "native: an existing Samba user keeps its password" "keeping its password" "$out"
assert_ok "and smbpasswd is not called" test ! -e "$TMP/smbpasswd-got"

finish_tests
