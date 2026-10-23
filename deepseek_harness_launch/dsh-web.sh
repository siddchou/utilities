#!/usr/bin/env bash
# Double-click or app-grid entry: toggle the DeepSeek Harness Web UI.
#
# Not running  -> start `dsh web` and open a dedicated browser window; closing
#                 that window stops the server gracefully (a watcher does it).
# Already up   -> stop: close the tracked window, then graceful SIGTERM with
#                 SIGKILL after 20s.
#
# Knobs live in ~/.config/deepseek-harness/launch.conf (see launch.conf.example):
# DSH_PORT, DSH_BROWSER, DSH_NODE, DSH_EXTRA_ARGS, DSH_READY_TIMEOUT.
# The server always starts from the repository root: a source launch runs node
# through tsx, which resolves the repo's tsconfig `paths` (source-level imports
# such as @deepseek-ai/cordis) from the process working directory; any other cwd
# falls back to built bundles that lack const-enum exports and crash at boot.
# The Web UI's "Choose workspace" picks where the agent works.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=dsh-common.sh
. "$here/dsh-common.sh"

# shellcheck source=/dev/null
[ -f "$dsh_config_file" ] && . "$dsh_config_file"
# launch.conf may point at a different checkout than the default.
dsh_repo_dir=${DSH_REPO:-$dsh_default_repo}

port=${DSH_PORT:-3080}
ready_timeout=${DSH_READY_TIMEOUT:-180}
origin="http://127.0.0.1:$port"
dsh_use_full_path

# A launch.conf from before the workspace knob was retired: say where it went.
if [ -n "${DSH_WORKSPACE:-}" ] && [ "$DSH_WORKSPACE" != "$dsh_repo_dir" ]; then
  dsh_notify 'DeepSeek Harness' "launch.conf sets DSH_WORKSPACE, which no longer changes the start directory. The server starts from $dsh_repo_dir; pick your project with Choose workspace in the Web UI."
fi

# Wait for the listening port, then print the newest authenticated URL the
# server logged (falling back to the bare origin).
# @returns 0 and prints a URL, 2 when our server died while waiting, 3 on timeout.
wait_for_url() {
  local waited=0 boot_wait=0 url='' pid_seen=0
  while [ "$waited" -lt "$((ready_timeout + 20))" ]; do
    if dsh_port_open "$port"; then
      while [ "$boot_wait" -lt 10 ] && ! url=$(dsh_last_web_url "$dsh_web_log"); do
        sleep 1
        boot_wait=$((boot_wait + 1))
      done
      printf '%s\n' "${url:-$origin}"
      return 0
    fi
    if [ -f "$dsh_web_pid_file" ]; then
      pid_seen=1
      dsh_pid_alive "$dsh_web_pid_file" || return 2
    elif [ "$waited" -ge 15 ] && [ "$pid_seen" -eq 0 ]; then
      return 2
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 3
}

# Print the tail of the server log for an error dialog.
dsh_log_tail() {
  if [ -s "$dsh_web_log" ]; then
    tail -n 15 "$dsh_web_log"
  else
    printf '(no log output at %s yet)\n' "$dsh_web_log"
  fi
}

# Open $1 in a dedicated, watchable browser window and start the watcher that
# stops the server when the window closes; falls back to the default browser
# (without auto-stop) when no trackable browser exists.
open_window() {
  local url=$1
  if dsh_launch_tracked_browser "$url"; then
    dsh_spawn_window_watcher
    return 0
  fi
  dsh_open_url "$url" || true
  dsh_notify 'DeepSeek Harness' "No trackable browser (Chrome/Chromium/Firefox) was found, so the UI opened in your default browser. Closing its window will NOT stop the server; double-click DeepSeek Harness again to stop it."
}

# Open the window for a ready server and report success.
announce_ready() {
  open_window "$1"
  dsh_notify 'DeepSeek Harness' "DeepSeek Harness is serving on $origin. Close its window (or double-click DeepSeek Harness again) to stop it."
}

# --- Toggle off: our server is up -> close the window and stop gracefully. --
if dsh_port_open "$port" && dsh_pid_alive "$dsh_web_pid_file"; then
  dsh_close_tracked_browser
  exec "$here/dsh-stop.sh"
fi

