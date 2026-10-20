#!/usr/bin/env bash
# ============================================================================
#  update_nvidia_driver.sh - Update the apt-managed NVIDIA driver (Ubuntu/Debian)
#
#  Finds the newest nvidia-driver branch available in your package repos and
#  installs it, replacing whatever branch is currently installed. The kernel
#  flavor of today's install (open vs proprietary) is preserved automatically.
#
#  Usage:
#    ./update_nvidia_driver.sh [branch] [--check]
#      branch     Target driver branch to install, e.g. 615 (default: newest in repos)
#      --check    Only report current vs available; do not install anything
#
#  Requires: root privileges (re-execs itself with sudo when not run as root).
#  Exit code: 0 = up to date / updated successfully, 1 = failure or bad usage.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $(basename "$0") [branch] [--check]"
    echo "  branch     Target driver branch to install, e.g. 615 (default: newest in repos)"
    echo "  --check    Only report current vs available; do not install anything"
}

CHECK_ONLY=0
TARGET_BRANCH=""
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        --check)   CHECK_ONLY=1 ;;
        *)
            if [[ -n "$TARGET_BRANCH" ]]; then
                echo "[ERROR] Unexpected argument: $arg" >&2
                usage >&2
                exit 1
            fi
            TARGET_BRANCH="$arg"
            ;;
    esac
done

if [[ -n "$TARGET_BRANCH" && ! "$TARGET_BRANCH" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] branch must be a plain number, e.g. 615 (got: $TARGET_BRANCH)" >&2
    usage >&2
    exit 1
fi

# Re-exec with sudo if not root.
if [[ "$(id -u)" -ne 0 ]]; then
    exec sudo bash "$SCRIPT_DIR/update_nvidia_driver.sh" "$@"
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo "[ERROR] This script requires apt (Ubuntu/Debian)." >&2
    exit 1
fi

RUNNING_DRIVER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)"

echo "============================================================================"
echo " NVIDIA Driver Update (apt-managed, $(. /etc/os-release && echo "$PRETTY_NAME"))"
if [[ -n "${RUNNING_DRIVER:-}" ]]; then
    echo "   Currently running driver : ${RUNNING_DRIVER}"
fi
[[ $CHECK_ONLY -eq 1 ]] && echo "   Mode                   : check only (no install)"
echo "============================================================================"
echo

# ---------------------------------------------------------------------------
# Detect the installed driver: highest branch wins, remember its flavor.
# ---------------------------------------------------------------------------
CURRENT_BRANCH=""
FLAVOR_SUFFIX=""    # "-open" or ""
while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    b="${pkg#nvidia-driver-}"
    suffix=""
    if [[ "$b" == *-open ]]; then
        b="${b%-open}"
        suffix="-open"
    fi
    if (( 10#$b > 10#${CURRENT_BRANCH:-0} )); then
        CURRENT_BRANCH="$b"
        FLAVOR_SUFFIX="$suffix"
    fi
done < <(dpkg-query -W -f='${Package}\n' 'nvidia-driver-[0-9]+' 2>/dev/null || true)

if [[ -z "$CURRENT_BRANCH" ]]; then
    echo "[ERROR] No apt-managed NVIDIA driver found (expected nvidia-driver-* packages)." >&2
    echo "        Install one first, e.g.:" >&2
    echo "          sudo ubuntu-drivers install" >&2
    echo "          sudo apt install nvidia-driver-<branch>-open" >&2
    exit 1
fi

echo "[..] Installed driver branch : ${CURRENT_BRANCH}${FLAVOR_SUFFIX}"

# ---------------------------------------------------------------------------
# Refresh package lists, then list available branches for the same flavor.
# ---------------------------------------------------------------------------
echo "[..] Refreshing package lists (apt-get update) ..."
DEBIAN_FRONTEND=noninteractive apt-get update -qq

mapfile -t AVAILABLE < <(
    apt-cache search --names-only "^nvidia-driver-[0-9]+${FLAVOR_SUFFIX}\$" \
        | awk '{print $1}' \
        | sed -E 's/^nvidia-driver-([0-9]+).*/\1/' \
        | sort -un
)

if [[ ${#AVAILABLE[@]} -eq 0 ]]; then
    echo "[ERROR] No nvidia-driver packages found in your repos (flavor: '${FLAVOR_SUFFIX}')." >&2
    echo "        Check that 'universe' is enabled and try again after a manual apt update." >&2
    exit 1
fi

echo "[..] Available branches      : ${AVAILABLE[*]}"

# ---------------------------------------------------------------------------
# Pick the target branch (default: newest available).
# ---------------------------------------------------------------------------
if [[ -z "$TARGET_BRANCH" ]]; then
    TARGET_BRANCH="${AVAILABLE[-1]}"
else
    if ! printf '%s\n' "${AVAILABLE[@]}" | grep -qx "$TARGET_BRANCH"; then
        echo "[ERROR] Branch ${TARGET_BRANCH}${FLAVOR_SUFFIX} is not available in your repos." >&2
        echo "        Available: ${AVAILABLE[*]}${FLAVOR_SUFFIX}" >&2
        exit 1
    fi
fi

echo "[..] Target driver branch    : ${TARGET_BRANCH}${FLAVOR_SUFFIX}"
echo

# ---------------------------------------------------------------------------
# Compare and act.
# ---------------------------------------------------------------------------
if (( 10#$TARGET_BRANCH == 10#$CURRENT_BRANCH )); then
    echo "[ OK ] Already up to date (branch ${CURRENT_BRANCH}${FLAVOR_SUFFIX})."
    exit 0
fi

if [[ $CHECK_ONLY -eq 1 ]]; then
    if (( 10#$TARGET_BRANCH > 10#$CURRENT_BRANCH )); then
        echo "[..] An update is available: ${CURRENT_BRANCH} -> ${TARGET_BRANCH}${FLAVOR_SUFFIX}"
        echo "     Run without --check to install it."
    else
        echo "[..] Pinned branch ${TARGET_BRANCH} is OLDER than installed ${CURRENT_BRANCH} (would downgrade)."
    fi
    exit 0
fi

if (( 10#$TARGET_BRANCH < 10#$CURRENT_BRANCH )); then
    echo "[WARN] Target ${TARGET_BRANCH} is older than installed ${CURRENT_BRANCH} - downgrading."
fi

echo "[..] Installing nvidia-driver-${TARGET_BRANCH}${FLAVOR_SUFFIX} ..."
DEBIAN_FRONTEND=noninteractive apt-get install -y "nvidia-driver-${TARGET_BRANCH}${FLAVOR_SUFFIX}"

NEW_VERSION="$(dpkg-query -W -f='${Version}' "nvidia-driver-${TARGET_BRANCH}${FLAVOR_SUFFIX}" 2>/dev/null || echo '?')"
echo
echo "[ OK ] Installed nvidia-driver-${TARGET_BRANCH}${FLAVOR_SUFFIX} ${NEW_VERSION} (was branch ${CURRENT_BRANCH})."
echo
echo "A reboot is required for the new kernel module to load:"
echo "    sudo reboot"
echo "Then verify with:"
echo "    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader"
