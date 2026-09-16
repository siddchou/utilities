#!/usr/bin/env bash
# Installs Claude Desktop for Linux (includes Claude Code) via Anthropic's apt repo.
# Docs: https://code.claude.com/docs/en/desktop-linux
set -euo pipefail

EXPECTED_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
KEYRING="/usr/share/keyrings/claude-desktop-archive-keyring.asc"
REPO_LIST="/etc/apt/sources.list.d/claude-desktop.list"

# 0. Prerequisites (curl is missing on this machine)
if ! command -v curl >/dev/null; then
  echo ">> Installing curl + gnupg..."
  sudo apt-get update
  sudo apt-get install -y curl gnupg
fi

# 1. Download Anthropic's signing key
echo ">> Downloading signing key..."
sudo curl -fsSLo "$KEYRING" https://downloads.claude.ai/claude-desktop/key.asc

# 2. Verify the fingerprint (docs: must be $EXPECTED_FPR)
FPR=$(gpg --show-keys "$KEYRING" 2>/dev/null | grep -oE '[0-9A-F]{40}' | head -n1)
if [[ "${FPR:-}" != "$EXPECTED_FPR" ]]; then
  echo "ERROR: key fingerprint mismatch (got '${FPR:-none}', expected '$EXPECTED_FPR')" >&2
  exit 1
fi
echo ">> Key fingerprint OK: $FPR"

# 3. Register the repository
echo ">> Registering apt repo..."
echo "deb [arch=amd64,arm64 signed-by=$KEYRING] https://downloads.claude.ai/claude-desktop/apt/stable stable main" | sudo tee "$REPO_LIST" >/dev/null

# 4. Install the package (Cowork's QEMU deps come in as recommended packages)
echo ">> Installing claude-desktop..."
sudo apt-get update
sudo apt-get install -y claude-desktop

echo
echo "Done! Launch with: claude-desktop   (or from your app launcher)"
