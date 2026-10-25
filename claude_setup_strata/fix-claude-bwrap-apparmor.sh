#!/usr/bin/env bash
# Fix "apply-seccomp: write /proc/self/setgroups ... Permission denied" in Claude Code's
# sandboxed Bash tool on Ubuntu 24.04+.
#
# Root cause (verified on this machine, Ubuntu 26.04, apparmor 5.0.2, bubblewrap 0.11.1):
#   * kernel.apparmor_restrict_unprivileged_userns = 1  -> unconfined processes may not
#     create/map a user namespace ("unshare -Ur true" fails writing uid_map).
#   * Ubuntu therefore ships /etc/apparmor.d/bwrap-userns-restrict: profile "bwrap" gets
#     `userns`, but every process inside the sandbox is stacked against profile
#     "unpriv_bwrap", which contains `audit deny capability`.
#   * Result: bwrap cannot map uid 0 inside its namespace (children stay uid 1000 with
#     CapEff 0), and Claude Code's apply-seccomp helper needs CAP_SYS_ADMIN to set up the
#     nested namespace it uses for Unix-socket blocking -> EPERM on /proc/self/setgroups,
#     every sandboxed Bash call exits 1.
#
# Fix: give bwrap a profile that grants userns WITHOUT stripping capabilities from the
# sandboxed children (Anthropic's documented profile, flags=(unconfined)), and stop
# Ubuntu's same-named "bwrap" profile from winning (it loads later, alphabetically).
#
# Usage:
#   sudo ./fix-claude-bwrap-apparmor.sh            # swap the profile for /usr/bin/bwrap
#   sudo ./fix-claude-bwrap-apparmor.sh --scoped   # dedicated bwrap copy, keep Ubuntu's rule
#   sudo ./fix-claude-bwrap-apparmor.sh --revert   # undo whatever this script did
#   ./fix-claude-bwrap-apparmor.sh --check         # no changes: just test, exit 0 = fixed
set -euo pipefail

PROFILE_DIR=/etc/apparmor.d
UBUNTU_PROFILE="$PROFILE_DIR/bwrap-userns-restrict"
CLAUDE_PROFILE="$PROFILE_DIR/bwrap"
SCOPED_DIR=/usr/local/libexec/claude-sandbox
SCOPED_BIN="$SCOPED_DIR/bwrap"
SCOPED_PROFILE="$PROFILE_DIR/claude-bwrap"
BACKUP_DIR=/var/backups/claude-bwrap-apparmor
RUN_UID=$(id -u)
RUN_USER=$(id -un)

# The probe mirrors what Claude Code's apply-seccomp helper needs inside its sandbox: it
# unshares a nested user namespace and, as root *in that namespace*, writes setgroups and
# installs its seccomp filter. Writing setgroups in bwrap's OWN namespace is not the test -
# there uid 1000 has no CAP_SETGID on any distro, sandboxed or not.
INNER=/tmp/claude-bwrap-inner.$$.sh
OUTER=/tmp/claude-bwrap-outer.$$.sh
make_probe_scripts() {
  cat > "$INNER" <<'INNER_EOF'
#!/bin/sh
# Running at all here means the nested namespace's uid_map, setgroups and gid_map writes
# all succeeded - the exact writes apply-seccomp performs. Now confirm it is root with
# CAP_SYS_ADMIN (needed to install the seccomp filter) and CAP_SETGID.
caps=$(awk '/^CapEff/{print $2}' /proc/self/status)
if [ "$(id -u)" != 0 ]; then echo "nested_root=NO"; exit 1; fi
if [ $(( 0x$caps & 0x200008 )) -ne $(( 0x200008 )) ]; then echo "cap_sys_admin=MISSING caps=$caps"; exit 1; fi
echo "caps=$caps PROBE_OK"
INNER_EOF
  cat > "$OUTER" <<'OUTER_EOF'
#!/bin/sh
# inside the bwrap sandbox
printf "label=%s " "$(tr -d '\n' < /proc/self/attr/current)"
unshare -Ur /bin/sh INNER_SCRIPT || exit 1
OUTER_EOF
  sed -i "s#INNER_SCRIPT#$INNER#" "$OUTER"
  chmod 0755 "$INNER" "$OUTER"
}

