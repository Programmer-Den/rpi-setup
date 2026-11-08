#!/usr/bin/env bash
# test-task-runner.sh - unit tests for tasks/runner.sh: setting checks, the
# platform name, the deploy command's argument checks and a full deploy
# against throw-away git repositories with a stub setup.sh.
# Nothing is downloaded and no runner is registered.
#
# Run: bash ci/test-task-runner.sh
# shellcheck disable=SC2016,SC2153
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"
. "$ROOT/lib/common.sh"
declare -a TASKS=()
. "$ROOT/tasks/runner.sh"

# CI runs this under sudo; the deploy command's SUDO_USER check has its own case.
unset SUDO_USER
tmp="$TMP"

assert_contains "runner registers its task" "runner|" "${TASKS[*]}"

# --- runner_check_settings ----------------------------------------------------
ok() { ( RUNNER_REPO="${R-me/rpi-private}" RUNNER_TOKEN="${K-}" RUNNER_NAME="${N-pi5}" \
         RUNNER_LABELS="${L-pi5}" RUNNER_BRANCHES="${B-main}" runner_check_settings ) >/dev/null 2>&1; }
assert_ok    "a filled repo and defaults are valid" ok
assert_fails "an empty RUNNER_REPO is refused" eval 'R= ok'
assert_contains "an empty RUNNER_REPO explains what to set" "private repository" \
    "$( (RUNNER_REPO='' RUNNER_TOKEN='' RUNNER_NAME=pi5 RUNNER_LABELS=pi5 RUNNER_BRANCHES=main runner_check_settings) 2>&1 || true)"
assert_fails "a URL instead of owner/name is refused" eval 'R=https://github.com/me/x ok'
assert_ok    "a token is accepted" eval 'K=AABBCC123 ok'
assert_fails "a token with odd characters is refused" eval 'K="abc;reboot" ok'
assert_fails "a bad runner name is refused" eval 'N="my pi" ok'
assert_ok    "several labels are valid" eval 'L=pi5,home ok'
assert_fails "labels with spaces are refused" eval 'L="pi5, home" ok'
assert_ok    "several branches are valid" eval 'B="main, next" ok'
assert_fails "a bad branch is refused" eval 'B="main;x" ok'
assert_ok    "a workflow branch is valid" eval '( RUNNER_WORKFLOW_BRANCH=release ok )'
assert_fails "a bad workflow branch is refused" eval '( RUNNER_WORKFLOW_BRANCH="main;x" ok )'

# --- runner_job_hook_script: only manual runs from the workflow branch --------
printf '%s\n' "$(runner_job_hook_script Me/rpi-private main)" >"$tmp/hook"
assert_ok "the job hook is valid bash" bash -n "$tmp/hook"
hook() { env -i PATH="$PATH" GITHUB_REPOSITORY="${HR-Me/rpi-private}" GITHUB_EVENT_NAME="${HE-workflow_dispatch}" \
           GITHUB_REF="${HF-refs/heads/main}" GITHUB_WORKFLOW_REF="${HW-Me/rpi-private/.github/workflows/deploy.yml@refs/heads/main}" \
           bash "$tmp/hook" 2>&1; }
