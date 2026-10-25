#!/usr/bin/env bash
# One-shot diagnostic: which AppArmor knob is still denying the uid_map / setgroups writes
# that Claude Code's apply-seccomp helper needs inside its bwrap sandbox?
#
# Reversible: unloads/loads AppArmor profiles and flips the unprivileged-userns sysctl,
# restoring both sysctl values and the profile set on exit. Nothing persistent changes.
#
#   sudo ./diag-bwrap-apparmor.sh      # paste the whole output back
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SUDO_USER=${SUDO_USER:-$(id -un)}
A=kernel.apparmor_restrict_unprivileged_userns
B=kernel.apparmor_restrict_unprivileged_unconfined
RESTRICT=/etc/apparmor.d/bwrap-userns-restrict
OURS=/etc/apparmor.d/bwrap
ORIG_A=$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)
ORIG_B=$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_unconfined 2>/dev/null)

cleanup() {
  echo; echo "== restore =="
  [ -n "$ORIG_A" ] && sysctl -qw "$A=$ORIG_A" 2>/dev/null
  [ -n "$ORIG_B" ] && sysctl -qw "$B=$ORIG_B" 2>/dev/null
  apparmor_parser -r "$RESTRICT" 2>/dev/null && echo "reloaded $(basename "$RESTRICT")"
  [ -f "$OURS" ] && apparmor_parser -r "$OURS" 2>/dev/null && echo "reloaded $(basename "$OURS")"
  echo "sysctl $A=$ORIG_A  $B=$ORIG_B (restored to values found at start)"
}
trap cleanup EXIT

probe() { # label for this scenario; runs the failing operation as the normal user
  local out
  # Reuse the single probe implementation shipped with the fix script (checks the nested
  # namespace, where the seccomp helper actually runs - not bwrap's own namespace).
  out=$(su "$SUDO_USER" -c "'$HERE/fix-claude-bwrap-apparmor.sh' --check" 2>&1 | sed -n 's/^  probe as .*: //p')
  printf '%-42s %s\n' "$1" "${out:-no output}"
}

[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 2; }

echo "== files =="
ls -l "$OURS" 2>&1
ls -l "$RESTRICT" 2>&1
echo "disable/ dir: $(ls -l /etc/apparmor.d/disable/ 2>&1 | tail -n +2 | tr '\n' ' ')"
echo "cached: $(ls /var/cache/apparmor/*/ 2>/dev/null | grep -i bwrap | tr '\n' ' ')"

echo; echo "== loaded profiles mentioning bwrap =="
if [ -r /sys/kernel/security/apparmor/profiles ]; then
  grep -iE 'bwrap|unpriv' /sys/kernel/security/apparmor/profiles || echo "(no bwrap profiles loaded)"
else
  echo "(profiles list not readable: $(ls -l /sys/kernel/security/apparmor/profiles 2>&1))"
fi

echo; echo "== parser verdicts =="
echo "-- our profile ($OURS):"; apparmor_parser -V -p "$OURS" 2>&1 | tail -3
echo "-- ubuntu profile ($RESTRICT):"; apparmor_parser -V -p "$RESTRICT" 2>&1 | tail -3

echo; echo "== sysctls =="
sysctl "$A" "$B" 2>&1

echo; echo "== probes =="
probe "1. as loaded now"
apparmor_parser -R "$RESTRICT" 2>/dev/null
probe "2. ubuntu restrict unloaded"
[ -f "$OURS" ] && apparmor_parser -r "$OURS" 2>/dev/null
probe "3. + our profile loaded"
sysctl -qw "$A=0" 2>/dev/null
probe "4. + $A=0"
sysctl -qw "$B=0" 2>/dev/null
probe "5. + $B=0"
echo
echo "Read the FIRST scenario whose PROBE_OK line appears:"
echo "  2 works   -> Ubuntu's unpriv_bwrap capability denial was the blocker; keep the restrict"
echo "               profile disabled (or scoped variant) and you are done."
echo "  4 works   -> the unprivileged-userns sysctl is the blocker, not the profile."
echo "  5 works   -> the unconfined-restriction sysctl is the blocker."
echo "  none     -> something else strips caps (see 'label=' and 'caps=' columns above)."
