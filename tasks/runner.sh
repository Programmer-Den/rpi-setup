#!/usr/bin/env bash
# Task: runner - a GitHub Actions runner on this Pi for a PRIVATE repository
# of yours, so a manual "Deploy" workflow there can update the Pi: it pulls
# this public repo, installs your settings and reruns tasks with setup.sh.
# The runner only connects out to GitHub; no SSH key, Tailscale key or Pi
# address is stored at GitHub. Never register it to a public repository:
# pull requests from strangers could then run code on the Pi.
# Template workflow and private-repo layout: templates/private-repo/.
# Settings: RUNNER_* in config/rpi-setup.env (names in config/tasks/runner.env).
set -euo pipefail

TASKS+=("runner|GitHub runner for a manual Deploy workflow in your private repo")

RPI_RUNNER_USER=rpi-runner
RPI_RUNNER_DIR=/opt/rpi-runner
RPI_DEPLOY_CMD=/usr/local/sbin/rpi-setup-deploy
RPI_DEPLOY_SUDOERS=/etc/sudoers.d/rpi-setup-runner
# Run by the runner before every job; refuses jobs that are not a manual run
# of a workflow from RUNNER_WORKFLOW_BRANCH (see runner_job_hook_script).
# The runner only runs a hook whose name ends in .sh, .ps1 or .js and fails
# every job otherwise.
RPI_RUNNER_JOB_HOOK=/usr/local/libexec/rpi-setup/runner-job-started.sh
# Tasks that finished at least once, one per line; written by setup.sh.
RPI_SETUP_DONE_FILE="${RPI_SETUP_DONE_FILE:-/var/lib/rpi-setup/tasks.done}"

run_runner() {
  : "${RUNNER_REPO:=}" "${RUNNER_TOKEN:=}" "${RUNNER_NAME:=}" "${RUNNER_LABELS:=}" "${RUNNER_BRANCHES:=main}" \
    "${RUNNER_WORKFLOW_BRANCH:=main}"
  [[ -n "$RUNNER_NAME" ]] || RUNNER_NAME="$(hostname)"
  [[ -n "$RUNNER_LABELS" ]] || RUNNER_LABELS="$RUNNER_NAME"
  runner_check_settings

  git -C "$RPI_SETUP_ROOT" rev-parse --git-dir >/dev/null 2>&1 ||
    die "$RPI_SETUP_ROOT is not a git checkout; clone the repository with git so the Deploy workflow can update it."
  apt_install git curl jq tar sudo

  install -m 0755 -d "$(dirname "$RPI_DEPLOY_CMD")"
  if runner_deploy_script "$RPI_SETUP_ROOT" "$RUNNER_BRANCHES" | write_if_changed "$RPI_DEPLOY_CMD" 0755; then
    say "Wrote $RPI_DEPLOY_CMD"
  fi

  if ! id "$RPI_RUNNER_USER" >/dev/null 2>&1; then
    local uid
    uid="$(assign_uid "$RPI_RUNNER_USER")"
    groupadd --system --gid "$uid" "$RPI_RUNNER_USER"
    useradd --system --uid "$uid" --gid "$uid" --home-dir "$RPI_RUNNER_DIR" --shell /usr/sbin/nologin "$RPI_RUNNER_USER"
    say "Created user $RPI_RUNNER_USER ($uid)"
  fi
  install -m 0750 -o "$RPI_RUNNER_USER" -g "$RPI_RUNNER_USER" -d "$RPI_RUNNER_DIR"

  # The runner user may run exactly one command as root: the deploy command,
  # which checks its arguments before doing anything.
  local tmp
  tmp="$(mktemp)"
  printf '# Written by rpi-setup (tasks/runner.sh).\n%s ALL=(root) NOPASSWD: %s\n' "$RPI_RUNNER_USER" "$RPI_DEPLOY_CMD" >"$tmp"
  visudo -cqf "$tmp" || { rm -f "$tmp"; die 'The sudoers rule for the runner did not validate.'; }
  write_if_changed "$RPI_DEPLOY_SUDOERS" 0440 <"$tmp" && say "Wrote $RPI_DEPLOY_SUDOERS"
  rm -f "$tmp"

  if [[ ! -x "$RPI_RUNNER_DIR/config.sh" ]]; then
    runner_download "$RPI_RUNNER_DIR"
    "$RPI_RUNNER_DIR/bin/installdependencies.sh" >/dev/null
  fi

  if [[ -f "$RPI_RUNNER_DIR/.runner" ]]; then
    info "Runner already registered ($(jq -r '.agentName + " at " + .gitHubUrl' "$RPI_RUNNER_DIR/.runner" 2>/dev/null || echo 'see .runner'))"
    runner_check_registration "$RPI_RUNNER_DIR"
  else
    [[ -n "$RUNNER_TOKEN" ]] || die "RUNNER_TOKEN is empty. In https://github.com/$RUNNER_REPO/settings/actions/runners/new copy the token after --token, put it in RUNNER_TOKEN (valid for one hour) and run: sudo bash setup.sh runner"
    # The one-time token goes on config.sh's command line (its only way to
    # take it); it is worthless after this call.
    ( cd "$RPI_RUNNER_DIR" &&
      runuser -u "$RPI_RUNNER_USER" -- ./config.sh --unattended --replace \
        --url "https://github.com/$RUNNER_REPO" --token "$RUNNER_TOKEN" \
        --name "$RUNNER_NAME" --labels "$RUNNER_LABELS" --work _work ) ||
      die "Registering the runner failed. A token is valid for one hour; get a new one at https://github.com/$RUNNER_REPO/settings/actions/runners/new"
    # .runner holds the repository and name but not the labels.
    printf '%s\n' "$RUNNER_LABELS" >"$RPI_RUNNER_DIR/.labels"
    say "Runner '$RUNNER_NAME' registered to $RUNNER_REPO (labels: $RUNNER_LABELS)"
    info 'The token is no longer needed; you can empty RUNNER_TOKEN.'
  fi

  # svc.sh status exits 3 for an installed but stopped service, so it cannot
  # tell "not installed" apart; the unit file can.
  ( cd "$RPI_RUNNER_DIR" && { runner_service_installed "$RPI_RUNNER_DIR" || ./svc.sh install "$RPI_RUNNER_USER" >/dev/null; } ) ||
    die "Could not install the runner service (see: cd $RPI_RUNNER_DIR && sudo ./svc.sh status)"
  runner_install_job_hook "$RPI_RUNNER_DIR"
  ( cd "$RPI_RUNNER_DIR" && ./svc.sh start >/dev/null ) ||
    die "Could not start the runner service (see: cd $RPI_RUNNER_DIR && sudo ./svc.sh status)"
  say "Runner service running. Deploy from https://github.com/$RUNNER_REPO/actions with the 'Deploy to Pi' workflow."
  info "The deploy command accepts these branches of this repo: $RUNNER_BRANCHES"
  info "The runner only takes manual runs (Run workflow) of $RUNNER_REPO's workflows from its branch $RUNNER_WORKFLOW_BRANCH"
}

# Install the job-started hook (runner_job_hook_script) for the runner in $1
# through a systemd drop-in of its unit. Both files belong to root, so a job,
# which runs as the runner account, cannot change or remove them. A changed
# drop-in restarts the runner; inside a deploy (RPI_SETUP_FROM_DEPLOY) that
# job is still running, so the restart waits two minutes.
runner_install_job_hook() {
  local dir="$1" unit dropin changed=0
  unit="$(head -n1 "$dir/.service")"
  dropin="${RPI_RUNNER_UNIT_DIR:-/etc/systemd/system}/$unit.d/rpi-setup-job-check.conf"
  install -m 0755 -d "$(dirname "$RPI_RUNNER_JOB_HOOK")" "$(dirname "$dropin")"
  if runner_job_hook_script "$RUNNER_REPO" "$RUNNER_WORKFLOW_BRANCH" | write_if_changed "$RPI_RUNNER_JOB_HOOK" 0755; then
    say "Wrote $RPI_RUNNER_JOB_HOOK"
  fi
  # The hook's old name without .sh, which the runner refused to run.
  rm -f "${RPI_RUNNER_JOB_HOOK%.sh}"
  if printf '# Written by rpi-setup (tasks/runner.sh).\n[Service]\nEnvironment=ACTIONS_RUNNER_HOOK_JOB_STARTED=%s\n' "$RPI_RUNNER_JOB_HOOK" |
       write_if_changed "$dropin" 0644; then
    say "Wrote $dropin"
    changed=1
  fi
  [[ $changed -eq 1 ]] || return 0
  systemctl daemon-reload
  systemctl is-active --quiet "$unit" || return 0
  if [[ -n "${RPI_SETUP_FROM_DEPLOY:-}" ]] &&
     systemd-run --quiet --collect --on-active=120 systemctl restart "$unit"; then
    info "The runner restarts in two minutes, once this deploy is done, to load the job check."
  else
    systemctl restart "$unit"
  fi
}

