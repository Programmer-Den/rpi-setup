#!/usr/bin/env bash
# test-setup.sh - tests for setup.sh's task registry, argument parsing and
# interactive menu. No task is ever executed: the CLI tests only use inputs
# that make setup.sh exit before run_tasks (unknown task, empty selection).
#
# Run: bash ci/test-setup.sh        (sudo bash ci/test-setup.sh for the root-only tests)
# Many cases pass literal $ strings (settings values, eval bodies) on purpose.
# shellcheck disable=SC2016
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
# Sourcing setup.sh loads lib/common.sh and every tasks/*.sh without running main().
. "$ROOT/setup.sh"

# --- Task registry ------------------------------------------------------------
task_files=("$ROOT"/tasks/*.sh)
assert_eq "every tasks/*.sh registers exactly one task" "${#task_files[@]}" "${#TASKS[@]}"

names=()
for entry in "${TASKS[@]}"; do
    name="$(task_name "$entry")"
    desc="$(task_desc "$entry")"
    names+=("$name")
    if [[ "$(type -t "run_${name}")" == "function" ]]; then
        pass "task '$name' has a run_${name} handler"
    else
        fail "task '$name' has no run_${name} handler (setup.sh would silently skip it)"
    fi
    if [[ -n "$desc" && "$desc" != "$entry" ]]; then
        pass "task '$name' has a description"
    else
        fail "task '$name' is missing the '|description' part"
    fi
    if [[ -f "$ROOT/tasks/$name.sh" ]]; then
        pass "task '$name' lives in tasks/$name.sh"
    else
        fail "task '$name' is registered by a file that is not tasks/$name.sh"
    fi
done
dupes="$(printf '%s\n' "${names[@]}" | sort | uniq -d)"
assert_eq "task names are unique" "" "$dupes"

# --- task_desc_of ---------------------------------------------------------------
first="$(task_name "${TASKS[0]}")"
assert_eq "task_desc_of gives the description" "$(task_desc "${TASKS[0]}")" "$(task_desc_of "$first")"
assert_fails "task_desc_of dies on an unknown task" task_desc_of no-such-task
assert_contains "task_desc_of names the unknown task" "unknown task: no-such-task" \
    "$( (task_desc_of no-such-task) 2>&1 || true)"

# --- prompt_selection ---------------------------------------------------------
# The '> ' prompt must go to stderr; anything on stdout is taken as a task name.
nth() { task_name "${TASKS[$1 - 1]}"; }
assert_eq "prompt_selection parses comma-separated numbers" "$(nth 1) $(nth 3)" "$(printf '1,3\n' | prompt_selection 2>/dev/null | xargs)"
assert_eq "prompt_selection parses space-separated numbers" "$(nth 2) $(nth 4)" "$(printf '2 4\n' | prompt_selection 2>/dev/null | xargs)"
# "all" leaves out the tasks that need settings (apps, runner, gateway) or change the
# address (network); picked by number they still run.
all_names="$(printf '%s\n' "${names[@]}" | grep -vxE 'apps|runner|gateway|network' | xargs)"
assert_eq "prompt_selection expands 'all' without apps, runner, gateway and network" "$all_names" \
    "$(printf 'all\n' | prompt_selection 2>/dev/null | xargs)"
apps_no="$(printf '%s\n' "${names[@]}" | grep -nx apps | cut -d: -f1)"
assert_eq "prompt_selection still picks apps by number" "apps" "$(printf '%s\n' "$apps_no" | prompt_selection 2>/dev/null | xargs)"
assert_eq "prompt_selection returns nothing for empty input" "" "$(printf '\n' | prompt_selection 2>/dev/null)"
assert_eq "prompt_selection ignores non-numeric tokens" "$(nth 2)" "$(printf 'abc 2 x\n' | prompt_selection 2>/dev/null | xargs)"
assert_eq "prompt_selection ignores numbers without a task" "$(nth 1)" "$(printf '0 1 999\n' | prompt_selection 2>/dev/null | xargs)"
# main() does picked=($(prompt_selection)) under 'set -e', so a non-zero return
# here would silently kill setup.sh instead of printing "Cancelled.".
assert_ok "prompt_selection exits 0 on non-numeric input"  eval "printf 'abc\n' | prompt_selection"
assert_ok "prompt_selection exits 0 on a trailing non-numeric token" eval "printf '1 x\n' | prompt_selection"
assert_eq "prompt_selection writes the prompt to stderr, not stdout" "> " "$(printf '\n' | prompt_selection 2>&1 >/dev/null)"

# --- Task helpers -------------------------------------------------------------
tmp="$(mktemp -d)"
printf 'server {\n\tlisten 80 default_server;\n\tlisten [::]:80 default_server;\n\t# listen 443 ssl default_server;\n}\n' >"$tmp/site"
nginx_move_port "$tmp/site" 80 8080
assert_contains "nginx_move_port moves the IPv4 listen" "listen 8080 default_server;" "$(cat "$tmp/site")"
assert_contains "nginx_move_port moves the IPv6 listen" "listen [::]:8080 default_server;" "$(cat "$tmp/site")"
assert_contains "nginx_move_port leaves other ports alone" "# listen 443 ssl" "$(cat "$tmp/site")"
assert_eq "nginx_site_port reads the listen port" "8080" "$(nginx_site_port "$tmp/site")"

# samba: an old unmarked [nas-share] section is replaced, other sections kept.
printf '[global]\n   workgroup = W\n[nas-share]\n   path = /old\n[printers]\n   x = y\n' >"$tmp/smb.conf"
assert_ok "samba_share_section replaces the share" samba_share_section "$tmp/smb.conf" nas-share /srv/share pi yes
assert_eq "samba_share_section leaves one [nas-share]" "1" "$(grep -c '^\[nas-share\]' "$tmp/smb.conf")"
assert_contains "samba_share_section writes the settings" "read only = yes" "$(cat "$tmp/smb.conf")"
assert_contains "samba_share_section keeps other sections" $'[printers]\n   x = y' "$(cat "$tmp/smb.conf")"
assert_fails "samba_share_section is idempotent" samba_share_section "$tmp/smb.conf" nas-share /srv/share pi yes
rm -rf "$tmp"

dns_out="$(PIHOLE_DNS='9.9.9.9, 149.112.112.112#53'; declare -a l=(); pihole_dns_list l; printf '%s|' "${l[@]}")"
assert_eq "pihole_dns_list splits commas and spaces" "9.9.9.9|149.112.112.112#53|" "$dns_out"
assert_fails "pihole_dns_list rejects a host name" eval "PIHOLE_DNS=dns.google; declare -a l=(); pihole_dns_list l"

# raspi-config's nonint mode reads 0 as "enable": "do_ssh 1" switches SSH off
# and locks out a headless Pi after its next reboot.
assert_contains "base enables SSH (do_ssh 0)" "do_ssh 0" "$(declare -f run_base)"
assert_lacks "base never disables SSH" "do_ssh 1" "$(declare -f run_base)"
assert_contains "docker refreshes apt after adding its repository" "apt_update_now" "$(declare -f docker_install)"

# --- Settings: config/tasks/<task>.env, the central example and the tasks agree
example="$ROOT/config/rpi-setup.env.example"
example_names="$(sed -nE 's/^([A-Z][A-Z0-9_]*)=.*/\1/p' "$example" | sort)"
assert_eq "the central example sets each name once" "" "$(uniq -d <<<"$example_names")"
all_names=""
for n in "${names[@]}"; do
    prefix="${n^^}_"
    tpl="$ROOT/config/tasks/$n.env"
    if [[ ! -f "$tpl" ]]; then
        fail "task '$n' has no config/tasks/$n.env"
        continue
    fi
    tpl_names="$(task_setting_names "$n" | sort)"
    all_names+="$tpl_names"$'\n'
    assert_eq "config/tasks/$n.env holds names only" "" \
        "$(grep -vE '^[[:space:]]*(#|$)' "$tpl" | grep -vE '^[A-Z][A-Z0-9_]*=$' || true)"
    assert_eq "config/tasks/$n.env names all start with $prefix" "" "$(grep -v "^$prefix" <<<"$tpl_names" || true)"
    assert_eq "config/tasks/$n.env matches the $n section of the example" \
        "$(grep "^$prefix" <<<"$example_names" || true)" "$tpl_names"
    # Every setting the task file reads is listed, and every listed one is read.
    used="$(grep -oE "\\$\\{?${prefix}[A-Z0-9_]*" "$ROOT/tasks/$n.sh" | tr -d '${' | sort -u)"
    assert_eq "tasks/$n.sh reads exactly the settings in config/tasks/$n.env" "$tpl_names" "$used"
    # Every task has a page that documents each of its settings, linked from the README.
    doc="$ROOT/docs/tasks/$n.md"
    if [[ ! -f "$doc" ]]; then
        fail "task '$n' has no docs/tasks/$n.md"
    else
        assert_eq "docs/tasks/$n.md documents every setting in config/tasks/$n.env" "" \
            "$(while read -r s; do [[ -z "$s" ]] || grep -qF "\`$s\`" "$doc" || echo "$s"; done <<<"$tpl_names")"
    fi
    assert_contains "README links docs/tasks/$n.md" "(docs/tasks/$n.md)" "$(cat "$ROOT/README.md")"
done
assert_eq "every name in the example belongs to a task" "$example_names" "$(grep -v '^$' <<<"$all_names" | sort)"

# --- Run plan: order ------------------------------------------------------------
# A task that needs Docker installs it itself (container_require_docker in
# lib/containers.sh); setup.sh never adds a task to the run.
for n in "${names[@]}"; do
    if grep -Eq '(^|[^_[:alnum:]])require_docker' "$ROOT/tasks/$n.sh"; then
        fail "tasks/$n.sh calls require_docker; use container_require_docker, which installs Docker"
    fi
done
plan() { plan_tasks "$@"; echo "${PLAN[*]}"; }
assert_eq "plan keeps the given order" "web samba pihole" "$(plan web samba pihole)"
assert_eq "plan runs base first" "base web samba" "$(plan web samba base)"
assert_eq "plan drops repeats" "web netalertx" "$(plan web netalertx web)"
assert_eq "plan adds no task" "netalertx" "$(plan netalertx)"
assert_eq "plan runs firewall last" "web pihole firewall" "$(plan firewall web pihole)"
assert_eq "plan runs base first and firewall last" "base web firewall" "$(plan web firewall base)"
assert_eq "plan runs firewall once" "firewall" "$(plan firewall firewall)"
assert_eq "plan keeps firewall alone" "firewall" "$(plan firewall)"

# --- Run: continue after a failure, summary --------------------------------------
flow_tmp="$(mktemp -d)"
# flow NAME... - run stub tasks in a subshell, then print the summary and RUN_FAILED.
# docker fails through errexit, web through die; the others succeed.
# The run_* stubs are called by name from run_tasks.
# shellcheck disable=SC2329
flow() {
    (
        export RPI_SETUP_CONFIG_DIR="$flow_tmp/cfg"
        export RPI_SETUP_REBOOT_FILE="${REBOOT_FILE:-$flow_tmp/no-reboot}"
        export RPI_SETUP_MODEL_FILE="${MODEL_FILE:-$flow_tmp/no-model}"
        export RPI_SETUP_DONE_FILE="$flow_tmp/tasks.done"
        run_base()      { echo "ran-base"; }
        run_docker()    { echo "ran-docker"; false; echo "docker-went-on"; }
        run_netalertx() { echo "ran-netalertx"; }
        run_web()       { echo "ran-web"; die "web broke"; }
        run_samba()     { echo "ran-samba"; }
        run_tasks "$@"
        print_summary "$@"
        echo "RUN_FAILED=$RUN_FAILED"
    ) 2>&1
}
out="$(flow base docker netalertx web samba)"
assert_contains "a failing command ends its task" "ran-docker" "$out"
assert_lacks "errexit still applies inside a task" "docker-went-on" "$out"
assert_contains "the run goes on after a failed task" "ran-samba" "$out"
assert_eq "finished tasks are recorded for the runner, failed ones are not" "base netalertx samba" \
    "$(xargs <"$flow_tmp/tasks.done")"
printf 'monitoring\n' >>"$flow_tmp/tasks.done"
flow base >/dev/null
assert_eq "a recorded task removed from tasks/ is forgotten" "base netalertx samba" \
    "$(xargs <"$flow_tmp/tasks.done")"
out="$(flow base docker netalertx web samba)"
assert_contains "summary: ok task" "  base           ok" "$out"
assert_contains "summary: failed task" "  docker         failed" "$out"
assert_contains "summary: a task after a failed one runs" "  netalertx      ok" "$out"
assert_contains "summary: a task that died is failed" "  web            failed" "$out"
assert_contains "summary: task after the failures" "  samba          ok" "$out"
assert_contains "a failed task makes the run fail" "RUN_FAILED=1" "$out"
out="$(flow base samba)"
assert_contains "an all-ok run succeeds" "RUN_FAILED=0" "$out"
assert_lacks "no reboot hint off a Pi without /run/reboot-required" "Reboot recommended" "$out"
touch "$flow_tmp/reboot-required"
assert_contains "reboot hint when /run/reboot-required exists" "Reboot recommended" \
    "$(REBOOT_FILE="$flow_tmp/reboot-required" flow samba)"
printf 'Raspberry Pi 5 Model B Rev 1.0\0' >"$flow_tmp/model"
assert_contains "reboot hint after base on a Pi" "Reboot recommended" "$(MODEL_FILE="$flow_tmp/model" flow base)"

# The log gets stdout, stderr and a header; it is private and appended to.
log_out="$(
    RPI_SETUP_LOG="$flow_tmp/run.log"
    start_log web samba
    echo "to-stdout"
    echo "to-stderr" >&2
    print_summary
)"
assert_contains "the run still prints to the terminal" "to-stdout" "$log_out"
assert_contains "the summary names the log" "Full log of this run: $flow_tmp/run.log" "$log_out"
assert_contains "the log has a header per run" "===== rpi-setup run " "$(cat "$flow_tmp/run.log")"
assert_contains "the log header names the tasks" ": web samba =====" "$(cat "$flow_tmp/run.log")"
assert_contains "the log gets stdout" "to-stdout" "$(cat "$flow_tmp/run.log")"
assert_contains "the log gets stderr" "to-stderr" "$(cat "$flow_tmp/run.log")"
assert_eq "the log is private" "600" "$(stat -c %a "$flow_tmp/run.log")"
( RPI_SETUP_LOG="$flow_tmp/run.log"; start_log samba; echo "second-run" ) >/dev/null 2>&1
assert_eq "the log is appended to" "2" "$(grep -c '===== rpi-setup run ' "$flow_tmp/run.log")"
assert_eq "the log leaves stdin to the tasks" "stdin-kept" \
    "$(echo stdin-kept | ( RPI_SETUP_LOG="$flow_tmp/run.log"; start_log samba; read -r l; echo "$l" >&"$_LOG_OUT" ) 2>/dev/null | grep -x stdin-kept)"
rm -rf "$flow_tmp"

# --- CLI: --list works without root -------------------------------------------
listing="$(bash "$ROOT/setup.sh" --list)"
for n in "${names[@]}"; do
    assert_contains "--list shows task '$n'" " $n " "$listing"
done

# --- CLI: settings files ---------------------------------------------------------
cfg="$(mktemp -d)"
out="$(RPI_SETUP_CONFIG_DIR="$cfg" bash "$ROOT/setup.sh" --init-config 2>&1)"
assert_contains "--init-config creates the central file" "Created $cfg/rpi-setup.env" "$out"
assert_eq "--init-config copies the example" "$(cat "$ROOT/config/rpi-setup.env.example")" "$(cat "$cfg/rpi-setup.env")"
assert_eq "--init-config makes it private" "600" "$(stat -c %a "$cfg/rpi-setup.env")"
echo 'WEB_TITLE=Changed' >>"$cfg/rpi-setup.env"
assert_contains "--init-config never overwrites your file" "Keeping existing" \
    "$(RPI_SETUP_CONFIG_DIR="$cfg" bash "$ROOT/setup.sh" --init-config 2>&1)"
assert_contains "--init-config kept your change" "WEB_TITLE=Changed" "$(cat "$cfg/rpi-setup.env")"
assert_ok "--split-config splits the central file" env RPI_SETUP_CONFIG_DIR="$cfg" bash "$ROOT/setup.sh" --split-config
assert_contains "--split-config output carries the value" "WEB_TITLE='Changed'" "$(cat "$cfg/local/web.env")"
assert_ok "config/split.sh does the same" env RPI_SETUP_CONFIG_DIR="$cfg" bash "$ROOT/config/split.sh"
echo 'DOCKER_LOG_MAX_SIZE=10m' >>"$cfg/rpi-setup.env"
out="$(RPI_SETUP_CONFIG_DIR="$cfg" bash "$ROOT/setup.sh" --split-config 2>&1)" && rc=0 || rc=$?
assert_eq "--split-config accepts a removed setting" "0" "$rc"
assert_contains "--split-config warns about a removed setting" "'DOCKER_LOG_MAX_SIZE' is no longer a setting" "$out"
echo 'TAILSCALE_AUTHKEY=' >>"$cfg/rpi-setup.env"
out="$(RPI_SETUP_CONFIG_DIR="$cfg" bash "$ROOT/setup.sh" --split-config 2>&1)" && rc=0 || rc=$?
assert_eq "--split-config accepts a setting of a removed task" "0" "$rc"
assert_contains "--split-config warns about a removed task's setting" "'TAILSCALE_AUTHKEY' is no longer a setting" "$out"
echo 'DOCKER_LOG_MAX_SIZES=10m' >>"$cfg/rpi-setup.env"
assert_fails "--split-config still stops on an unknown setting" env RPI_SETUP_CONFIG_DIR="$cfg" bash "$ROOT/setup.sh" --split-config
rm -rf "$cfg"
assert_fails "setup.sh rejects an unknown option" bash "$ROOT/setup.sh" --bogus
assert_contains "--help explains the settings file" "rpi-setup.env" "$(bash "$ROOT/setup.sh" --help)"

# --- CLI: root handling -------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    assert_fails "setup.sh refuses to run tasks as non-root" bash "$ROOT/setup.sh" "$first"
    assert_contains "setup.sh explains it needs root" "run as root" \
        "$(bash "$ROOT/setup.sh" "$first" 2>&1 || true)"
    skip "root-only CLI tests (run with sudo to include them)"
else
    out="$(bash "$ROOT/setup.sh" no-such-task 2>&1 || true)"
    assert_fails "setup.sh exits non-zero on an unknown task" bash "$ROOT/setup.sh" no-such-task
    assert_contains "setup.sh reports the unknown task" "unknown task: no-such-task" "$out"

    out="$(printf '\n' | bash "$ROOT/setup.sh" 2>&1)"
    assert_contains "empty menu input cancels" "Cancelled." "$out"
    assert_contains "menu lists the tasks" " $first " "$out"

    out="$(printf 'abc\n' | bash "$ROOT/setup.sh" 2>&1)"
    assert_contains "non-numeric menu input cancels" "Cancelled." "$out"

    out="$(printf '1,2\n' | bash "$ROOT/setup.sh" --list 2>&1)"
    assert_contains "--list never prompts even with piped input" " $first " "$out"
fi

finish_tests