assert_ok    "a manual run of a deploy workflow from main is accepted" hook
assert_contains "and the log names the workflow" "job accepted: deploy.yml@refs/heads/main" "$(hook)"
assert_ok    "the repository's name is compared without case" eval 'HR=me/RPI-private hook'
assert_fails "a push is refused" eval 'HE=push hook'
assert_fails "a pull request is refused" eval 'HE=pull_request hook'
assert_fails "a manual run from another branch is refused" eval 'HF=refs/heads/evil HW=Me/rpi-private/.github/workflows/deploy.yml@refs/heads/evil hook'
assert_fails "a workflow from another branch is refused" eval 'HW=Me/rpi-private/.github/workflows/deploy.yml@refs/heads/evil hook'
assert_fails "a tag is refused" eval 'HF=refs/tags/main hook'
assert_fails "another repository is refused" eval 'HR=other/repo hook'
assert_fails "a workflow of another repository is refused" eval 'HW=other/repo/.github/workflows/deploy.yml@refs/heads/main hook'
assert_fails "missing job variables are refused" eval 'HR= HE= HF= HW= hook'
assert_contains "a refusal says what the runner takes" "only takes manual runs (Run workflow) of Me/rpi-private's workflows from main" "$(HE=push hook || true)"
assert_contains "and why this job is not one" "started by push" "$(HE=push hook || true)"
printf '%s\n' "$(runner_job_hook_script 'me/x;reboot' main)" >"$tmp/hook-odd"
assert_ok "odd characters in the settings are quoted" bash -n "$tmp/hook-odd"

# --- runner_check_registration: changed settings after registration ----------
mkdir -p "$tmp/reg"
printf '{"agentName":"pi5","gitHubUrl":"https://github.com/me/rpi-private","workFolder":"_work"}\n' >"$tmp/reg/.runner"
printf 'pi5,home\n' >"$tmp/reg/.labels"
reg() { ( RUNNER_REPO="${1:-me/rpi-private}" RUNNER_NAME="${2:-pi5}" RUNNER_LABELS="${3:-pi5,home}" runner_check_registration "$tmp/reg" ) 2>&1; }
assert_eq "the same settings as registered say nothing" "" "$(reg)"
assert_contains "another repository is noticed" "RUNNER_REPO (registered: me/rpi-private)" "$(reg me/other)"
assert_contains "another name is noticed" "RUNNER_NAME (registered: pi5)" "$(reg me/rpi-private pi6)"
assert_contains "other labels are noticed" "RUNNER_LABELS (registered: pi5,home)" "$(reg me/rpi-private pi5 pi5)"
assert_contains "the warning says how to register again" "put a new token in RUNNER_TOKEN and run: sudo bash setup.sh runner" "$(reg me/other)"
assert_contains "and what to remove first" "rm -f .runner" "$(reg me/other)"
rm -f "$tmp/reg/.labels"
assert_eq "an older registration without .labels only compares what .runner holds" "" "$(reg me/rpi-private pi5 other)"

# --- runner_service_installed: the unit file, not "svc.sh status" ------------
mkdir -p "$tmp/svc" "$tmp/units"
assert_fails "no .service file: not installed" eval 'RPI_RUNNER_UNIT_DIR="$tmp/units" runner_service_installed "$tmp/svc"'
printf 'actions.runner.me-rpi-private.pi5.service\n' >"$tmp/svc/.service"
assert_fails "a .service file without the unit: not installed" eval 'RPI_RUNNER_UNIT_DIR="$tmp/units" runner_service_installed "$tmp/svc"'
touch "$tmp/units/actions.runner.me-rpi-private.pi5.service"
assert_ok "unit file present: installed (even when stopped)" eval 'RPI_RUNNER_UNIT_DIR="$tmp/units" runner_service_installed "$tmp/svc"'

# --- runner_platform ----------------------------------------------------------
assert_eq "Pi 5 64-bit" linux-arm64 "$(runner_platform aarch64)"
assert_eq "x86_64" linux-x64 "$(runner_platform x86_64)"
assert_eq "32-bit Pi OS" linux-arm "$(runner_platform armv7l)"

# --- the generated deploy command ---------------------------------------------
script="$(runner_deploy_script /home/pi/rpi-setup "main,next")"
assert_ok "the deploy command is valid bash" bash -n <(printf '%s\n' "$script")
assert_contains "the deploy command knows the allowed branches" 'DP_BRANCHES=main\ next' "$script"
assert_contains "the deploy command knows the runner account" 'DP_RUNNER_USER=rpi-runner' "$script"
assert_contains "the deploy command checks the checkout owner" 'deploy_run_owner ()' "$script"
assert_contains "the deploy command checks where the settings are" 'deploy_run_check_config ()' "$script"
assert_contains "the deploy command knows where it is installed" 'DP_SELF=/usr/local/sbin/rpi-setup-deploy' "$script"