# Print the runner's job-started hook. The runner runs it before each job's
# first step and fails the job when it exits non-zero, so nothing of the job
# runs. It accepts only manual runs (workflow_dispatch) of a workflow of
# repository $1 from its branch $2: a workflow pushed to another branch, or
# "Run workflow" from another branch, never reaches the Pi, where every job
# can run the deploy command as root. GITHUB_* cannot be set by a workflow.
runner_job_hook_script() {
  printf '#!/usr/bin/env bash\n'
  printf '# Written by rpi-setup (tasks/runner.sh). Change RUNNER_REPO or\n'
  printf '# RUNNER_WORKFLOW_BRANCH and re-run "sudo bash setup.sh runner" instead.\n'
  printf 'set -euo pipefail\n'
  printf 'repo=%q\n' "$1"
  printf 'ref=%q\n' "refs/heads/$2"
  cat <<'EOF2'
refuse() {
  echo "rpi-setup: this runner only takes manual runs (Run workflow) of $repo's workflows from ${ref#refs/heads/}; $1" >&2
  exit 1
}
[[ "${GITHUB_REPOSITORY:-}" == "$repo" || "${GITHUB_REPOSITORY,,}" == "${repo,,}" ]] ||
  refuse "this job is from ${GITHUB_REPOSITORY:-an unknown repository}"
[[ "${GITHUB_EVENT_NAME:-}" == workflow_dispatch ]] ||
  refuse "this job was started by ${GITHUB_EVENT_NAME:-an unknown event}"
[[ "${GITHUB_REF:-}" == "$ref" ]] ||
  refuse "this job runs from ${GITHUB_REF:-an unknown ref}"
workflow="${GITHUB_WORKFLOW_REF:-}"
[[ "${workflow,,}" == "${repo,,}/.github/workflows/"*"@${ref,,}" ]] ||
  refuse "this job runs the workflow ${workflow:-(unknown)}"
echo "rpi-setup: job accepted: ${workflow#*/.github/workflows/}"
EOF2
}

