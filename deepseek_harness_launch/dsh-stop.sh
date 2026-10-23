#!/usr/bin/env bash
# Double-click or app-grid entry: stop the DeepSeek Harness Web server that this
# folder's launcher started, with a graceful shutdown.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=dsh-common.sh
. "$here/dsh-common.sh"

# shellcheck source=/dev/null
[ -f "$dsh_config_file" ] && . "$dsh_config_file"
# launch.conf may point at a different checkout than the default.
dsh_repo_dir=${DSH_REPO:-$dsh_default_repo}

port=${DSH_PORT:-3080}

# Ask a process to exit, escalating to SIGKILL after the grace period.
# @param $1 - pid.
# @returns 0 once the process is gone.
dsh_terminate() {
  local pid=$1 waited=0
  kill -TERM "$pid" 2>/dev/null || return 0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 20 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  kill -0 "$pid" 2>/dev/null || return 0
  kill -KILL "$pid" 2>/dev/null || true
  sleep 1
  ! kill -0 "$pid" 2>/dev/null
}

if ! dsh_pid_alive "$dsh_web_pid_file"; then
  rm -f "$dsh_web_pid_file"
  # A server started from a terminal in this checkout has no pid file here.
  leftovers=$(pgrep -f "$dsh_repo_dir/apps/cli/src/bin.ts.*web" 2>/dev/null || true)
  if [ -z "$leftovers" ]; then
    dsh_notify 'DeepSeek Harness' "No DeepSeek Harness server was started by this folder's launcher, and nothing else in this checkout is running. Port $port is untouched if something else owns it."
    exit 0
  fi
  stopped=''
  for pid in $leftovers; do
    dsh_terminate "$pid" && stopped="$stopped $pid"
  done
  dsh_notify 'DeepSeek Harness' "Stopped the DeepSeek Harness server process(es) started from this checkout:${stopped:- none survived}. A terminal that still shows a running server can be closed."
  exit 0
fi

pid=$(cat "$dsh_web_pid_file")
if dsh_terminate "$pid"; then
  rm -f "$dsh_web_pid_file"
  dsh_notify 'DeepSeek Harness' "DeepSeek Harness stopped (process $pid). Double-click DeepSeek Harness to start it again."
  exit 0
fi
rm -f "$dsh_web_pid_file"
dsh_stop_with_error 'DeepSeek Harness' "Process $pid did not exit after a forced kill. Check whether a supervisor restarted it: ps -p $pid"
exit 1
