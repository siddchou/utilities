#!/usr/bin/env bash
# =============================================================================
# install-dev-tools.sh — one-shot dev environment installer (NO root needed)
#
# Installs, user-locally under $HOME:
#   1. Google Chrome            -> ~/opt/google/chrome      (+ wrapper + .desktop)
#   2. Oracle JDK 27            -> ~/opt/jdk-27             (+ JAVA_HOME in ~/.bashrc)
#   3. Node.js (latest LTS)     -> ~/opt/nodejs             (+ node/npm/npx wrappers)
#   4. Flutter (stable channel) -> ~/flutter                (+ PATH in ~/.bashrc)
#   5. IntelliJ IDEA Ultimate   -> ~/opt/idea-IU-<build>    (+ `idea` wrapper + .desktop)
#   6. GitHub CLI (gh)          -> ~/.local/bin/gh          (+ optional auth via GH_TOKEN)
#
# Prerequisite: git — auto-installed via 'sudo dnf install git' when
# passwordless sudo is available; otherwise the script tells you what to run.
#
# Properties:
#   * Idempotent — re-running skips tools already at the latest version
#     (tracked in ~/.config/dev-tools-manifest); only outdated tools are
#     downloaded and reinstalled.
#   * No sudo required; everything lives under $HOME.
#   * Downloads run in parallel and are resumable (curl -C -).
#
# Requirements: bash, curl, tar, xz, cpio, rpm2cpio, python3 (git is auto-installed)
# Usage:        ./install-dev-tools.sh                 # install/update everything
#               SKIP_IDEA=1 ./install-dev-tools.sh     # skip one tool
#               (any of: CHROME JDK NODE FLUTTER IDEA GH)
#   Auth gh non-interactively with a personal access token:
#               GH_TOKEN=ghp_xxx ./install-dev-tools.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------- constants --
JDK_VERSION="27"
MANIFEST="$HOME/.config/dev-tools-manifest"
WORK="$(mktemp -d /tmp/devinst.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

ARCH="$(uname -m)"                       # x86_64 | aarch64
case "$ARCH" in
  x86_64)   NODE_ARCH="x64";    JDK_ARCH="x64";     CHROME_ARCH="x86_64"; GH_ARCH="amd64" ;;
  aarch64)  NODE_ARCH="arm64";  JDK_ARCH="aarch64"; CHROME_ARCH="aarch64"; GH_ARCH="arm64" ;;
  *) die "unsupported architecture: $ARCH" ;;
esac

# ------------------------------------------------------------------- helpers --
log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1 (install it first, e.g. 'sudo dnf install $1')"; }

manifest_get() { [ -f "$MANIFEST" ] && awk -F= -v k="$1" '$1==k{print $2}' "$MANIFEST"; }
manifest_set() {
  mkdir -p "$(dirname "$MANIFEST")"
  if grep -q "^$1=" "$MANIFEST" 2>/dev/null; then
    sed -i "s|^$1=.*|$1=$2|" "$MANIFEST"
  else
    echo "$1=$2" >> "$MANIFEST"
  fi
}

# Parallel, resumable downloads: download <url> <dest-in-$WORK>
PIDS=()
download() {
  curl -fSL --retry 3 -C - -o "$WORK/$2" "$1" &
  PIDS+=("$!")
}
wait_downloads() {
  local fail=0 pid
  for pid in "${PIDS[@]}"; do wait "$pid" || fail=1; done
  [ "$fail" -eq 0 ] || die "one or more downloads failed (see curl output above)"
}

# ------------------------------------------------------- version discovery ---
latest_node() {   # latest LTS, e.g. v24.21.0
  curl -fsSL --max-time 30 'https://nodejs.org/dist/index.json' \
    | python3 -c "import json,sys; print([r for r in json.load(sys.stdin) if r.get('lts')][0]['version'])"
}