# --- deploy_run_args ----------------------------------------------------------
args() { ( DP_BRANCHES="main next"; deploy_run_args "$@" && printf '%s|%s|%s' "$DP_BRANCH" "$DP_CONFIG" "$DP_TASKS" ) 2>/dev/null; }
assert_eq "defaults to the first allowed branch" "main||" "$(args)"
assert_eq "--update is accepted" "1" "$( (DP_BRANCHES=main; deploy_run_args --update --tasks base && echo "$DP_UPDATE") 2>/dev/null)"
assert_eq "tasks may be comma separated" "next||base pihole" "$(args --branch next --tasks base,pihole)"
assert_fails "a branch not in RUNNER_BRANCHES is refused" args --branch evil
assert_fails "a task with odd characters is refused" args --tasks 'base;reboot'
assert_fails "an unknown argument is refused" args --force
assert_fails "a task word starting with '-' is refused" args --tasks '--move-config'
assert_fails "an option hidden after a task is refused" args --tasks 'base --init-config'
assert_fails "an option hidden after a comma is refused" args --tasks 'base,-x'
assert_eq "a '-' inside a task name is fine" "main||my-task" "$(args --tasks my-task)"
assert_eq "--skip may be comma separated" "pihole web" "$( (DP_BRANCHES=main; deploy_run_args --skip pihole,web && echo "$DP_SKIP") 2>/dev/null)"
assert_fails "a skipped task with odd characters is refused" args --skip 'web;reboot'
assert_fails "an option hidden in --skip is refused" args --skip 'web --init-config'
assert_fails "a missing settings file is refused" args --config "$tmp/nope.env"
assert_eq "--commit takes a full commit id" "0123456789abcdef0123456789abcdef01234567" \
    "$( (DP_BRANCHES=main; deploy_run_args --commit 0123456789abcdef0123456789abcdef01234567 && echo "$DP_COMMIT") 2>/dev/null)"
assert_fails "a short commit id is refused" args --commit 0123456
assert_fails "a ref name instead of a commit id is refused" args --commit main
assert_fails "an upper-case or odd commit id is refused" args --commit '0123456789ABCDEF0123456789abcdef01234567'
# An option as the last argument used to make "shift 2" fail and the loop spin forever.
for opt in --tasks --skip --branch --commit --config; do
    assert_eq "$opt as the last argument is refused, not hung" "rpi-setup-deploy: $opt needs a value" \
        "$( (DP_BRANCHES=main; timeout 5 bash -c "$(declare -f deploy_run_args); DP_BRANCHES=main deploy_run_args --update $opt") 2>&1 || true)"
done
assert_contains "a bad task word is printed so that a tab is visible" "(got \$'base\\tweb')" \
    "$( (DP_BRANCHES=main; deploy_run_args --tasks $'base\tweb') 2>&1 || true)"
assert_contains "an unknown argument is printed the same way" "unknown argument \$'--force\\r'" \
    "$( (DP_BRANCHES=main; deploy_run_args $'--force\r') 2>&1 || true)"
if [[ $EUID -eq 0 ]] && id nobody >/dev/null 2>&1; then
    printf 'X=1\n' >"$tmp/root-only.env"; chmod 600 "$tmp/root-only.env"
    assert_fails "a settings file the sudo caller cannot read is refused" \
        eval 'SUDO_USER=nobody args --config "$tmp/root-only.env"'
else
    skip "sudo caller check (run with sudo to include it)"
fi

