#!/usr/bin/env bash
#
# enable-lms-unload.sh — run 'lms unload --all' on every shutdown/reboot
#
# Target system : Ubuntu 26.04 LTS, kernel 7.x-generic, NVIDIA open driver 595,
#                 dual RTX 3090 (same box as fix-poweroff.sh)
# Why:           An active CUDA context at poweroff is suspected of causing the
#                "black screen but stays on" incomplete-shutdown issue. Unloading
#                all LM Studio models before driver/ACPI teardown keeps the GPUs clean.
#
# What it does:
#   [1/3] Installs /usr/local/bin/lms-unload-shutdown.sh
#         -> runs 'lms unload --all' as user schou08, logs to /var/log/lms-unload.log,
#            never blocks or fails the shutdown sequence
#   [2/3] Installs + enables lms-unload.service
#         -> runs during shutdown AND reboot, before filesystems unmount and
#            before the user session (LM Studio server) is stopped
#   [3/3] Prints next steps
#
# Usage:      sudo bash enable-lms-unload.sh
# Safe to re-run. Takes effect at the NEXT shutdown — no reboot needed.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: run as root ->  sudo bash $0" >&2
    exit 1
fi

LMS_USER=schou08
HOOK_BIN=/usr/local/bin/lms-unload-shutdown.sh
UNIT_FILE=/etc/systemd/system/lms-unload.service
LOG_FILE=/var/log/lms-unload.log

if ! getent passwd "$LMS_USER" >/dev/null; then
    echo "ERROR: user '$LMS_USER' does not exist." >&2
    exit 1
fi
LMS_UID=$(id -u "$LMS_USER")

# ------------------------------------------------- [1/3] shutdown hook script
echo "==> [1/3] Installing $HOOK_BIN ..."
cat > "$HOOK_BIN" <<'EOF'
#!/bin/bash
# lms-unload-shutdown.sh — runs during system shutdown/reboot (lms-unload.service).
# Unloads all LM Studio models so no active CUDA context remains when the machine
# powers off. Helps with the "black screen but stays on" incomplete poweroff issue.
set -u

LMS_USER=schou08
HOME_DIR=/home/schou08
LMS_BIN="$HOME_DIR/.lmstudio/bin/lms"
LOG=/var/log/lms-unload.log
TIMEOUT=25

{
    echo "=== $(date -Is) lms unload (shutdown hook) ==="
    if [[ ! -x $LMS_BIN ]]; then
        echo "lms not found at $LMS_BIN — skipping."
    else
        # Run as the LM Studio user so its config/auth is used.
        rc=0
        timeout "$TIMEOUT" runuser -u "$LMS_USER" -- env HOME="$HOME_DIR" \
            "$LMS_BIN" unload --all || rc=$?
        if [[ $rc -eq 0 ]]; then
            echo "unload OK — sleeping 5s so GPU memory is fully released before driver teardown."
            sleep 5
        elif [[ $rc -eq 124 ]]; then
            echo "WARN: lms unload timed out after ${TIMEOUT}s"
        else
            echo "lms unload exited $rc (LM Studio server probably not running — fine)."
        fi
    fi
} >> "$LOG" 2>&1

# Never block or fail the shutdown sequence.
exit 0
EOF
chmod +x "$HOOK_BIN"

# ------------------------------------------------- [2/3] systemd unit
echo "==> [2/3] Installing $UNIT_FILE ..."
if [[ -f $UNIT_FILE ]]; then
    cp -a "$UNIT_FILE" "${UNIT_FILE}.bak-$(date +%Y%m%d-%H%M%S)"
    echo "    Backed up existing unit."
fi

# Before=user@<uid>.service guarantees the hook runs while the user session —
# and therefore the LM Studio server — is still alive.
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Unload LM Studio models from GPU before poweroff/reboot
DefaultDependencies=no
Before=umount.target user@${LMS_UID}.service

[Service]
Type=oneshot
ExecStart=${HOOK_BIN}
TimeoutStartSec=45

[Install]
WantedBy=shutdown.target
EOF

systemctl daemon-reload
systemctl enable lms-unload.service >/dev/null 2>&1 || true
echo "    Enabled. Log will appear at: $LOG_FILE"

# ---------------------------------------------------------------- [3/3] done
cat <<'NEXT'

============================================================
 Done. Next steps:

 1) Takes effect at the NEXT shutdown or reboot — no reboot needed now.

 2) Optional dry-run test (WARNING: this unloads any model currently
    loaded in LM Studio, including whatever is serving Bionic right now):
        sudo systemctl start lms-unload.service
        cat /var/log/lms-unload.log

 3) After your next shutdown/reboot, check both logs side by side:
        cat /var/log/lms-unload.log      <- did the hook run? unload OK?
        cat /var/log/shutdown-trace.log  <- GPU state at poweroff (from fix-poweroff.sh)
    If "unload OK" appears and the machine still doesn't fully power off,
    the trace log will show what else was holding a CUDA context.

 4) To remove this hook later:
        sudo systemctl disable --now lms-unload.service
        sudo rm /etc/systemd/system/lms-unload.service /usr/local/bin/lms-unload-shutdown.sh
============================================================
NEXT