latest_flutter() { # prints: <version> <archive-url>
  curl -fsSL --max-time 30 'https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json' \
    | python3 -c "
import json, sys
d = json.load(sys.stdin)
h = d['current_release']['stable']
r = [x for x in d['releases'] if x['hash'] == h][0]
base = 'https://storage.googleapis.com/flutter_infra_release/releases/'
print(r['version'], base + r['archive'])"
}

latest_idea() {   # prints: <marketing-version> (e.g. 2026.2.3) from JetBrains updates.xml
  curl -fsSL --max-time 60 'https://www.jetbrains.com/updates/updates.xml' -o "$WORK/updates.xml"
  python3 - "$WORK/updates.xml" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for p in root.iter('product'):
    code = p.get('code') or (p.findtext('code') if p.find('code') is not None else '')
    if code != 'IU':            # IU = IntelliJ IDEA Ultimate
        continue
    for ch in p.iter('channel'):
        if ch.get('status') != 'release':
            continue
        build = list(ch.iter('build'))[0]   # newest first
        print(build.get('version'))
PYEOF
}

latest_gh() {     # prints: <version> e.g. 2.102.0 (from GitHub releases API)
  curl -fsSL --max-time 30 'https://api.github.com/repos/cli/cli/releases/latest' \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'].lstrip('v'))"
}

# ------------------------------------------------------------- PATH / bashrc --
update_bashrc() {
  python3 - <<'PYEOF'
import os, re
path = os.path.expanduser('~/.bashrc')
block = '''# >>> dev-tools-managed >>>
export JAVA_HOME="$HOME/opt/jdk-27"
export PATH="$JAVA_HOME/bin:$HOME/flutter/bin:$PATH"
# <<< dev-tools-managed <<<'''
content = open(path).read() if os.path.exists(path) else ''
pat = re.compile(r'# >>> dev-tools-managed >>>.*?# <<< dev-tools-managed <<</', re.S)
if pat.search(content):
    content = pat.sub(block, content)
else:
    if content and not content.endswith('\n'):
        content += '\n'
    content += block + '\n'
open(path, 'w').write(content)
PYEOF
}

# ============================================================================
log "Checking prerequisites"
for c in curl tar xz cpio rpm2cpio python3; do need_cmd "$c"; done
if ! command -v git >/dev/null 2>&1; then
  if sudo -n dnf install -y git >/dev/null 2>&1; then
    log "git installed via dnf"
  else
    die "git not found (and passwordless sudo unavailable) — run 'sudo dnf install git' first, then re-run this script"
  fi
fi
[ -d "$HOME/.local/bin" ] || warn "$HOME/.local/bin missing or not on PATH — wrappers may not resolve in new shells"

# ============================================================================
log "Resolving latest versions"
NODE_VER="$(latest_node)";            log "Node.js LTS:      $NODE_VER"
read -r FLUTTER_VER FLUTTER_URL < <(latest_flutter);  log "Flutter stable:   $FLUTTER_VER"
IDEA_VER="$(latest_idea)";            log "IDEA Ultimate:    $IDEA_VER"
GH_VER="$(latest_gh)";                log "GitHub CLI:     $GH_VER"
log "Oracle JDK:       ${JDK_VERSION} (fixed)"

# ============================================================================
# Decide what actually needs work (manifest + live binary check).
NEED_CHROME=0; NEED_JDK=0; NEED_NODE=0; NEED_FLUTTER=0; NEED_IDEA=0; NEED_GH=0

if [ "${SKIP_CHROME:-0}" != 1 ]; then
  chrome_live="$(google-chrome --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)" || true
  { [ "$(manifest_get chrome)" = "$chrome_live" ] && [ -n "$chrome_live" ] \
    && [ -x "$HOME/opt/google/chrome/google-chrome" ]; } || NEED_CHROME=1