# Dies naming the setting if a RUNNER_* value is unusable.
runner_check_settings() {
  local b
  [[ -n "$RUNNER_REPO" ]] ||
    die 'RUNNER_REPO is empty: set it to your private repository, e.g. Chriszly/rpi-private (see templates/private-repo/README.md).'
  [[ "$RUNNER_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    die "RUNNER_REPO must look like owner/name (got '$RUNNER_REPO')"
  [[ -z "$RUNNER_TOKEN" || "$RUNNER_TOKEN" =~ ^[A-Za-z0-9]+$ ]] ||
    die 'RUNNER_TOKEN must be the token shown after --token on the "New self-hosted runner" page.'
  [[ "$RUNNER_NAME" =~ ^[A-Za-z0-9._-]{1,64}$ ]] ||
    die "RUNNER_NAME may use letters, digits, '.', '_' and '-' (got '$RUNNER_NAME')"
  [[ "$RUNNER_LABELS" =~ ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$ ]] ||
    die "RUNNER_LABELS must be comma separated words such as pi5,home (got '$RUNNER_LABELS')"
  [[ -n "$RUNNER_BRANCHES" ]] || die 'RUNNER_BRANCHES must name at least one branch, e.g. main'
  if [[ ! "${RUNNER_WORKFLOW_BRANCH:-main}" =~ ^[A-Za-z0-9._/-]+$ || "${RUNNER_WORKFLOW_BRANCH:-main}" == -* ]] ||
     ! git check-ref-format --branch "${RUNNER_WORKFLOW_BRANCH:-main}" >/dev/null 2>&1; then
    die "RUNNER_WORKFLOW_BRANCH: '$RUNNER_WORKFLOW_BRANCH' is not a branch name"
  fi
  for b in ${RUNNER_BRANCHES//,/ }; do
    if [[ ! "$b" =~ ^[A-Za-z0-9._/-]+$ || "$b" == -* ]] || ! git check-ref-format --branch "$b" >/dev/null 2>&1; then
      die "RUNNER_BRANCHES: '$b' is not a branch name"
    fi
  done
}

# Warn when RUNNER_REPO, RUNNER_NAME or RUNNER_LABELS differ from the
# registration in $1/.runner (and $1/.labels, written at registration): the
# settings only count when the runner registers, so a changed value does
# nothing until it is registered again.
runner_check_registration() {
  local dir="$1" url name labels diff=""
  url="$(jq -r '.gitHubUrl // ""' "$dir/.runner" 2>/dev/null)" || url=""
  name="$(jq -r '.agentName // ""' "$dir/.runner" 2>/dev/null)" || name=""
  labels="$(head -n1 "$dir/.labels" 2>/dev/null)" || labels=""
  [[ -z "$url" || "${url%/}" == "https://github.com/$RUNNER_REPO" ]] || diff+=", RUNNER_REPO (registered: ${url#https://github.com/})"
  [[ -z "$name" || "$name" == "$RUNNER_NAME" ]] || diff+=", RUNNER_NAME (registered: $name)"
  [[ -z "$labels" || "$labels" == "$RUNNER_LABELS" ]] || diff+=", RUNNER_LABELS (registered: $labels)"
  [[ -n "$diff" ]] || return 0
  warn "The runner is registered with other settings than these: ${diff#, }. A registered runner ignores the settings."
  warn "To register it again: cd $dir && sudo ./svc.sh stop && sudo ./svc.sh uninstall && sudo rm -f .runner .credentials .credentials_rsaparams .service .labels, then put a new token in RUNNER_TOKEN and run: sudo bash setup.sh runner"
  warn "A runner with another name or repository stays listed at GitHub; delete it there under Settings > Actions > Runners."
}

# True once svc.sh installed the runner's systemd unit: it writes the unit
# name to $1/.service and the unit file to /etc/systemd/system.
runner_service_installed() {
  local f="$1/.service" unit
  [[ -f "$f" ]] || return 1
  unit="$(head -n1 "$f")"
  [[ -n "$unit" && -f "${RPI_RUNNER_UNIT_DIR:-/etc/systemd/system}/$unit" ]]
}

# The runner release asset name for CPU $1 (uname -m), e.g. linux-arm64.
runner_platform() {
  case "$1" in
    aarch64|arm64) echo linux-arm64 ;;
    x86_64|amd64) echo linux-x64 ;;
    armv7l|armv6l|armhf) echo linux-arm ;;
    *) die "No GitHub runner build for CPU '$1'" ;;
  esac
}

# Download and unpack the newest runner release into $1, checking the
# SHA-256 that GitHub publishes for the file.
runner_download() {
  local dir="$1" plat json url digest file
  plat="$(runner_platform "$(uname -m)")"
  json="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest)" ||
    die 'Could not ask GitHub for the newest runner release; check the network and try again.'
  url="$(jq -r --arg p "$plat" '.assets[] | select(.name | test("^actions-runner-" + $p + "-[0-9.]+\\.tar\\.gz$")) | .browser_download_url' <<<"$json" | head -n1)"
  digest="$(jq -r --arg u "$url" '.assets[] | select(.browser_download_url == $u) | .digest // ""' <<<"$json")"
  [[ -n "$url" ]] || die "The newest runner release has no $plat build; see https://github.com/actions/runner/releases"
  file="$(mktemp)"
  info "Downloading $url"
  curl -fsSL -o "$file" "$url" || { rm -f "$file"; die "Download failed: $url"; }
  # The runner runs your workflows; never install one that was not checked.
  if [[ "$digest" != sha256:* ]]; then
    rm -f "$file"
    die "GitHub listed no checksum for $url, so it cannot be verified. Try again later, or unpack a release you checked yourself into $dir and re-run."
  fi
  echo "${digest#sha256:}  $file" | sha256sum -c --quiet - || { rm -f "$file"; die "Checksum mismatch for $url"; }
  tar -xzf "$file" -C "$dir"
  rm -f "$file"
  chown -R "$RPI_RUNNER_USER:$RPI_RUNNER_USER" "$dir"
}