# --- deploy_run_owner ---------------------------------------------------------
owner() { ( DP_DIR="$1" DP_RUNNER_USER="${2:-rpi-runner}"; deploy_run_owner ) 2>/dev/null; }
mkdir "$tmp/own"
if [[ $EUID -eq 0 ]]; then
    assert_fails "a root-owned checkout is refused" owner "$tmp/own"
    if id nobody >/dev/null 2>&1; then
        chown nobody "$tmp/own"
        assert_eq "setup.sh's user is the checkout owner" nobody "$(owner "$tmp/own")"
        assert_fails "a checkout owned by the runner account is refused" owner "$tmp/own" nobody
    fi
else
    assert_eq "setup.sh's user is the checkout owner" "$(id -un)" "$(owner "$tmp/own")"
    assert_fails "a checkout owned by the runner account is refused" owner "$tmp/own" "$(id -un)"
    skip "root-owned checkout (run with sudo to include it)"
fi
assert_contains "a refused owner explains the fix" "chown" \
    "$( (DP_DIR="$tmp/own" DP_RUNNER_USER="$(stat -c %U "$tmp/own")"; deploy_run_owner) 2>&1 || true)"

# --- deploy_run_check_config --------------------------------------------------
cfg() { ( DP_DIR="$tmp/cc" DP_CONFIG_DIR="$tmp/cc-etc" DP_CONFIG="${1:-}"; deploy_run_check_config ) 2>/dev/null; }
mkdir -p "$tmp/cc/config"
assert_ok "no settings anywhere runs with defaults" cfg
printf 'X=1\n' >"$tmp/cc/config/rpi-setup.env"
assert_fails "settings only in the checkout are refused" cfg
assert_contains "the refusal names --move-config" "setup.sh --move-config" \
    "$( (DP_DIR="$tmp/cc" DP_CONFIG_DIR="$tmp/cc-etc" DP_CONFIG=''; deploy_run_check_config) 2>&1 || true)"
assert_ok "with --config the checkout settings do not matter" cfg "$tmp/cc/config/rpi-setup.env"
mkdir "$tmp/cc-etc"; printf 'X=1\n' >"$tmp/cc-etc/rpi-setup.env"
assert_ok "settings in the system folder are used" cfg

# --- a deploy against local repositories --------------------------------------
git_q() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
git_q init --bare "$tmp/origin.git"
git_q clone "$tmp/origin.git" "$tmp/work"
cat >"$tmp/work/setup.sh" <<STUB
#!/usr/bin/env bash
echo "generated password: hunter2"
echo "\$* cfg=\$RPI_SETUP_CONFIG_DIR" >"$tmp/ran"
echo "\$SUDO_USER" >"$tmp/ran-user"
echo 'Summary:'
echo "  \$1 ok"
STUB
cat >"$tmp/work/update.sh" <<STUB
#!/usr/bin/env bash
echo "\$*" >"$tmp/updated"
echo 'Summary:'
echo '  containers ok'
STUB
git_q -C "$tmp/work" add setup.sh update.sh
git_q -C "$tmp/work" commit -m one
git_q -C "$tmp/work" push origin main
git_q clone "$tmp/origin.git" "$tmp/pi"
# The task files only arrive with the fetch, so the name check must run after it.
mkdir "$tmp/work/tasks"
touch "$tmp/work/tasks/base.sh" "$tmp/work/tasks/pihole.sh" "$tmp/work/tasks/web.sh"
git_q -C "$tmp/work" add tasks
git_q -C "$tmp/work" commit -m two
git_q -C "$tmp/work" push origin main
printf 'WEB_TITLE=Mine\n' >"$tmp/settings.env"
if [[ $EUID -eq 0 ]] && id nobody >/dev/null 2>&1; then DEPLOY_OWNER=nobody; else DEPLOY_OWNER="$(id -un)"; fi

assert_fails "an unknown task is refused" eval 'deploy --tasks "base nope" >/dev/null'
assert_ok "and runs no setup" test ! -e "$tmp/ran"

