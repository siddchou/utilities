#!/usr/bin/env bash
# Double-click or app-grid entry: build the Web artifacts that this folder's
# launcher serves (`pnpm run build:artifacts`). Pass --full for the complete
# repository build (`pnpm run build`, which also typechecks the aggregate).
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=dsh-common.sh
. "$here/dsh-common.sh"

# shellcheck source=/dev/null
[ -f "$dsh_config_file" ] && . "$dsh_config_file"
# launch.conf may point at a different checkout than the default.
dsh_repo_dir=${DSH_REPO:-$dsh_default_repo}

target=build:artifacts
[ "${1:-}" = '--full' ] && target=build
dsh_use_full_path

node=$(dsh_find_node) || {
  dsh_stop_with_error 'DeepSeek Harness' 'Node.js was not found. Install Node.js 22.19+ or 24+ before building.'
  exit 1
}
dsh_node_supported "$node" || {
  dsh_stop_with_error 'DeepSeek Harness' "$("$node" -v 2>/dev/null || echo 'The node executable found') is too old. Building needs Node.js ^22.19 || >=24."
  exit 1
}
pnpm=$(command -v pnpm || true)
[ -n "$pnpm" ] || {
  dsh_stop_with_error 'DeepSeek Harness' "pnpm was not found. Install it (npm install -g pnpm@12, or corepack enable) and double-click again."
  exit 1
}

umask 077
mkdir -p "$dsh_state_dir"
chmod 700 "$dsh_state_dir"
touch "$dsh_build_log"
chmod 600 "$dsh_build_log"

if dsh_pid_alive "$dsh_web_pid_file" && command -v zenity >/dev/null 2>&1; then
  if ! zenity --question --title='DeepSeek Harness build' --width=520 --text='The Web UI server is running. A rebuild replaces the files it serves, so restart it with DeepSeek Harness (Stop) and then start it again when the build finishes.

Build now?'; then
    exit 0
  fi
fi

printf '\n===== %s  build: %s run %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$pnpm" "$target" >>"$dsh_build_log"
dsh_notify 'DeepSeek Harness' "Building DeepSeek Harness ($target). Progress: $dsh_build_log"

dialog=''
if command -v zenity >/dev/null 2>&1; then
  zenity --progress --pulsate --no-cancel --title='DeepSeek Harness build' \
    --text="Building DeepSeek Harness ($target)…
This can take several minutes.
Log: $dsh_build_log" >/dev/null 2>&1 &
  dialog=$!
fi

status=0
(cd -- "$dsh_repo_dir" && "$pnpm" run "$target" >>"$dsh_build_log" 2>&1) || status=$?

if [ -n "$dialog" ]; then
  kill "$dialog" 2>/dev/null || true
  wait "$dialog" 2>/dev/null || true
fi

if [ "$status" -eq 0 ]; then
  dsh_notify 'DeepSeek Harness' "Build finished. Double-click DeepSeek Harness to open the Web UI; restart a running server first with DeepSeek Harness (Stop)."
  exit 0
fi

dsh_stop_with_error 'DeepSeek Harness' "Build failed (exit $status). Last log lines:

$(tail -n 20 "$dsh_build_log" 2>/dev/null || echo "(no log at $dsh_build_log)")

Full log: $dsh_build_log"
exit "$status"
