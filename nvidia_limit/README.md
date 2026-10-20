# nvidia_limit

Set per-GPU NVIDIA power limits at boot on Linux, or on demand on Windows.

For every detected GPU this utility will:

1. Wait for the driver / `nvidia-smi` to be ready (with retries)
2. Enable persistence mode (`-pm 1`) — best effort
3. Set a target power limit (`-pl`), clamped into each GPU's own min/max range
4. Verify the applied limit and print a status summary

## Files

| File | Purpose |
|---|---|
| `nvidia_limit.sh` | Linux power limiter (the core script) |
| `install.sh` | Installs the script + systemd unit, enables it at boot, verifies |
| `update_nvidia_driver.sh` | Updates the apt-managed NVIDIA driver to the newest branch in your repos |
| `nvidia-limit.service` | Reference systemd unit (the installer generates its own with your wattage baked in) |
| `nvidia_limit.bat` | Windows equivalent — run as administrator |

## Linux

### Install (applies the limit on every boot)

```bash
./install.sh [powerLimitWatts]    # default: 275
```

Installs:

- `/usr/local/bin/nvidia_limit.sh`
- `/etc/systemd/system/nvidia-limit.service` — enabled, runs at boot (`multi-user.target`)

Re-execs itself with `sudo` when not run as root. Re-running is safe and idempotent: it regenerates the unit with your wattage and re-verifies.

### One-off / change the limit on the fly

```bash
sudo nvidia_limit.sh [powerLimitWatts] [waitSeconds]    # defaults: 275, 15 (0 = skip wait)
```

### Manage

```bash
systemctl status nvidia-limit              # "active (exited)" = ran successfully at boot
sudo systemctl disable --now nvidia-limit  # stop applying the limit at boot
nvidia-smi -q -d POWER                     # inspect current limits per GPU
```

### Update the NVIDIA driver

```bash
./update_nvidia_driver.sh            # update to the newest branch in your repos
./update_nvidia_driver.sh --check    # report current vs available, install nothing
./update_nvidia_driver.sh 615        # pin a specific branch (also used for downgrades)
```

- Works with apt-managed drivers (`nvidia-driver-*` packages); the open/proprietary kernel flavor of your current install is preserved.
- Re-execs itself with `sudo`. A reboot is required after an update so the new kernel module loads; verify afterwards with `nvidia-smi --query-gpu=name,driver_version --format=csv,noheader`.

## Windows

Run as administrator:

```bat
nvidia_limit.bat [powerLimitWatts] [waitSeconds]    # defaults: 275, 15 (0 = skip wait)
```

## Notes

- Requires root/admin and an NVIDIA driver with `nvidia-smi`.
- Power limits are **not persistent** across reboots or driver reloads — that is exactly what the boot service is for.
- The same target wattage applies to all GPUs; each GPU clamps it into its own min/max range (e.g. a 275 W target on an RTX 3090 with a 100–350 W range stays at 275 W, while a 400 W target would be capped at the GPU's maximum).
- Exit code: `0` = all GPUs configured and verified, `1` = one or more failures.
