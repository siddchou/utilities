#!/usr/bin/env bash
# Register this folder's launchers in the GNOME Applications menu, or unregister
# them with --uninstall. Double-clicking the .desktop files in this folder works
# without this step once Files is allowed to launch them; registering adds them
# to the app grid and global search.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
default_repo=/home/schou08/Applications/deepseek-harness
apps_dir=${XDG_DATA_HOME:-$HOME/.local/share}/applications
config_file=${XDG_CONFIG_HOME:-$HOME/.config}/deepseek-harness/launch.conf
# The merged start/stop toggle and the build entry. dsh-stop.sh stays in this
# folder for terminal use (and is what the window watcher runs), but it is no
# longer a menu entry.
entries=(
  deepseek-harness.desktop
  deepseek-harness-build.desktop
)
executables=(
  dsh-web.sh
  dsh-stop.sh
  dsh-build.sh
  install-desktop-entry.sh
)

# shellcheck source=/dev/null
[ -f "$config_file" ] && . "$config_file"

# Remove a registration this folder created, leaving a foreign file of the same
# name untouched.
# @param $1 - path inside the applications directory.
remove_entry() {
  local target=$1 current
  [ -L "$target" ] || return 0
  current=$(readlink -f -- "$target")
  if [ "$current" = "$here/$(basename -- "$target")" ]; then
    rm -f -- "$target"
  fi
  return 0
}

if [ "${1:-}" = '--uninstall' ]; then
  for entry in "${entries[@]}"; do
    remove_entry "$apps_dir/$entry"
    gio set -- "$here/$entry" metadata::trusted false >/dev/null 2>&1 || true
  done
  # The merged toggle replaced the separate Stop entry; drop a stale one.
  [ -L "$apps_dir/deepseek-harness-stop.desktop" ] && rm -f -- "$apps_dir/deepseek-harness-stop.desktop"
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$apps_dir" >/dev/null 2>&1 || true
  fi
  echo "Removed the DeepSeek Harness entries from $apps_dir."
  echo "The launcher files stay in $here."
  exit 0
fi

if [ "$#" -ne 0 ]; then
  echo "usage: $(basename -- "$0") [--uninstall]" >&2
  exit 2
fi

for file in "${executables[@]}" "${entries[@]}"; do
  chmod +x -- "$here/$file"
done

if command -v desktop-file-validate >/dev/null 2>&1; then
  for entry in "${entries[@]}"; do
    desktop-file-validate -- "$here/$entry" ||
      echo "warning: $entry has desktop-file-validate findings above." >&2
  done
fi

mkdir -p "$apps_dir"
for entry in "${entries[@]}"; do
  remove_entry "$apps_dir/$entry"
  ln -sfn -- "$here/$entry" "$apps_dir/$entry"
done
# The merged toggle replaced the separate Stop entry; drop a stale registration
# (symlinks only, so a foreign file of that name is left alone).
[ -L "$apps_dir/deepseek-harness-stop.desktop" ] && rm -f -- "$apps_dir/deepseek-harness-stop.desktop"
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$apps_dir" >/dev/null 2>&1 || true
fi

# Files needs a trusted flag before it will launch a desktop file by double-click.
trusted=1
for entry in "${entries[@]}"; do
  gio set -- "$here/$entry" metadata::trusted true >/dev/null 2>&1 || trusted=0
done

printf 'Registered in the Applications menu:\n'
for entry in "${entries[@]}"; do
  printf '  %s\n' "$entry"
done
printf '  applications directory: %s\n' "$apps_dir"
printf '  launcher folder:        %s\n' "$here"
printf '  start directory:        %s (source launch; pick your project with Choose workspace in the Web UI)\n' \
  "${DSH_REPO:-$default_repo}"
if [ "$trusted" -eq 1 ]; then
  printf 'Double-click in Files is enabled. In the app grid, search for "DeepSeek Harness".\n'
else
  printf 'Could not set the launch-trust flag from here. In Files, right-click each\n' \
    'desktop file once and choose "Allow Launching"; the app grid entries work either way.\n'
fi
