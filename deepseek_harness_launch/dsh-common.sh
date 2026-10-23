# shellcheck shell=bash
# Shared setup for the double-click launchers: repository paths, Node discovery,
# built-artifact checks, loopback port probe, and desktop messages.
# Sourced by dsh-web.sh, dsh-stop.sh, and dsh-build.sh; not run on its own.

dsh_launcher_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# This utility lives outside the harness checkout, so the checkout path is a
# setting (DSH_REPO in launch.conf), not derived from this folder. The scripts
# re-derive dsh_repo_dir after sourcing their config; this default covers the
# gap between sourcing and that point.
dsh_default_repo=/home/schou08/Applications/deepseek-harness
dsh_repo_dir=$dsh_default_repo
dsh_state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/deepseek-harness-launcher
dsh_config_file=${XDG_CONFIG_HOME:-$HOME/.config}/deepseek-harness/launch.conf
dsh_web_log=$dsh_state_dir/web.log
dsh_web_pid_file=$dsh_state_dir/web.pid
dsh_build_log=$dsh_state_dir/build.log
dsh_icon_file=$dsh_repo_dir/apps/desktop/resources/icon.svg

# Show a desktop notification; a missing notifier is not a launcher failure.
# @param $1 - notification title.
# @param $2 - notification body.
dsh_notify() {
  command -v notify-send >/dev/null 2>&1 &&
    notify-send --app-name='DeepSeek Harness' -- "$1" "$2" >/dev/null 2>&1
  return 0
}

# Report a launcher that cannot continue: stderr always, a dialog when zenity exists.
# @param $1 - dialog title.
# @param $2 - dialog body, with the command the user should run.
dsh_stop_with_error() {
  printf '%s: %s\n' "$1" "$2" >&2
  if command -v zenity >/dev/null 2>&1; then
    zenity --error --title="$1" --width=520 --text="$1

$2" >/dev/null 2>&1
    return 0
  fi
  dsh_notify "$1" "$2"
}

# Add the Node and pnpm install locations a desktop launch may miss. A
# GNOME-launched process inherits a minimal PATH, and pnpm scripts resolve
# `node` through it, so the launchers export the extended PATH before running
# anything.
dsh_use_full_path() {
  local dir prefix=''
  for dir in "$dsh_repo_dir/node_modules/.bin" "$HOME/.local/bin" "$HOME/opt/nodejs/bin" \
    "$HOME/.volta/bin" "$HOME/.npm-global/bin" /usr/local/bin /usr/bin; do
    [ -d "$dir" ] && prefix="$prefix${prefix:+:}$dir"
  done
  PATH="${prefix:+$prefix:}$PATH"
  export PATH
}

# Print the first node executable that satisfies the engines range, honouring
# $DSH_NODE. Call dsh_use_full_path first.
# @returns 0 and prints the executable path, or 1 when none was found.
dsh_find_node() {
  if [ -n "${DSH_NODE:-}" ] && [ -x "${DSH_NODE:-}" ]; then
    printf '%s\n' "$DSH_NODE"
    return 0
  fi
  local candidate
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if dsh_node_supported "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(type -aP node || true)
  return 1
}

# Whether a node executable satisfies the repository's engines range
# `^22.19.0 || >=24.0.0`.
# @param $1 - node executable to query.
# @returns 0 when the version is supported.
dsh_node_supported() {
  "$1" -e 'const [major, minor] = process.versions.node.split(".").map(Number);
process.exit(major >= 24 || (major === 22 && minor >= 19) ? 0 : 1)' >/dev/null 2>&1
}

# Whether the repository has the installed workspace and the built Web artifacts
# that `dsh web` serves.
# @param $1 - node executable used for the check.
# @returns 0 when a launch can serve the built Web UI.
dsh_artifacts_ready() {
  [ -d "$dsh_repo_dir/node_modules" ] &&
    [ -f "$dsh_repo_dir/apps/cli/src/bin.ts" ] &&
    [ -f "$dsh_repo_dir/apps/web/dist/index.html" ] &&
    [ -f "$dsh_repo_dir/.dsh-build/client-build-environment.json" ] &&
    dsh_tsx_loader "$1" >/dev/null
}

# Resolve the tsx ESM loader that the source launcher imports, as a `file://` URL.
# The server runs with the workspace as its working directory, so a bare
# `tsx/esm` specifier would not resolve from there.
# @param $1 - node executable used for the resolution.
# @returns 0 and prints the loader URL, or 1 when tsx is absent.
dsh_tsx_loader() {
  local resolved
  resolved=$(cd -- "$dsh_repo_dir" &&
    "$1" -e 'console.log(require.resolve("tsx/esm"))' 2>/dev/null) || return 1
  [ -n "$resolved" ] && [ -f "$resolved" ] || return 1
  "$1" -e 'console.log(require("node:url").pathToFileURL(process.argv[1]).href)' "$resolved"
}

# Whether the loopback Web port already accepts connections.
# @param $1 - TCP port.
# @returns 0 when something is listening.
dsh_port_open() {
  timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" >/dev/null 2>&1
}

# Print the most recent authenticated Web URL a launcher-started server logged.
# Opening that URL is what passes the browser-trust fence; a bare origin only
# works while the signed cookie from an earlier visit is still valid.
# @param $1 - log file written by the server.
# @returns 0 and prints the URL, or 1 when the log has none.
dsh_last_web_url() {
  local line
  [ -f "$1" ] || return 1
  line=$(grep -oE '^dsh web: https?://[^[:space:]]+' "$1" 2>/dev/null | tail -n 1) || return 1
  [ -n "$line" ] || return 1
  printf '%s\n' "${line#'dsh web: '}"
}

# Open a URL in the default browser without blocking the launcher.
# @param $1 - absolute http(s) URL.
dsh_open_url() {
  command -v xdg-open >/dev/null 2>&1 || return 1
  setsid xdg-open "$1" >/dev/null 2>&1 &
  return 0
}

# Whether the recorded server process is still alive.
# @param $1 - pid file.
# @returns 0 when it holds a live pid.
dsh_pid_alive() {
  local pid
  [ -f "$1" ] || return 1
  pid=$(cat "$1" 2>/dev/null) || return 1
  case $pid in ('' | *[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}