deploy() {
    rm -f "$tmp/ran"
    (
        DP_DIR="$tmp/pi" DP_BRANCHES=main DP_DONE_FILE="$tmp/done" DP_CONFIG_DIR="$tmp/etc"
        DP_LOG_DIR="$tmp/log" DP_LOCK="$tmp/lock"
        # The owner check has its own cases above; under sudo the throw-away
        # checkout belongs to root, so stand in a regular account here.
        deploy_run_owner() { printf '%s\n' "$DEPLOY_OWNER"; }
        deploy_run "$@"
    ) 2>&1
}
out="$(deploy --config "$tmp/settings.env" --tasks "base pihole")"
assert_eq "the checkout is updated to the branch tip" "$(git -C "$tmp/work" rev-parse HEAD)" "$(git -C "$tmp/pi" rev-parse HEAD)"
assert_eq "the settings are installed" "WEB_TITLE=Mine" "$(cat "$tmp/etc/rpi-setup.env")"
assert_eq "the settings are private" "600" "$(stat -c %a "$tmp/etc/rpi-setup.env")"
assert_eq "setup.sh runs the tasks with the installed settings" "base pihole cfg=$tmp/etc" "$(cat "$tmp/ran")"
assert_eq "setup.sh acts for the checkout owner, not the runner" "$DEPLOY_OWNER" "$(cat "$tmp/ran-user")"
assert_contains "the summary reaches the workflow log" "base ok" "$out"
assert_lacks "setup.sh's full output (passwords) stays out of the workflow log" "hunter2" "$out"
assert_contains "the full output is kept on the Pi" "hunter2" "$(cat "$tmp"/log/deploy-*.log)"

# A failed task: its error line reaches the workflow log, nothing else does.
cp "$tmp/work/setup.sh" "$tmp/setup.ok"
cat >"$tmp/work/setup.sh" <<STUB
#!/usr/bin/env bash
echo "generated password: hunter2"
printf '\033[31m[x]\033[0m Port 8080 is used by nginx; set DENWATCHER_PORT to a free port\n'
echo 'Summary:'
echo "  \$1 failed"
exit 1
STUB
git_q -C "$tmp/work" commit -am failing
git_q -C "$tmp/work" push origin main
out="$(deploy --tasks web || true)"
assert_contains "a failed task's error line reaches the workflow log" \
    "rpi-setup-deploy: error: Port 8080 is used by nginx; set DENWATCHER_PORT to a free port" "$out"
assert_contains "and so does the summary" "web failed" "$out"
assert_lacks "a failed run keeps the passwords on the Pi" "hunter2" "$out"
cp "$tmp/setup.ok" "$tmp/work/setup.sh"
git_q -C "$tmp/work" commit -am fixed
git_q -C "$tmp/work" push origin main

out="$(deploy)"
assert_contains "no tasks and none recorded does nothing" "none recorded" "$out"
assert_ok "and runs no setup" test ! -e "$tmp/ran"
printf 'base\nweb\n' >"$tmp/done"
deploy >/dev/null
assert_eq "no tasks reruns the recorded ones" "base web cfg=$tmp/etc" "$(cat "$tmp/ran")"
assert_fails "a branch outside RUNNER_BRANCHES never touches the checkout" eval 'deploy --branch other >/dev/null'
printf 'gone\n' >>"$tmp/done"
out="$(deploy)"
assert_eq "a recorded task removed from the checkout is skipped" "base web cfg=$tmp/etc" "$(cat "$tmp/ran")"
assert_contains "and the workflow log says so" "skipping 'gone'" "$out"
assert_fails "a given task missing from the checkout is still refused" eval 'deploy --tasks gone >/dev/null'
out="$(deploy --skip web)"
assert_eq "--skip leaves a recorded task out" "base cfg=$tmp/etc" "$(cat "$tmp/ran")"
assert_contains "and the workflow log says so" "skipping 'web' (--skip)" "$out"
deploy --tasks "base pihole web" --skip "pihole,web" >/dev/null
assert_eq "--skip leaves a given task out" "base cfg=$tmp/etc" "$(cat "$tmp/ran")"
out="$(deploy --tasks web --skip web)"
assert_contains "skipping every task runs nothing" "none recorded" "$out"
assert_ok "and runs no setup" test ! -e "$tmp/ran"
assert_fails "an unknown task to skip is refused (a typo)" eval 'deploy --skip wbe >/dev/null'