fi
if [ "${SKIP_JDK:-0}" != 1 ]; then
  { [ "$(manifest_get jdk)" = "$JDK_VERSION" ] && [ -x "$HOME/opt/jdk-${JDK_VERSION}/bin/java" ]; } || NEED_JDK=1
fi
if [ "${SKIP_NODE:-0}" != 1 ]; then
  { [ "$(manifest_get node)" = "$NODE_VER" ] && [ -x "$HOME/opt/nodejs/bin/node" ]; } || NEED_NODE=1
fi
if [ "${SKIP_FLUTTER:-0}" != 1 ]; then
  { [ "$(manifest_get flutter)" = "$FLUTTER_VER" ] && [ -x "$HOME/flutter/bin/flutter" ]; } || NEED_FLUTTER=1
fi
if [ "${SKIP_IDEA:-0}" != 1 ]; then
  { [ "$(manifest_get idea)" = "$IDEA_VER" ] && ls -d "$HOME"/opt/idea-IU-*/bin/idea.sh >/dev/null 2>&1; } || NEED_IDEA=1
fi
if [ "${SKIP_GH:-0}" != 1 ]; then
  { [ "$(manifest_get gh)" = "$GH_VER" ] && [ -x "$HOME/.local/bin/gh" ]; } || NEED_GH=1
fi

need_list=""
[ "$NEED_CHROME" = 1 ]  && need_list+="CHROME "   || true
[ "$NEED_JDK" = 1 ]     && need_list+="JDK "      || true
[ "$NEED_NODE" = 1 ]    && need_list+="NODE "     || true
[ "$NEED_FLUTTER" = 1 ] && need_list+="FLUTTER "  || true
[ "$NEED_IDEA" = 1 ]    && need_list+="IDEA "     || true
[ "$NEED_GH" = 1 ]      && need_list+="GH "       || true

# ============================================================================
log "Downloading (parallel, resumable) — needed: ${need_list:-none}"
[ "$NEED_CHROME" = 1 ]  && download "https://dl.google.com/linux/direct/google-chrome-stable_current_${CHROME_ARCH}.rpm" chrome.rpm   || true
[ "$NEED_JDK" = 1 ]     && download "https://download.oracle.com/java/${JDK_VERSION}/latest/jdk-${JDK_VERSION}_linux-${JDK_ARCH}_bin.tar.gz" jdk.tar.gz || true
[ "$NEED_NODE" = 1 ]    && download "https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}-linux-${NODE_ARCH}.tar.xz" node.tar.xz        || true
[ "$NEED_FLUTTER" = 1 ] && download "$FLUTTER_URL" flutter.tar.xz                                                                                   || true
[ "$NEED_IDEA" = 1 ]    && download "https://download.jetbrains.com/idea/ideaIU-${IDEA_VER}.tar.gz" idea.tar.gz                                     || true
[ "$NEED_GH" = 1 ]      && download "https://github.com/cli/cli/releases/download/v${GH_VER}/gh_${GH_VER}_linux_${GH_ARCH}.tar.gz" gh.tar.gz        || true
if [ "${#PIDS[@]}" -gt 0 ]; then
  wait_downloads
  ls -lh "$WORK"
fi

# ============================================================================
if [ "$NEED_CHROME" = 1 ]; then
log "Installing Google Chrome -> ~/opt/google/chrome"
rm -rf "$WORK/chrome-x"; mkdir -p "$WORK/chrome-x"
( cd "$WORK/chrome-x" && rpm2cpio "$WORK/chrome.rpm" | cpio -idm --quiet )
[ -d "$WORK/chrome-x/opt/google" ] || die "chrome rpm did not contain opt/google"
mkdir -p "$HOME/opt"; rm -rf "$HOME/opt/google"
mv "$WORK/chrome-x/opt/google" "$HOME/opt/"          # move contents, avoid nesting
fi
# wrappers + desktop entry (cheap & idempotent — always refreshed)
if [ "${SKIP_CHROME:-0}" != 1 ]; then
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/google-chrome" <<'EOF'
#!/bin/sh
exec "$HOME/opt/google/chrome/google-chrome" "$@"
EOF
chmod +x "$HOME/.local/bin/google-chrome"
ln -sf google-chrome "$HOME/.local/bin/chrome"
mkdir -p "$HOME/.local/share/applications"
cat > "$HOME/.local/share/applications/google-chrome.desktop" <<EOF
[Desktop Entry]
Name=Google Chrome
Comment=Web Browser
Exec=$HOME/.local/bin/google-chrome %U
Icon=$HOME/opt/google/chrome/product_logo_48.png
Terminal=false
Type=Application
Categories=Network;WebBrowser;
EOF
manifest_set chrome "$(google-chrome --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
fi