# Print the deploy command: its fixed settings, then the deploy_run_*
# functions below (so the unit tests exercise the code the runner calls).
runner_deploy_script() {
  local dir="$1" branches="$2"
  printf '#!/usr/bin/env bash\n'
  printf '# Written by rpi-setup (tasks/runner.sh). Change the RUNNER_* settings and\n'
  printf '# re-run "sudo bash setup.sh runner" instead of editing this file.\n'
  printf '# Usage: sudo %s [--branch NAME] [--commit SHA] [--config FILE] [--tasks "a b"] [--skip "c d"] [--update]\n' "$RPI_DEPLOY_CMD"
  printf 'set -euo pipefail\n'
  printf 'DP_DIR=%q\n' "$dir"
  printf 'DP_BRANCHES=%q\n' "${branches//,/ }"
  printf 'DP_DONE_FILE=%q\n' "$RPI_SETUP_DONE_FILE"
  printf 'DP_CONFIG_DIR=/etc/rpi-setup\n'
  printf 'DP_LOG_DIR=/var/log/rpi-setup-deploy\n'
  printf 'DP_LOCK=/run/rpi-setup-deploy.lock\n'
  printf 'DP_RUNNER_USER=%q\n' "$RPI_RUNNER_USER"
  printf 'DP_SELF=%q\n' "$RPI_DEPLOY_CMD"
  declare -f deploy_run_git deploy_run_args deploy_run_refresh deploy_run_owner deploy_run_check_config \
    deploy_run_tasks deploy_run_config deploy_run_errors deploy_run
  printf 'deploy_run "$@"\n'
}

# --- Code of the deploy command (uses only DP_* variables and plain tools) ---

# The error lines ("[x] ...", what die printed) of log $1, so the workflow log
# says why a task failed. The rest of the log stays on the Pi: it can hold
# generated passwords, which no error line prints.
deploy_run_errors() {
  sed -n -e 's/\x1b\[[0-9;]*m//g' -e 's/^\[x\] \(.*\)/rpi-setup-deploy: error: \1/p' "$1" >&2
}

# git in $DP_DIR as the user who owns the checkout, so root never leaves
# root-owned files in it.
deploy_run_git() {
  local owner
  owner="$(stat -c %U "$DP_DIR")"
  if [[ "$owner" == "$(id -un)" ]]; then
    git -C "$DP_DIR" "$@"
  else
    runuser -u "$owner" -- git -C "$DP_DIR" "$@"
  fi
}