# --commit: exactly that commit of the branch, also back to an older one.
tip="$(git -C "$tmp/work" rev-parse HEAD)"
older="$(git -C "$tmp/work" rev-parse HEAD~2)"
out="$(deploy --commit "$older" --tasks base)"
assert_eq "--commit moves the checkout back to an older commit of the branch" "$older" "$(git -C "$tmp/pi" rev-parse HEAD)"
assert_contains "and the workflow log says it is pinned" "at ${older:0:7} (pinned)" "$out"
assert_eq "and runs the tasks there" "base cfg=$tmp/etc" "$(cat "$tmp/ran")"
deploy --commit "$tip" --tasks base >/dev/null
assert_eq "--commit moves the checkout forward to a newer one" "$tip" "$(git -C "$tmp/pi" rev-parse HEAD)"
deploy --commit "$tip" --tasks base >/dev/null
assert_eq "--commit with the checkout already there is fine" "$tip" "$(git -C "$tmp/pi" rev-parse HEAD)"
git_q -C "$tmp/work" checkout -b side
git_q -C "$tmp/work" commit --allow-empty -m side
git_q -C "$tmp/work" push origin side
side="$(git -C "$tmp/work" rev-parse HEAD)"
git_q -C "$tmp/work" checkout main
assert_fails "a commit that is not on the branch is refused" eval 'deploy --commit "$side" --tasks base >/dev/null'
assert_ok "and runs no setup" test ! -e "$tmp/ran"
assert_eq "and leaves the checkout alone" "$tip" "$(git -C "$tmp/pi" rev-parse HEAD)"
assert_contains "the refusal names the branch" "is not on origin/main" "$(deploy --commit "$side" --tasks base || true)"
assert_fails "an unknown commit is refused" eval 'deploy --commit 0123456789abcdef0123456789abcdef01234567 --tasks base >/dev/null'
rm -rf "${tmp:?}/etc"
mkdir -p "$tmp/pi/config"; printf 'X=1\n' >"$tmp/pi/config/rpi-setup.env"
rm -f "$tmp/ran"
out="$(deploy --tasks base || true)"
assert_contains "settings left in the checkout stop the deploy" "--move-config" "$out"
assert_ok "and run no setup" test ! -e "$tmp/ran"

# --- the deploy command writes itself again from the updated checkout ---------
mkdir -p "$tmp/fresh/tasks"
cp "$ROOT/tasks/runner.sh" "$tmp/fresh/tasks/runner.sh"
printf '#!/usr/bin/env bash\necho old\n' >"$tmp/self"
refresh() { ( DP_DIR="$tmp/fresh" DP_BRANCHES=main DP_DONE_FILE="$tmp/done" DP_SELF="$tmp/self"; deploy_run_refresh ) 2>&1; }
assert_fails "an outdated deploy command is replaced and run again" refresh
assert_contains "it is written from the checkout's deploy code" 'deploy_run_refresh ()' "$(cat "$tmp/self")"
assert_contains "for the same checkout" "DP_DIR=$tmp/fresh" "$(cat "$tmp/self")"
assert_contains "and the same done file" "DP_DONE_FILE=$tmp/done" "$(cat "$tmp/self")"
assert_eq "and it stays executable" "755" "$(stat -c %a "$tmp/self")"
assert_ok "a current deploy command is left alone" refresh
printf 'stale\n' >"$tmp/self"
assert_ok "a command that was just written is not replaced again" eval '( DP_FRESH=1; refresh )'
assert_eq "so it is not touched" "stale" "$(cat "$tmp/self")"
assert_ok "without DP_SELF (an older command) nothing is written" eval '( unset DP_SELF; DP_DIR="$tmp/fresh"; deploy_run_refresh )'
rm -rf "${tmp:?}/fresh" "$tmp/self"