probe() { # runs as the invoking (unprivileged) user, even under sudo
  local bin=${1:-bwrap} out rc
  make_probe_scripts
  local cmd="'$bin' --ro-bind / / --dev /dev --proc /proc -- /bin/sh '$OUTER'"
  if [ "$RUN_UID" = 0 ]; then out=$(su "$RUN_USER" -c "$cmd" 2>&1); rc=$?
  else out=$(eval "$cmd" 2>&1); rc=$?; fi
  rm -f "$INNER" "$OUTER"
  echo "  probe as $RUN_USER: $out"
  [ $rc -eq 0 ] && printf '%s\n' "$out" | grep -q PROBE_OK
}

load_profile() { # file
  local f=$1 abi
  for abi in 'abi <abi/4.0>,' 'abi <abi/5.0>,' ''; do
    if [ -n "$abi" ]; then
      # Force one abi line at the top, keeping comments and the rest of the profile intact.
      awk -v a="$abi" 'BEGIN{print a} /^abi /{next} {print}' "$f" > "$f.tmp"
    else
      cp "$f" "$f.tmp"
    fi
    if apparmor_parser -Q -p "$f.tmp" >/dev/null 2>&1; then
      mv "$f.tmp" "$f"
      apparmor_parser -r "$f"
      return 0
    fi
  done
  rm -f "$f.tmp"
  echo "ERROR: no AppArmor ABI accepted the profile $f" >&2
  return 1
}

write_profile() { # path attachment_path
  cat > "$1" <<EOF
# Added by fix-claude-bwrap-apparmor.sh - lets bubblewrap create the user namespaces
# Claude Code's sandbox needs. Children stay unconfined, so they keep the capabilities
# inside their own namespace (Ubuntu's bwrap-userns-restrict strips them and breaks
# Claude Code's apply-seccomp helper).
include <tunables/global>

profile $(basename "$1" .conf) $2 flags=(unconfined) {
  userns,
  include if exists <local/$(basename "$1" .conf)>
}
EOF
}

check_mode() {
  echo "== current state =="
  printf '  kernel.apparmor_restrict_unprivileged_userns = '
  cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 'n/a'
  printf '  host-wide unprivileged userns (outside bwrap): '
  if unshare -Ur true 2>/dev/null; then echo 'allowed'; else echo 'restricted by AppArmor (unchanged, intentional)'; fi
  printf '  Ubuntu restrict profile: '
  if [ -L "$PROFILE_DIR/disable/$(basename "$UBUNTU_PROFILE")" ]; then echo 'present but disabled'; else
    [ -e "$UBUNTU_PROFILE" ] && echo 'present and active' || echo absent; fi
  echo "  Claude profile:          $([ -e "$CLAUDE_PROFILE" ] && echo present || echo absent)"
  echo "  scoped bwrap:            $([ -x "$SCOPED_BIN" ] && echo "$SCOPED_BIN" || echo absent)"
  echo "== probe =="
  if probe; then echo "RESULT: sandbox namespace chain WORKS"; return 0
  else echo "RESULT: still broken (Claude sandboxed Bash will fail)"; return 1; fi
}

require_root() {
  [ "$RUN_UID" = 0 ] || { echo "Run with sudo: sudo $0 $*" >&2; exit 2; }
}

profile_for_path() { # attachment_path profile_file
  write_profile "$2" "$1"
  load_profile "$2"
}

mode_default() {
  require_root "$@"
  mkdir -p "$BACKUP_DIR"
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  [ -e "$UBUNTU_PROFILE" ] && cp -a "$UBUNTU_PROFILE" "$BACKUP_DIR/bwrap-userns-restrict.$ts"
  [ -e "$CLAUDE_PROFILE" ] && cp -a "$CLAUDE_PROFILE" "$BACKUP_DIR/bwrap.$ts"

  # 1. Unload Ubuntu's profile first: it declares the same profile name ("bwrap") for the
  #    same path and, being alphabetically later, would otherwise replace ours at reload.
  if [ -e "$UBUNTU_PROFILE" ]; then
    apparmor_parser -R "$UBUNTU_PROFILE" 2>/dev/null || true
    mkdir -p "$PROFILE_DIR/disable"
    ln -sfn "$UBUNTU_PROFILE" "$PROFILE_DIR/disable/$(basename "$UBUNTU_PROFILE")"
    echo "disabled $UBUNTU_PROFILE (symlink in $PROFILE_DIR/disable/)"
  fi

  # 2. Install the Anthropic-recommended profile for /usr/bin/bwrap.
  profile_for_path /usr/bin/bwrap "$CLAUDE_PROFILE"
  echo "installed $CLAUDE_PROFILE"

  systemctl reload apparmor 2>/dev/null || true
  echo "== verifying =="
  if probe; then
    echo "OK: nested user namespaces now work inside bwrap - restart Claude Code/Desktop and Bash works."
  else
    echo "NOT YET: nested namespaces still fail. Check 'sudo aa-status' (the bwrap profile must be"
    echo "loaded and unpriv_bwrap gone), or fall back to the sysctl documented at"
    echo "https://code.claude.com/docs/en/sandboxing"
    return 1
  fi
}

