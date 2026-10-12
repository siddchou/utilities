#!/usr/bin/env bash
# ============================================================================
#  install.sh - Install nvidia_limit.sh and trigger it at startup (systemd)
#
#  Installs:
#    /usr/local/bin/nvidia_limit.sh                    (the power limiter script)
#    /etc/systemd/system/nvidia-limit.service          (runs the script at boot)
#
#  Usage:
#    ./install.sh [powerLimitWatts]        (default: 275)
#
#  Re-execs itself with sudo when not run as root.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_W="${1:-275}"

if ! [[ "$TARGET_W" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] powerLimitWatts must be a non-negative integer (got: $TARGET_W)" >&2
    exit 1
fi

# Re-exec with sudo if not root.
if [[ "$(id -u)" -ne 0 ]]; then
    exec sudo bash "$SCRIPT_DIR/install.sh" "$TARGET_W"
fi

echo "Installing nvidia_limit for target power limit ${TARGET_W}W ..."

install -m 0755 "$SCRIPT_DIR/nvidia_limit.sh" /usr/local/bin/nvidia_limit.sh

# Write the systemd unit with the chosen wattage baked into ExecStart.
cat > /etc/systemd/system/nvidia-limit.service <<EOF
[Unit]
Description=NVIDIA GPU power limiter (apply per-GPU power limit at boot)
Documentation=https://github.com/siddchou/utilities/tree/main/nvidia_limit
After=nvidia-persistenced.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nvidia_limit.sh ${TARGET_W} 15

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nvidia-limit.service

echo
echo "Installed. Running now to verify..."
if /usr/local/bin/nvidia_limit.sh "$TARGET_W" 0; then
    echo
    echo "[ OK ] Power limit applied and verified."
else
    rc=$?
    echo
    echo "[WARN] The script reported failures (see output above)."
fi

echo
echo "Enabled at startup: nvidia-limit.service will run on every boot."
echo "Check status anytime with:  systemctl status nvidia-limit"
exit "${rc:-0}"