# ============================================================================
if [ "$NEED_JDK" = 1 ]; then
log "Installing Oracle JDK ${JDK_VERSION} -> ~/opt/jdk-${JDK_VERSION}"
# verify checksum (Oracle publishes a .sha256 sidecar)
curl -fsSL --max-time 30 -o "$WORK/jdk.sha256" \
  "https://download.oracle.com/java/${JDK_VERSION}/latest/jdk-${JDK_VERSION}_linux-${JDK_ARCH}_bin.tar.gz.sha256"
( cd "$WORK" && echo "$(awk '{print $1}' jdk.sha256)  jdk.tar.gz" | sha256sum -c - ) \
  || die "Oracle JDK checksum mismatch!"
mkdir -p "$HOME/opt"; rm -rf "$HOME/opt/jdk-${JDK_VERSION}"
tar -xzf "$WORK/jdk.tar.gz" -C "$HOME/opt/"
fi
[ "${SKIP_JDK:-0}" != 1 ] && manifest_set jdk "$JDK_VERSION" || true

# ============================================================================
if [ "$NEED_NODE" = 1 ]; then
log "Installing Node.js ${NODE_VER} -> ~/opt/nodejs"
rm -rf "$HOME/opt/nodejs"; mkdir -p "$HOME/opt/nodejs"
tar -xJf "$WORK/node.tar.xz" -C "$HOME/opt/nodejs" --strip-components=1
fi
if [ "${SKIP_NODE:-0}" != 1 ]; then
mkdir -p "$HOME/.local/bin"
ln -sf "$HOME/opt/nodejs/bin/node" "$HOME/.local/bin/node"
ln -sf "$HOME/opt/nodejs/bin/npm"  "$HOME/.local/bin/npm"
ln -sf "$HOME/opt/nodejs/bin/npx"  "$HOME/.local/bin/npx"
manifest_set node "$NODE_VER"
fi

# ============================================================================
if [ "$NEED_FLUTTER" = 1 ]; then
log "Installing Flutter ${FLUTTER_VER} -> ~/flutter"
rm -rf "$HOME/flutter"
tar -xJf "$WORK/flutter.tar.xz" -C "$HOME"            # creates ~/flutter
fi
if [ "${SKIP_FLUTTER:-0}" != 1 ]; then
  # first run downloads the Dart SDK / artifacts (can take a minute)
  "$HOME/flutter/bin/flutter" --version >/dev/null 2>&1 || true
  manifest_set flutter "$FLUTTER_VER"
fi

# ============================================================================
if [ "$NEED_IDEA" = 1 ]; then
log "Installing IntelliJ IDEA Ultimate ${IDEA_VER} -> ~/opt/"
rm -rf "$HOME"/opt/idea-IU-*                          # remove previous installs
tar -xzf "$WORK/idea.tar.gz" -C "$HOME/opt/"
fi
if [ "${SKIP_IDEA:-0}" != 1 ]; then
  # folder name is build-based (e.g. idea-IU-262.10968.63) — detect dynamically
  IDEA_DIR="$(ls -d "$HOME"/opt/idea-IU-* | head -1)"
  [ -x "$IDEA_DIR/bin/idea.sh" ] || die "IDEA extraction failed (no bin/idea.sh in $IDEA_DIR)"
  cat > "$HOME/.local/bin/idea" <<EOF