# --- --update: containers, then only the new tasks ----------------------------
rm -rf "${tmp:?}/pi/config"
printf 'base\nweb\n' >"$tmp/done"
rm -f "$tmp/updated"
out="$(deploy --update)"
assert_eq "--update updates the containers only" "--containers-only" "$(cat "$tmp/updated")"
assert_contains "the update summary reaches the workflow log" "containers ok" "$out"
assert_contains "--update without tasks reports none new" "no new tasks" "$out"
assert_ok "and reruns no recorded task" test ! -e "$tmp/ran"
deploy --update --tasks "base pihole web" >/dev/null
assert_eq "--update runs only the tasks not yet set up" "pihole cfg=$tmp/etc" "$(cat "$tmp/ran")"
rm -f "$tmp/ran"
deploy --update --tasks "base pihole web" --skip pihole >/dev/null
assert_ok "--update with --skip leaves a new task out" test ! -e "$tmp/ran"
assert_eq "and the containers of the skipped tasks alone" "--containers-only --skip pihole" "$(cat "$tmp/updated")"
rm -f "$tmp/updated"
assert_fails "--update refuses an unknown task" eval 'deploy --update --tasks nope >/dev/null'
assert_ok "before updating anything" test ! -e "$tmp/updated"

# --- an outdated deploy command writes itself again and runs the new one ------
# The fixture repository gets a copy of tasks/runner.sh whose fixed paths
# point into the temp folder, so the command written from it runs here.
sed -e "s|^RPI_DEPLOY_CMD=.*|RPI_DEPLOY_CMD=$tmp/self|" \
    -e "s|DP_CONFIG_DIR=/etc/rpi-setup|DP_CONFIG_DIR=$tmp/etc|" \
    -e "s|DP_LOG_DIR=/var/log/rpi-setup-deploy|DP_LOG_DIR=$tmp/log|" \
    -e "s|DP_LOCK=/run/rpi-setup-deploy.lock|DP_LOCK=$tmp/lock|" \
    "$ROOT/tasks/runner.sh" >"$tmp/work/tasks/runner.sh"
git_q -C "$tmp/work" add tasks/runner.sh
git_q -C "$tmp/work" commit -m runner
git_q -C "$tmp/work" push origin main
# The outdated command: written from that copy, with one extra line.
( RPI_SETUP_DONE_FILE="$tmp/done"; TASKS=(); . "$tmp/work/tasks/runner.sh"; runner_deploy_script "$tmp/pi" main ) >"$tmp/self"
sed -i 's/^deploy_run "\$@"$/# outdated\n&/' "$tmp/self"
chmod 0755 "$tmp/self"
printf 'base\n' >"$tmp/done"
rm -f "$tmp/ran" "$tmp/lock"
if [[ $EUID -eq 0 ]]; then
    # The real command refuses a root-owned checkout; hand it to a regular
    # account, which then also runs git in it.
    chmod 0755 "$TMP"
    chown -R "$DEPLOY_OWNER" "$tmp/pi" "$tmp/origin.git"
fi
out="$(DP_FRESH='' "$tmp/self" --tasks base 2>&1)" || fail "the self-updating deploy failed: $out"
assert_eq "the outdated command replaces itself once" "1" "$(grep -c "updated $tmp/self from the checkout; running the new one" <<<"$out")"
assert_eq "the new command runs the deploy once" "1" "$(grep -c 'running setup.sh base' <<<"$out")"
assert_eq "with the given task" "base cfg=$tmp/etc" "$(cat "$tmp/ran")"
assert_lacks "the new command is not outdated" "# outdated" "$(cat "$tmp/self")"
assert_contains "and points at itself" "DP_SELF=$tmp/self" "$(cat "$tmp/self")"
assert_ok "the lock is free afterwards" flock -n "$tmp/lock" true

finish_tests
