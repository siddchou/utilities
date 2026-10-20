#!/usr/bin/env bash
# ============================================================================
#  nvidia_limit.sh - Configure NVIDIA GPU power limits on Linux
#
#  Linux port of nvidia_limit.bat (https://github.com/siddchou/utilities).
#
#  For every detected GPU this script will:
#    1. Wait for the driver / nvidia-smi to be ready (with retries)
#    2. Enable persistence mode (-pm 1)
#    3. Set a target power limit (-pl), clamped into the GPU's min/max range
#    4. Verify the applied limit and print a status summary
#
#  Usage:
#    nvidia_limit.sh [powerLimitWatts] [waitSeconds]
#      powerLimitWatts   Target power limit in watts (default: 275)
#      waitSeconds       Initial delay for driver init, 0 to skip (default: 15)
#
#  Requires: root privileges and an NVIDIA driver with nvidia-smi.
#  Exit code: 0 = all GPUs configured, 1 = one or more failures / bad usage.
# ============================================================================

set -u

TARGET_W=275
[[ $# -ge 1 && -n "${1:-}" ]] && TARGET_W="$1"
WAIT_S=15
[[ $# -ge 2 && -n "${2:-}" ]] && WAIT_S="$2"

is_number() { [[ "$1" =~ ^[0-9]+$ ]]; }

echo "============================================================================"
echo " NVIDIA GPU Power Limiter (Linux)"
echo "   Target power limit : ${TARGET_W} W (all detected GPUs)"
echo "   Persistence mode   : ON"
echo "   Started            : $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================================"
echo

# ---------------------------------------------------------------------------
# Validate arguments (non-negative integers)
# ---------------------------------------------------------------------------
if ! is_number "$TARGET_W" || ! is_number "$WAIT_S"; then
    echo "[ERROR] Invalid arguments - both must be non-negative integers (watts / seconds)."
    echo "Usage: nvidia_limit.sh [powerLimitWatts] [waitSeconds]"
    exit 1
fi

# ---------------------------------------------------------------------------
# Check that nvidia-smi exists (NVIDIA driver installed)
# ---------------------------------------------------------------------------
if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "[ERROR] nvidia-smi not found. Is the NVIDIA driver installed?"
    exit 1
fi

# ---------------------------------------------------------------------------
# Check for root privileges (-pl requires root on Linux).
# Advisory only: if we truly lack rights, nvidia-smi -pl below will fail
# per-GPU with its own clear error instead of being blocked here.
# ---------------------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
    echo "[WARN] Not running as root."
    echo "       Continuing anyway - if the power limit fails, re-run with:"
    echo "       sudo $0 ${TARGET_W} ${WAIT_S}"
fi

# ---------------------------------------------------------------------------
# Wait for driver initialization, then confirm nvidia-smi can see GPUs
# ---------------------------------------------------------------------------
if [[ "$WAIT_S" != "0" ]]; then
    echo "Waiting ${WAIT_S}s for GPU/driver initialization..."
    sleep "$WAIT_S"
fi

READY=0
for _ in 1 2 3 4 5; do
    if [[ $READY -eq 0 ]]; then
        nvidia-smi -L >/dev/null 2>&1 && READY=1 || sleep 3
    fi
done
if [[ $READY -ne 1 ]]; then
    echo "[ERROR] nvidia-smi is not reporting any GPUs after retries."
    exit 1
fi

# ---------------------------------------------------------------------------
# Detect GPU count and driver version
# ---------------------------------------------------------------------------
GPU_COUNT=$(nvidia-smi -L 2>/dev/null | grep -c '^GPU [0-9][0-9]*:')
if [[ $GPU_COUNT -eq 0 ]]; then
    echo "[ERROR] No NVIDIA GPUs detected."
    exit 1
fi

DRV_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1)
[[ -z "$DRV_VER" ]] && DRV_VER="unknown"

echo "Detected ${GPU_COUNT} GPU(s). Driver: ${DRV_VER}"
echo

# ---------------------------------------------------------------------------
# configure_gpu <index> - persistence mode + power limit for one GPU
# ---------------------------------------------------------------------------
OK=0
FAILS=0

configure_gpu() {
    local IDX="$1"
    echo "[GPU ${IDX}] Configuring..."

    # --- Read this GPU's allowed power range (watts) ---
    # nvidia-smi has no power.limit.min/max query fields; the range only comes
    # from the -q -d POWER section. Linux prints separate lines:
    #   "Min Power Limit : 100.00 W" / "Max Power Limit : 350.00 W"
    # (some drivers print a combined "Min/Max Power Limit : <min> W / <max> W").
    # Take the first real value; later repeats may be N/A.
    local POWER_BLOCK MIN_RAW MAX_RAW COMBINED
    POWER_BLOCK=$(nvidia-smi -i "$IDX" -q -d POWER 2>/dev/null)

    # First real value on each line (later repeats may be N/A).
    MIN_RAW=$(printf '%s\n' "$POWER_BLOCK" | grep -m1 'Min Power Limit' \
            | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {print $i; exit}}')
    MAX_RAW=$(printf '%s\n' "$POWER_BLOCK" | grep -m1 'Max Power Limit' \
            | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {print $i; exit}}')

    # Fallback for the combined "Min/Max Power Limit : <min> W / <max> W" format.
    if ! [[ "$MIN_RAW" =~ ^[0-9]+ ]] || ! [[ "$MAX_RAW" =~ ^[0-9]+ ]]; then
        COMBINED=$(printf '%s\n' "$POWER_BLOCK" | grep -m1 'Min/Max Power Limit')
        if [[ -n "$COMBINED" ]]; then
            MIN_RAW=$(awk '{for(i=1;i<=NF;i++)  if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {print $i; exit}}' <<<"$COMBINED")
            MAX_RAW=$(awk '{for(i=NF;i>=1;i--) if ($i ~ /^[0-9]+(\.[0-9]+)?$/) {print $i; exit}}' <<<"$COMBINED")
        fi
    fi

    # Keep only clean integers (strip the ".00" fraction, e.g. "100.00" -> 100).
    local MIN_W="" MAX_W=""
    [[ "$MIN_RAW" =~ ^[0-9]+ ]] && MIN_W="${MIN_RAW%%.*}"
    [[ "$MAX_RAW" =~ ^[0-9]+ ]] && MAX_W="${MAX_RAW%%.*}"

    # --- Clamp the target into this GPU's allowed range ---
    local APPLY_W="$TARGET_W"
    if is_number "${MIN_W:-}" && [[ "$TARGET_W" -lt "$MIN_W" ]]; then
        echo "   [NOTE] Target ${TARGET_W}W is below this GPU's minimum (${MIN_W}W); using ${MIN_W}W."
        APPLY_W="$MIN_W"
    elif is_number "${MAX_W:-}" && [[ "$TARGET_W" -gt "$MAX_W" ]]; then
        echo "   [NOTE] Target ${TARGET_W}W is above this GPU's maximum (${MAX_W}W); using ${MAX_W}W."
        APPLY_W="$MAX_W"
    fi

    # --- Enable persistence mode (best-effort; not supported on all platforms) ---
    # Note: nvidia-smi can exit 0 even when -pm fails, so inspect the output
    # and verify the resulting state instead of trusting the exit code.
    local PM_OUT PM_STATE
    PM_OUT=$(nvidia-smi -pm 1 -i "$IDX" 2>&1)
    if [[ $? -ne 0 || "$PM_OUT" == *"Unable to set persistence mode"* ]]; then
        echo "   [WARN] Persistence mode could not be enabled on GPU ${IDX} (continuing)."
    fi
    PM_STATE=$(nvidia-smi -i "$IDX" --query-gpu=persistence_mode \
               --format=csv,noheader 2>/dev/null | head -n1)
    [[ -z "$PM_STATE" ]] && PM_STATE="unknown"

    # --- Apply power limit ---
    if ! nvidia-smi -pl "$APPLY_W" -i "$IDX" >/dev/null 2>&1; then
        echo "   [ERROR] Failed to set the power limit on GPU ${IDX}."
        FAILS=$((FAILS + 1))
        return
    fi

    # --- Verify the applied limit ---
    local ACTUAL_W
    ACTUAL_W=$(nvidia-smi -i "$IDX" --query-gpu=power.limit \
               --format=csv,noheader,nounits 2>/dev/null | head -n1)
    ACTUAL_W="${ACTUAL_W%%.*}"

    if [[ "${ACTUAL_W:-}" == "$APPLY_W" ]]; then
        echo "   [ OK ] Persistence mode: ${PM_STATE}, power limit = ${ACTUAL_W} W  (range ${MIN_W:-?}-${MAX_W:-?} W)"
        OK=$((OK + 1))
    else
        echo "   [FAIL] Requested ${APPLY_W}W but GPU ${IDX} reports ${ACTUAL_W:-N/A}W."
        FAILS=$((FAILS + 1))
    fi
}

for (( i = 0; i < GPU_COUNT; i++ )); do
    configure_gpu "$i"
done

# ---------------------------------------------------------------------------
# Summary + status table
# ---------------------------------------------------------------------------
echo
echo "============================================================================"
if [[ $FAILS -eq 0 ]]; then
    echo " SUCCESS: all ${OK} GPU(s) configured to the target power limit."
else
    echo " WARNING: ${OK}/${GPU_COUNT} GPUs configured, ${FAILS} failed - see messages above."
fi
echo "============================================================================"
echo
echo "Current GPU Status:"
echo "-------------------"
nvidia-smi --query-gpu=index,name,power.limit,power.draw,temperature.gpu,utilization.gpu,memory.used --format=csv

if [[ $FAILS -eq 0 ]]; then
    exit 0
fi
exit 1