mode_scoped() {
  require_root "$@"
  mkdir -p "$BACKUP_DIR" "$SCOPED_DIR"
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  [ -e "$SCOPED_PROFILE" ] && cp -a "$SCOPED_PROFILE" "$BACKUP_DIR/claude-bwrap.$ts"
  install -m 0755 -o root -g root /usr/bin/bwrap "$SCOPED_BIN"
  # Ubuntu's profile is attached to the path /usr/bin/bwrap, so this copy is not covered by
  # it; the profile below grants the copy userns despite the unprivileged-userns restriction.
  profile_for_path "$SCOPED_BIN" "$SCOPED_PROFILE"

  # The point of the scoped variant is to put Ubuntu's restriction back for /usr/bin/bwrap,
  # so undo what the default mode did.
  rm -f "$PROFILE_DIR/disable/$(basename "$UBUNTU_PROFILE")"
  [ -e "$UBUNTU_PROFILE" ] && apparmor_parser -r "$UBUNTU_PROFILE" 2>/dev/null || true
  if [ -e "$CLAUDE_PROFILE" ]; then
    apparmor_parser -R "$CLAUDE_PROFILE" 2>/dev/null || true
    rm -f "$CLAUDE_PROFILE"
    echo "removed $CLAUDE_PROFILE (superseded by $SCOPED_PROFILE)"
  fi
  systemctl reload apparmor 2>/dev/null || true
  echo "installed $SCOPED_BIN + $SCOPED_PROFILE; Ubuntu's restriction is active again for /usr/bin/bwrap."
  echo
  echo "Point Claude Code at it by adding to ~/.claude/settings.json (top-level key):"
  echo "  \"sandbox\": { \"bwrapPath\": \"$SCOPED_BIN\" }"
  echo "then fully restart Claude Desktop / the CLI."
  echo
  if probe "$SCOPED_BIN"; then
    echo "OK: the scoped bwrap can create nested user namespaces."
  else
    echo "WARN: the scoped copy still cannot; re-run --check after restarting the session, or"
    echo "fall back to the default mode: sudo $0"
  fi
  echo "For reference, /usr/bin/bwrap should now fail the probe again (that is intended):"
  probe bwrap || true
}

mode_revert() {
  require_root "$@"
  rm -f "$PROFILE_DIR/disable/bwrap-userns-restrict"
  [ -e "$UBUNTU_PROFILE" ] && apparmor_parser -r "$UBUNTU_PROFILE" || true
  if [ -e "$CLAUDE_PROFILE" ]; then apparmor_parser -R "$CLAUDE_PROFILE" || true; rm -f "$CLAUDE_PROFILE"; fi
  if [ -e "$SCOPED_PROFILE" ]; then apparmor_parser -R "$SCOPED_PROFILE" || true; rm -f "$SCOPED_PROFILE"; fi
  rm -f "$SCOPED_BIN"; rmdir "$SCOPED_DIR" 2>/dev/null || true
  systemctl reload apparmor 2>/dev/null || true
  echo "reverted to Ubuntu's stock configuration. Backups in $BACKUP_DIR"
}

case "${1:-}" in
  --check)  check_mode ;;
  --scoped) mode_scoped "$@" ;;
  --revert) mode_revert "$@" ;;
  ""|--help|-h)
    if [ -z "${1:-}" ]; then mode_default "$@"; else
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    fi ;;
  *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
esac