# --- A foreign server owns the port: open it, touch nothing. -----------------
if dsh_port_open "$port"; then
  dsh_notify 'DeepSeek Harness' "Port $port is already serving something else. If that is a DeepSeek Harness server you started in a terminal, open the URL it printed. To start another one here, set DSH_PORT in $dsh_config_file and double-click again."
  dsh_open_url "$origin" || true
  exit 0
fi

# --- A live pid with a closed port means the server is still booting. --------
if dsh_pid_alive "$dsh_web_pid_file"; then
  dsh_notify 'DeepSeek Harness' 'DeepSeek Harness is still starting.'
  status=0
  url=''
  url=$(wait_for_url) || status=$?
  if [ "$status" -eq 0 ]; then
    announce_ready "$url"
    exit 0
  fi
  dsh_stop_with_error 'DeepSeek Harness' "The server started earlier did not become ready on port $port. Double-click DeepSeek Harness again to stop it, then start once more. Log tail:

$(dsh_log_tail)"
  exit 1
fi

node=$(dsh_find_node) || {
  dsh_stop_with_error 'DeepSeek Harness' "Node.js was not found. Install Node.js 22.19+ or 24+, or set DSH_NODE in $dsh_config_file to the node executable."
  exit 1
}
dsh_node_supported "$node" || {
  dsh_stop_with_error 'DeepSeek Harness' "$("$node" -v 2>/dev/null || echo 'The node executable found') is too old. DeepSeek Harness needs Node.js ^22.19 || >=24; set DSH_NODE in $dsh_config_file to a newer executable."
  exit 1
}
[ -d "$dsh_repo_dir/node_modules" ] || {
  dsh_stop_with_error 'DeepSeek Harness' "Dependencies are missing. Run this in $dsh_repo_dir and then start again:

  pnpm install"
  exit 1
}
dsh_artifacts_ready "$node" || {
  dsh_stop_with_error 'DeepSeek Harness' "The built Web artifacts are not present. Double-click DeepSeek Harness (Build), or run this in $dsh_repo_dir and then start again:

  pnpm run build:artifacts"
  exit 1
}

loader=$(dsh_tsx_loader "$node") || {
  dsh_stop_with_error 'DeepSeek Harness' "The tsx loader is missing from $dsh_repo_dir/node_modules. Run this in $dsh_repo_dir and then start again:

  pnpm install"
  exit 1
}

umask 077
mkdir -p "$dsh_state_dir"
chmod 700 "$dsh_state_dir"
# The log holds the Web launch token, so it stays owner-only and bounded in size.
if [ -f "$dsh_web_log" ] && [ "$(stat -c %s "$dsh_web_log" 2>/dev/null || echo 0)" -gt 2097152 ]; then
  tail -c 262144 "$dsh_web_log" >"$dsh_web_log.tmp" && mv -f "$dsh_web_log.tmp" "$dsh_web_log"
fi
touch "$dsh_web_log"
chmod 600 "$dsh_web_log"

printf '\n===== %s  launch: %s web --port %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" \
  "$node" "$port" >>"$dsh_web_log"

# New session, so the server outlives this launcher. The recorded pid is the
# server process itself: the inner bash execs node after writing its own pid.
setsid bash -c '
  pid_file=$1; shift
  log_file=$1; shift
  repo_dir=$1; shift
  printf "%s\n" "$$" >"$pid_file"
  chmod 600 "$pid_file"
  cd "$repo_dir" || exit 1
  exec "$@" >>"$log_file" 2>&1 </dev/null
' _ "$dsh_web_pid_file" "$dsh_web_log" "$dsh_repo_dir" \
  "$node" --import "$loader" "$dsh_repo_dir/apps/cli/src/bin.ts" web --port "$port" --no-open ${DSH_EXTRA_ARGS:-} &

status=0
url=''
url=$(wait_for_url) || status=$?
case $status in
0)
  announce_ready "$url"
  ;;
2)
  dsh_stop_with_error 'DeepSeek Harness' "The server exited during startup. Log tail:

$(dsh_log_tail)"
  exit 1
  ;;
*)
  dsh_stop_with_error 'DeepSeek Harness' "The server did not start within ${ready_timeout}s. Check the log, then double-click DeepSeek Harness again to stop and retry:

$(dsh_log_tail)"
  exit 1
  ;;
esac