#!/bin/sh
exec "$IDEA_DIR/bin/idea.sh" "\$@"
EOF
  chmod +x "$HOME/.local/bin/idea"
  mkdir -p "$HOME/.local/share/applications"
  cat > "$HOME/.local/share/applications/intellij-idea-ultimate.desktop" <<EOF
[Desktop Entry]
Name=IntelliJ IDEA Ultimate
Comment=IntelliJ IDEA Ultimate ${IDEA_VER}
Exec=$HOME/.local/bin/idea %U
Icon=${IDEA_DIR}/bin/idea.png
Terminal=false
Type=Application
Categories=Development;IDE;
EOF
  manifest_set idea "$IDEA_VER"
fi

# ============================================================================
if [ "$NEED_GH" = 1 ]; then
log "Installing GitHub CLI ${GH_VER} -> ~/.local/bin/gh"
rm -rf "$WORK/gh-x"; mkdir -p "$WORK/gh-x"
tar -xzf "$WORK/gh.tar.gz" -C "$WORK/gh-x"
install -m 755 "$WORK/gh-x/gh_${GH_VER}_linux_${GH_ARCH}/bin/gh" "$HOME/.local/bin/gh"
fi
if [ "${SKIP_GH:-0}" != 1 ]; then
  if [ -n "${GH_TOKEN:-}" ]; then
    printf '%s' "$GH_TOKEN" | gh auth login --with-token >/dev/null 2>&1 \
      && log "gh authenticated (via GH_TOKEN)" || warn "GH_TOKEN was rejected by GitHub — check the token and re-run"
  elif ! gh auth status >/dev/null 2>&1; then
    warn "gh is not authenticated — run 'gh auth login' in a terminal, or set GH_TOKEN and re-run this script"
  fi
  manifest_set gh "$GH_VER"
fi

# ============================================================================
log "Updating ~/.bashrc (JAVA_HOME + PATH)"
update_bashrc

# ============================================================================
log "Verification (fresh login shell)"
env -i HOME="$HOME" TERM=xterm bash -lc '
  printf "%-14s %s\n" "git:"       "$(git --version)"
  printf "%-14s %s\n" "java:"      "$(java -version 2>&1 | head -1)"
  printf "%-14s %s\n" "JAVA_HOME:" "$JAVA_HOME"
  printf "%-14s %s\n" "node:"      "$(node --version) (npm $(npm --version))"
  printf "%-14s %s\n" "flutter:"   "$(flutter --version 2>/dev/null | head -1)"
  printf "%-14s %s\n" "chrome:"    "$(google-chrome --version)"
  printf "%-14s %s\n" "idea:"      "$(command -v idea || echo MISSING)"
  if command -v gh >/dev/null 2>&1; then
    auth="authenticated"
    gh auth status >/dev/null 2>&1 || auth="NOT AUTHENTICATED (run: gh auth login)"
    printf "%-14s %s\n" "gh:"        "$(gh --version | head -1) — $auth"
  else
    printf "%-14s %s\n" "gh:"        "MISSING"
  fi
'

log "All done. Open a new terminal (or run 'source ~/.bashrc') to use the tools."
echo "  java / javac   -> Oracle JDK ${JDK_VERSION}   ($HOME/opt/jdk-${JDK_VERSION})"
echo "  node / npm     -> $NODE_VER                   ($HOME/opt/nodejs)"
echo "  flutter        -> $FLUTTER_VER                ($HOME/flutter)"
echo "  google-chrome  -> Chrome                      ($HOME/opt/google/chrome)"
echo "  git            -> $(git --version | awk '{print $3}')   (prerequisite)"
echo "  gh             -> GitHub CLI ${GH_VER} ($HOME/.local/bin/gh)"