# Parse and check the arguments into DP_BRANCH, DP_COMMIT, DP_CONFIG,
# DP_TASKS, DP_SKIP and DP_UPDATE (1 with --update).
# Everything comes from a workflow, so anything unexpected stops the deploy.
# shellcheck disable=SC2153  # DP_BRANCHES is set at the top of the deploy command
deploy_run_args() {
  DP_BRANCH="${DP_BRANCHES%% *}" DP_COMMIT='' DP_CONFIG='' DP_TASKS='' DP_SKIP='' DP_UPDATE=0
  local opt words
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch|--commit|--config|--tasks|--skip)
        # As the last argument "shift 2" would fail and spin this loop forever.
        if [[ $# -lt 2 ]]; then echo "rpi-setup-deploy: $1 needs a value" >&2; return 2; fi
        case "$1" in
          --branch) DP_BRANCH="$2" ;;
          --commit) DP_COMMIT="$2" ;;
          --config) DP_CONFIG="$2" ;;
          --tasks) DP_TASKS="$2" ;;
          --skip) DP_SKIP="$2" ;;
        esac
        shift 2 ;;
      --update) DP_UPDATE=1; shift ;;
      *) echo "rpi-setup-deploy: unknown argument $(printf '%q' "$1")" >&2; return 2 ;;
    esac
  done
  case " $DP_BRANCHES " in
    *" $DP_BRANCH "*) ;;
    *) echo "rpi-setup-deploy: branch $(printf '%q' "$DP_BRANCH") is not allowed (RUNNER_BRANCHES: $DP_BRANCHES)" >&2; return 2 ;;
  esac
  # A full commit id only: a short one or a ref name could mean something
  # else after the fetch.
  if [[ -n "$DP_COMMIT" && ! "$DP_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    echo "rpi-setup-deploy: --commit must be a full 40-character commit id (got $(printf '%q' "$DP_COMMIT"))" >&2
    return 2
  fi
  DP_TASKS="${DP_TASKS//,/ }" DP_SKIP="${DP_SKIP//,/ }"
  for opt in tasks skip; do
    [[ $opt == tasks ]] && words="$DP_TASKS" || words="$DP_SKIP"
    # Printed with %q, so a tab, a CR or a control character is visible.
    if [[ ! "$words" =~ ^[a-z0-9_\ -]*$ ]]; then
      echo "rpi-setup-deploy: --$opt: task names may only use a-z, 0-9, '-' and '_' (got $(printf '%q' "$words"))" >&2
      return 2
    fi
    # A word starting with '-' would reach setup.sh as an option (--move-config).
    if [[ " $words" == *" -"* ]]; then
      echo "rpi-setup-deploy: --$opt: task names may not start with '-' (got $(printf '%q' "$words"))" >&2
      return 2
    fi
  done
  if [[ -n "$DP_CONFIG" && ! -f "$DP_CONFIG" ]]; then
    echo "rpi-setup-deploy: settings file '$DP_CONFIG' not found" >&2
    return 2
  fi
  # Called through sudo: only take a settings file the caller could read
  # itself, so the runner cannot copy other root-only files around.
  if [[ -n "$DP_CONFIG" && -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] &&
     ! runuser -u "$SUDO_USER" -- test -r "$DP_CONFIG"; then
    echo "rpi-setup-deploy: $SUDO_USER cannot read '$DP_CONFIG'" >&2
    return 2
  fi
  return 0
}

# The person who owns the Pi: the owner of the checkout. setup.sh runs with
# SUDO_USER set to them, so tasks that act on "the user" (docker group, SSH
# keys, samba share user) never pick the runner account or root.
# shellcheck disable=SC2153  # DP_RUNNER_USER is set at the top of the deploy command
deploy_run_owner() {
  local owner
  owner="$(stat -c %U "$DP_DIR")"
  if [[ "$owner" == root || "$owner" == "$DP_RUNNER_USER" ]]; then
    echo "rpi-setup-deploy: $DP_DIR is owned by $owner; it must belong to your own login user (sudo chown -R <you>: $DP_DIR)" >&2
    return 1
  fi
  printf '%s\n' "$owner"
}

# Without --config, refuse when the settings still live in the checkout:
# setup.sh reads $DP_CONFIG_DIR and would silently use every default.
deploy_run_check_config() {
  [[ -z "$DP_CONFIG" && ! -f "$DP_CONFIG_DIR/rpi-setup.env" && -f "$DP_DIR/config/rpi-setup.env" ]] || return 0
  echo "rpi-setup-deploy: your settings are in $DP_DIR/config/rpi-setup.env, but a deploy reads $DP_CONFIG_DIR/rpi-setup.env. Move them once on the Pi: cd $DP_DIR && sudo bash setup.sh --move-config (or tick the workflow's settings box / pass --config FILE)" >&2
  return 1
}

# Tasks to run: DP_TASKS, else every task that finished on this Pi. With
# --update only the DP_TASKS not yet finished on this Pi (the new ones).
# Tasks in DP_SKIP are left out. Each given or skipped task must exist as
# tasks/<name>.sh in the (updated) checkout; a recorded one that does not
# was removed from rpi-setup and is skipped.
deploy_run_tasks() {
  local -a t s
  local n recorded=0
  read -r -a t <<<"$DP_TASKS"
  read -r -a s <<<"$DP_SKIP"
  for n in "${s[@]}"; do
    if [[ ! -f "$DP_DIR/tasks/$n.sh" ]]; then
      echo "rpi-setup-deploy: unknown task '$n' to skip (no $DP_DIR/tasks/$n.sh)" >&2
      return 2
    fi
  done
  if [[ ${#t[@]} -eq 0 && $DP_UPDATE -eq 0 && -f "$DP_DONE_FILE" ]]; then
    mapfile -t t < <(grep -E '^[a-z0-9_-]+$' "$DP_DONE_FILE" || true)
    recorded=1
  fi
  for n in "${t[@]}"; do
    if [[ $recorded -eq 1 && ! -f "$DP_DIR/tasks/$n.sh" ]]; then
      echo "rpi-setup-deploy: skipping '$n', set up on this Pi before but no longer a task in $DP_DIR/tasks" >&2
      continue
    fi
    if [[ ! -f "$DP_DIR/tasks/$n.sh" ]]; then
      echo "rpi-setup-deploy: unknown task '$n' (no $DP_DIR/tasks/$n.sh)" >&2
      return 2
    fi
    if [[ " ${s[*]} " == *" $n "* ]]; then
      echo "rpi-setup-deploy: skipping '$n' (--skip)" >&2
      continue
    fi
    if [[ $DP_UPDATE -eq 1 && -f "$DP_DONE_FILE" ]] && grep -qxF "$n" "$DP_DONE_FILE"; then
      continue
    fi
    printf '%s\n' "$n"
  done
}

# This command is written by the runner task, so it would keep running the
# deploy code of the day the runner was set up. Write it again from the
# updated checkout and run the new one when it differs (once: DP_FRESH).
deploy_run_refresh() {
  local tmp
  [[ -n "${DP_SELF:-}" && -z "${DP_FRESH:-}" && -f "$DP_DIR/tasks/runner.sh" ]] || return 0
  tmp="$(mktemp)"
  if ! RPI_SETUP_DONE_FILE="$DP_DONE_FILE" bash -c 'source "$1/tasks/runner.sh" && runner_deploy_script "$1" "$2"' \
       _ "$DP_DIR" "$DP_BRANCHES" >"$tmp" || ! bash -n "$tmp"; then
    rm -f "$tmp"
    echo "rpi-setup-deploy: could not write this command from $DP_DIR/tasks/runner.sh; keeping it" >&2
    return 0
  fi
  if cmp -s "$tmp" "$DP_SELF"; then
    rm -f "$tmp"
    return 0
  fi
  install -m 0755 "$tmp" "$DP_SELF"
  rm -f "$tmp"
  echo "rpi-setup-deploy: updated $DP_SELF from the checkout; running the new one"
  return 1
}

# Install settings file $1 as $DP_CONFIG_DIR/rpi-setup.env (root only).
deploy_run_config() {
  install -m 0700 -d "$DP_CONFIG_DIR"
  install -m 0600 "$1" "$DP_CONFIG_DIR/rpi-setup.env"
  echo "rpi-setup-deploy: installed new settings in $DP_CONFIG_DIR/rpi-setup.env"
}

# One deploy. setup.sh's full output (it prints generated passwords) goes
# to a root-only log on the Pi; only the summary reaches the workflow log.
# With --update: update.sh --containers-only first (leaving out the
# containers of the DP_SKIP tasks), then setup.sh only for the new tasks.
deploy_run() {
  deploy_run_args "$@" || return $?
  local owner old new target list log stamp rc=0
  local -a tasks=() upd=(--containers-only)
  owner="$(deploy_run_owner)" || return 1
  deploy_run_check_config || return 1
  exec 9>"$DP_LOCK"
  flock -n 9 || { echo 'rpi-setup-deploy: another deploy is running' >&2; return 1; }
  deploy_run_git fetch --quiet origin "$DP_BRANCH"
  old="$(deploy_run_git rev-parse HEAD)"
  if [[ "$(deploy_run_git rev-parse --abbrev-ref HEAD)" != "$DP_BRANCH" ]]; then
    deploy_run_git checkout --quiet "$DP_BRANCH" 2>/dev/null ||
      deploy_run_git checkout --quiet -b "$DP_BRANCH" FETCH_HEAD
  fi
  # --commit: exactly that commit, which must be on the branch, such as the
  # one the private repository's submodule pins and its checks tested;
  # otherwise the branch tip. An older commit of the branch than the
  # checkout's goes back to it, as long as the checkout has no commits of
  # its own.
  target=FETCH_HEAD
  if [[ -n "$DP_COMMIT" ]]; then
    deploy_run_git merge-base --is-ancestor "$DP_COMMIT" FETCH_HEAD 2>/dev/null || {
      echo "rpi-setup-deploy: commit ${DP_COMMIT:0:7} is not on origin/$DP_BRANCH" >&2
      return 1
    }
    target="$DP_COMMIT"
  fi
  if [[ -n "$DP_COMMIT" && "$old" != "$DP_COMMIT" ]] && deploy_run_git merge-base --is-ancestor "$DP_COMMIT" HEAD; then
    { deploy_run_git merge-base --is-ancestor HEAD FETCH_HEAD && deploy_run_git reset --keep --quiet "$DP_COMMIT"; } || {
      echo "rpi-setup-deploy: cannot move $DP_DIR back to ${DP_COMMIT:0:7}; local commits or changes are in the way (git -C $DP_DIR status)" >&2
      return 1
    }
  else
    deploy_run_git merge --ff-only --quiet "$target" || {
      echo "rpi-setup-deploy: cannot fast-forward $DP_DIR to origin/$DP_BRANCH; local commits or changes are in the way (git -C $DP_DIR status)" >&2
      return 1
    }
  fi
  new="$(deploy_run_git rev-parse HEAD)"
  echo "rpi-setup-deploy: $DP_DIR on $DP_BRANCH at ${new:0:7}${DP_COMMIT:+ (pinned)} (was ${old:0:7})"
  if ! deploy_run_refresh; then
    exec 9>&-
    DP_FRESH=1 exec "$DP_SELF" "$@"
  fi
  [[ -z "$DP_CONFIG" ]] || deploy_run_config "$DP_CONFIG"
  list="$(deploy_run_tasks)" || return $?
  [[ -z "$list" ]] || mapfile -t tasks <<<"$list"
  [[ -z "${DP_SKIP// /}" ]] || upd+=(--skip "$DP_SKIP")
  install -m 0700 -d "$DP_LOG_DIR"
  stamp="$(date +%Y%m%d-%H%M%S)"
  if [[ $DP_UPDATE -eq 1 ]]; then
    log="$DP_LOG_DIR/update-$stamp.log"
    echo "rpi-setup-deploy: updating the containers (full output on the Pi: $log)"
    ( umask 077
      bash "$DP_DIR/update.sh" "${upd[@]}" </dev/null >"$log" 2>&1 ) || rc=$?
    sed -n '/^Summary:/,$p' "$log"
    [[ $rc -eq 0 ]] || deploy_run_errors "$log"
    [[ $rc -eq 0 ]] || echo "rpi-setup-deploy: update.sh failed (exit $rc); details on the Pi: sudo less $log" >&2
    if [[ ${#tasks[@]} -eq 0 ]]; then
      echo 'rpi-setup-deploy: no new tasks'
      return "$rc"
    fi
  elif [[ ${#tasks[@]} -eq 0 ]]; then
    echo 'rpi-setup-deploy: no tasks given and none recorded on this Pi; pass --tasks'
    return 0
  fi
  log="$DP_LOG_DIR/deploy-$stamp.log"
  echo "rpi-setup-deploy: running setup.sh ${tasks[*]} (full output on the Pi: $log)"
  local src=0
  ( umask 077
    SUDO_USER="$owner" SUDO_UID="$(id -u "$owner")" SUDO_GID="$(id -g "$owner")" RPI_SETUP_FROM_DEPLOY=1 \
      RPI_SETUP_CONFIG_DIR="$DP_CONFIG_DIR" bash "$DP_DIR/setup.sh" "${tasks[@]}" </dev/null >"$log" 2>&1 ) || src=$?
  sed -n '/^Summary:/,$p' "$log"
  [[ $src -eq 0 ]] || deploy_run_errors "$log"
  [[ $src -eq 0 ]] || echo "rpi-setup-deploy: setup.sh failed (exit $src); details on the Pi: sudo less $log" >&2
  [[ $src -eq 0 ]] || rc=$src
  return "$rc"
}
