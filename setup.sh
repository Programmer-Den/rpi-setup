#!/usr/bin/env bash
# rpi-setup - easy way to provision a Raspberry Pi for different tasks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

declare -a TASKS=()
for f in "$SCRIPT_DIR"/tasks/*.sh; do
  . "$f"
done

[[ ${#TASKS[@]} -gt 0 ]] || die 'No tasks found under tasks/'

task_name() { printf '%s' "${1%%|*}"; }
task_desc() { printf '%s' "${1#*|}"; }

print_tasks() {
  local i=1 e
  for e in "${TASKS[@]}"; do
    printf '  %3d) %-14s %s\n' "$i" "$(task_name "$e")" "$(task_desc "$e")"
    i=$((i + 1))
  done
}

# Description of the task named $1; dies if there is no such task.
task_desc_of() {
  local entry
  for entry in "${TASKS[@]}"; do
    if [[ "$(task_name "$entry")" == "$1" ]]; then task_desc "$entry"; return 0; fi
  done
  die "unknown task: $1"
}

# Tasks the menu's "all" leaves out: apps, runner and gateway stop without their
# required settings, and network changes the Pi's address (and ends an SSH
# session). Pick them by number.
NOT_IN_ALL=' apps runner gateway network '

# Read the menu answer and print the names of the tasks picked by number.
prompt_selection() {
  local line p name all=0
  printf '> ' >&2
  IFS= read -r line
  line="${line//,/ }"
  if [[ "$line" == "all" ]]; then all=1; line="$(seq 1 ${#TASKS[@]})"; fi
  # Use if/then rather than '[[ ]] && echo': a trailing non-numeric token would
  # otherwise make the function return 1, and 'picked=($(prompt_selection))' in
  # main() would then abort the script under 'set -e' instead of cancelling.
  for p in $line; do
    if [[ "$p" =~ ^[0-9]+$ ]] && (( 10#$p >= 1 && 10#$p <= ${#TASKS[@]} )); then
      name="$(task_name "${TASKS[10#$p - 1]}")"
      if [[ $all -eq 1 && "$NOT_IN_ALL" == *" $name "* ]]; then continue; fi
      echo "$name"
    fi
  done
  return 0
}

# Set PLAN, the order tasks $@ run in: base first if picked, firewall last
# if picked (it opens the ports of what is installed when it runs), the
# others in the order given, repeats dropped.
declare -a PLAN=()
plan_tasks() {
  local -A seen=()
  local name
  PLAN=()
  if [[ " $* " == *" base "* ]]; then set -- base "$@"; fi
  for name in "$@"; do
    [[ "$name" != firewall ]] || continue
    [[ -z "${seen[$name]+x}" ]] || continue
    seen[$name]=1
    PLAN+=("$name")
  done
  if [[ " $* " == *" firewall "* ]]; then PLAN+=(firewall); fi
}

# Parse the settings file of every selected task before running any, so a typo
# in the last task's file stops the run before the first task changes anything.
check_task_configs() {
  local name
  for name in "$@"; do
    ( load_task_config "$name" ) >/dev/null
  done
}

# Run tasks by name. Each runs in a subshell, so a failing command or 'die'
# ends only that task; the run goes on and TASK_RESULT records ok, failed or
# skipped. RUN_FAILED becomes 1 if a task failed. Call it plainly, never in a
# condition such as "run_tasks ||": bash would then ignore errexit inside
# every task.
declare -A TASK_RESULT=()
RUN_FAILED=0
run_tasks() {
  local name rc
  TASK_RESULT=()
  RUN_FAILED=0
  for name in "$@"; do
    hr
    if [[ "$(type -t "run_${name}")" != "function" ]]; then
      warn "No handler for task '$name', skipping."
      TASK_RESULT[$name]='skipped (no handler)'
      continue
    fi
    echo "Task $name: $(task_desc_of "$name")"
    # Not "if ( ... )" or "( ... ) || ...": bash ignores errexit inside a
    # condition, which would let a failing command in a task go unnoticed.
    set +e
    ( set -e; load_task_config "$name"; "run_${name}" )
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      TASK_RESULT[$name]=ok
      record_task_done "$name"
      say "Complete: $name"
    else
      TASK_RESULT[$name]=failed
      warn "Task $name failed (exit code $rc); going on with the next task."
      RUN_FAILED=1
    fi
  done
}

# Remember that task $1 finished on this Pi, so the runner task's deploy
# reruns it (RPI_SETUP_DONE_FILE: see tasks/runner.sh), and forget tasks
# that were removed from tasks/. Best effort: a read-only state folder never
# fails a run.
record_task_done() {
  local f="$RPI_SETUP_DONE_FILE" n
  {
    mkdir -p "$(dirname "$f")" &&
      { cat "$f" 2>/dev/null || true; printf '%s\n' "$1"; } | sort -u |
      while IFS= read -r n; do
        [[ ! -f "$RPI_SETUP_ROOT/tasks/$n.sh" ]] || printf '%s\n' "$n"
      done >"$f.tmp" &&
      mv -f "$f.tmp" "$f"
  } 2>/dev/null || true
}

# The results table, reboot hint and log location printed at the end of a run.
print_summary() {
  local name
  hr
  echo 'Summary:'
  for name in "$@"; do
    printf '  %-14s %s\n' "$name" "${TASK_RESULT[$name]:-not run}"
  done
  if [[ -f "${RPI_SETUP_REBOOT_FILE:-/run/reboot-required}" ]] ||
     { [[ "${TASK_RESULT[base]:-}" == ok || "${TASK_RESULT[base]:-}" == failed ]] && is_pi; }; then
    info 'Reboot recommended: sudo reboot'
  fi
  if [[ -n "${RPI_SETUP_LOG_ACTIVE:-}" ]]; then
    info "Full log of this run: $RPI_SETUP_LOG_ACTIVE"
  fi
}

# Copy everything this run prints (stdout and stderr) to the log file. It is
# kept private because tasks print generated passwords. stdin is left alone,
# so prompts and '[[ -t 0 ]]' checks in tasks work as before.
RPI_SETUP_LOG="${RPI_SETUP_LOG:-/var/log/rpi-setup.log}"
RPI_SETUP_LOG_ACTIVE=''
_LOG_PID=''
_LOG_OUT=''
_LOG_ERR=''
start_log() {
  local log="$RPI_SETUP_LOG"
  if ! ( umask 077; touch "$log" && chmod 600 "$log" ) 2>/dev/null; then
    warn "Cannot write $log; this run is not logged."
    return 0
  fi
  printf '\n===== rpi-setup run %s: %s =====\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >>"$log"
  exec {_LOG_OUT}>&1 {_LOG_ERR}>&2
  exec > >(tee -a "$log") 2>&1
  _LOG_PID=$!
  RPI_SETUP_LOG_ACTIVE="$log"
  trap stop_log EXIT
}

# Restore the terminal and give tee a moment to write the last lines. The
# wait is bounded: a daemon a task started may still hold the pipe open.
stop_log() {
  [[ -n "$RPI_SETUP_LOG_ACTIVE" ]] || return 0
  exec 1>&"$_LOG_OUT" 2>&"$_LOG_ERR"
  exec {_LOG_OUT}>&- {_LOG_ERR}>&-
  RPI_SETUP_LOG_ACTIVE=''
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$_LOG_PID" 2>/dev/null || break
    sleep 0.2
  done
}

usage() {
  cat <<EOF
Usage: sudo bash setup.sh [task ...]   run tasks (no task: interactive menu)
       bash setup.sh --list            list the tasks
       bash setup.sh --init-config     create config/rpi-setup.env from the example
       bash setup.sh --split-config    split config/rpi-setup.env into config/local/<task>.env
       sudo bash setup.sh --move-config  move config/rpi-setup.env to $(system_config_dir) (root only)
Put your settings in $(central_config); setup.sh splits it into one
file per task before it runs any task. Settings are read from
$(system_config_dir)/rpi-setup.env when that file exists, so they can
live outside the git checkout.
EOF
}

main() {
  case "${1:-}" in
    --list)
      print_tasks
      return 0
      ;;
    --init-config)
      init_config
      return 0
      ;;
    --split-config)
      split_config "$(central_config)"
      return 0
      ;;
    --move-config)
      need_root
      move_config
      return 0
      ;;
    -h|--help)
      usage
      return 0
      ;;
    -*)
      usage >&2
      die "unknown option: $1"
      ;;
  esac

  need_root

  if ! is_pi; then
    warn 'This does not appear to be a Raspberry Pi. Some tasks may not work correctly.'
  fi

  local -a picked=()
  local n
  if [[ $# -gt 0 ]]; then
    for n in "$@"; do task_desc_of "$n" >/dev/null; done
    picked=("$@")
  else
    echo "rpi-setup - easy Raspberry Pi provisioning"
    echo
    echo 'Available tasks:'
    print_tasks
    echo
    echo 'Enter task numbers (comma/space separated), or nothing to quit.'
    echo '"all" picks every task except apps, runner, gateway and network; firewall runs last:'
    picked=($(prompt_selection))
    if [[ ${#picked[@]} -eq 0 ]]; then
      echo 'Cancelled.'
      return 0
    fi
  fi
  start_log "${picked[*]}"
  plan_tasks "${picked[@]}"
  warn_shadowed_config
  if [[ -f "$(central_config)" ]]; then
    split_config "$(central_config)"
  else
    ignore_stale_local_config
  fi
  check_task_configs "${PLAN[@]}"
  run_tasks "${PLAN[@]}"
  print_summary "${PLAN[@]}"
  if [[ $RUN_FAILED -ne 0 ]]; then
    warn 'Some tasks did not finish; the lines above say why.'
  else
    say 'All selected tasks finished.'
  fi
  return "$RUN_FAILED"
}

# Only run when executed directly; ci/test-setup.sh sources this file to test
# the functions above without running any task.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi