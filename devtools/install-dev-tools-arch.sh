#!/usr/bin/env bash
# =============================================================================
# install-dev-tools-arch.sh — one-shot dev environment installer for
# Arch Linux / CachyOS, no root needed. Sibling of install-dev-tools.sh
# (Fedora); same layout, manifest and wrappers, Arch-specific plumbing.
#
# Installs, user-locally under $HOME:
#   1. Oracle JDK 27            -> ~/opt/jdk-27          (+ JAVA_HOME via env file)
#   2. Google Chrome (stable)   -> ~/opt/google/chrome   (+ wrapper + .desktop)
#   3. GitHub CLI (gh)          -> ~/.local/bin/gh       (+ optional auth via GH_TOKEN)
#
# Deliberately does NOT install Flutter or IntelliJ IDEA (both are huge; add
# them if you want them) and does not touch an existing system Node.js, which
# Arch ships current — a second copy under ~/opt would just shadow it on PATH.
#
# Arch-specific notes:
#   * Chrome is taken from Google's .deb, not the .rpm. Beyond 'rpm2cpio' not
#     existing here, current google-chrome RPMs carry a chunked payload
#     container ('07070X' plus a bare counter where a newc cpio header should
#     be) that neither GNU cpio nor libarchive 3.8.11 (built without an rpm
#     reader) can unpack. The .deb is ar + data.tar.xz, handled by bsdtar +
#     tar, and ships an identical /opt/google/chrome tree.
#   * chrome-sandbox keeps no setuid bit (impossible without root). Fine while
#     unprivileged user namespaces are on — 'sysctl kernel.unprivileged_userns_clone'
#     — because Chrome then uses the namespace sandbox instead of the SUID one.
#   * Shell wiring covers bash, fish and zsh. A block appended to ~/.bashrc is
#     NOT enough: the Arch skeleton returns early for non-interactive shells
#     ('[[ $- != *i* ]] && return'), so 'ssh host cmd' and IDE-launched tools
#     never see JAVA_HOME. Exports live in one file, ~/.config/dev-tools/env.sh,
#     sourced from ~/.bashrc + ~/.bash_profile (bash), ~/.zshenv (zsh, all
#     modes) and ~/.config/fish/conf.d/dev-tools.fish (fish, all modes).
#
# Properties:
#   * Idempotent — re-running skips tools already at the expected version
#     (tracked in ~/.config/dev-tools-manifest); only outdated tools are
#     downloaded. Delete a file under ./devinst to force a refetch.
#   * No sudo required; everything lives under $HOME.
#   * Downloads run in parallel and are resumable (curl -C -).
#
# Requirements: bash, curl, tar, xz, bsdtar (libarchive), python3
# Usage:        ./install-dev-tools-arch.sh                # install / update all
#               SKIP_CHROME=1 ./install-dev-tools-arch.sh  # skip one tool
#               (any of: JDK CHROME GH)
#   Auth gh non-interactively with a personal access token:
#               GH_TOKEN=ghp_xxx ./install-dev-tools-arch.sh
#
# Verified on CachyOS (Arch rolling), bash 5.3 / fish 4.9 / zsh 5.9.
# =============================================================================
set -euo pipefail

JDK_VERSION="27"
GH_VERSION="2.103.3"
MANIFEST="$HOME/.config/dev-tools-manifest"
DL="$(cd "$(dirname "${BASH_SOURCE[0]}")/devinst" && pwd)"   # package cache; fetched on demand
WORK="$(mktemp -d /tmp/devinst.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

manifest_get() { [ -f "$MANIFEST" ] && awk -F= -v k="$1" '$1==k{print $2}' "$MANIFEST" || true; }
manifest_set() {
  mkdir -p "$(dirname "$MANIFEST")"
  if grep -q "^$1=" "$MANIFEST" 2>/dev/null; then
    sed -i "s|^$1=.*|$1=$2|" "$MANIFEST"
  else
    echo "$1=$2" >> "$MANIFEST"
  fi
}

# -------------------------------------------- what actually needs installing --
NEED_JDK=0; NEED_CHROME=0; NEED_GH=0
if [ "${SKIP_JDK:-0}" != 1 ]; then
  { [ -x "$HOME/opt/jdk-${JDK_VERSION}/bin/java" ] && [ "$(manifest_get jdk)" = "$JDK_VERSION" ]; } || NEED_JDK=1
fi
CHROME_LIVE="$("$HOME/.local/bin/google-chrome" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
if [ "${SKIP_CHROME:-0}" != 1 ]; then
  { [ -n "$CHROME_LIVE" ] && [ -x "$HOME/opt/google/chrome/google-chrome" ] \
    && [ "$(manifest_get chrome)" = "$CHROME_LIVE" ]; } || NEED_CHROME=1
fi
if [ "${SKIP_GH:-0}" != 1 ]; then
  { [ -x "$HOME/.local/bin/gh" ] && [ "$(manifest_get gh)" = "$GH_VERSION" ] \
    && "$HOME/.local/bin/gh" --version >/dev/null 2>&1; } || NEED_GH=1
fi
todo=""
[ "$NEED_JDK" = 1 ]    && todo+="JDK "    || true
[ "$NEED_CHROME" = 1 ] && todo+="CHROME " || true
[ "$NEED_GH" = 1 ]     && todo+="GH "     || true

# --------------------------------------------------------------- downloads ---
# Parallel and resumable; only what is missing/outdated is fetched, and an
# existing download is reused (delete the file in ./devinst to force a refetch).
mkdir -p "$DL"
PIDS=()
fetch() {   # fetch <url> <dest-name>
  [ -s "$DL/$2" ] && { printf '    cached  %s\n' "$2"; return 0; }
  printf '    %s\n' "$2"
  curl -fSL --retry 3 -C - -o "$DL/$2.part" "$1" && mv "$DL/$2.part" "$DL/$2"
}
log "Fetching packages — needed: ${todo:-none}"
fetch_if() {   # fetch_if <need-flag> <url> <dest-name> — always exits 0 when not needed
  [ "$1" = 1 ] || return 0
  fetch "$2" "$3"
}
fetch_if "$NEED_CHROME" "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" chrome.deb & PIDS+=("$!")
fetch_if "$NEED_JDK"    "https://download.oracle.com/java/${JDK_VERSION}/latest/jdk-${JDK_VERSION}_linux-x64_bin.tar.gz" jdk.tar.gz & PIDS+=("$!")
fetch_if "$NEED_JDK"    "https://download.oracle.com/java/${JDK_VERSION}/latest/jdk-${JDK_VERSION}_linux-x64_bin.tar.gz.sha256" jdk.sha256 & PIDS+=("$!")
fetch_if "$NEED_GH"     "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" gh.tar.gz & PIDS+=("$!")
fail=0
for pid in ${PIDS[@]+"${PIDS[@]}"}; do wait "$pid" || fail=1; done
[ "$fail" = 0 ] || die "one or more downloads failed (see curl output above)"

if [ "$NEED_CHROME" = 1 ]; then [ -s "$DL/chrome.deb" ] || die "missing download: chrome.deb"; fi
if [ "$NEED_JDK" = 1 ]; then [ -s "$DL/jdk.tar.gz" ] && [ -s "$DL/jdk.sha256" ] || die "missing download: jdk tarball/sha256"; fi
if [ "$NEED_GH" = 1 ]; then [ -s "$DL/gh.tar.gz" ] || die "missing download: gh.tar.gz"; fi
command -v bsdtar >/dev/null 2>&1 || die "bsdtar is required to unpack the Chrome .deb here"

mkdir -p "$HOME/opt" "$HOME/.local/bin" "$HOME/.local/share/applications"

# ---------------------------------------------------------------- JDK --------
if [ "${SKIP_JDK:-0}" = 1 ]; then
  log "Oracle JDK ${JDK_VERSION} skipped (SKIP_JDK=1)"
elif [ "$NEED_JDK" = 0 ]; then
  log "Oracle JDK ${JDK_VERSION} already installed — skipping"
else
  log "Verifying Oracle JDK ${JDK_VERSION} checksum"
  ( cd "$DL" && echo "$(awk '{print $1}' jdk.sha256)  jdk.tar.gz" | sha256sum -c - ) \
    || die "Oracle JDK checksum mismatch!"

  log "Installing Oracle JDK ${JDK_VERSION} -> ~/opt/jdk-${JDK_VERSION}"
  mkdir -p "$WORK/jdk-x"
  tar -xzf "$DL/jdk.tar.gz" -C "$WORK/jdk-x"
  JDK_DIR="$(find "$WORK/jdk-x" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [ -n "$JDK_DIR" ] && [ -x "$JDK_DIR/bin/java" ] || die "JDK tarball layout unexpected (no bin/java)"
  rm -rf "$HOME/opt/jdk-${JDK_VERSION}"
  mv "$JDK_DIR" "$HOME/opt/jdk-${JDK_VERSION}"
  manifest_set jdk "$JDK_VERSION"
fi

# --------------------------------------------------------------- Chrome ------
if [ "${SKIP_CHROME:-0}" = 1 ]; then
  log "Google Chrome skipped (SKIP_CHROME=1)"
elif [ "$NEED_CHROME" = 0 ]; then
  log "Google Chrome ${CHROME_LIVE} already installed — skipping"
else
log "Unpacking Google Chrome .deb -> ~/opt/google/chrome (ar + data.tar.xz)"
mkdir -p "$WORK/deb"
bsdtar -xf "$DL/chrome.deb" -C "$WORK/deb" || die "failed to unpack chrome.deb"
[ -f "$WORK/deb/data.tar.xz" ] || die "chrome.deb did not contain data.tar.xz"
tar -xJf "$WORK/deb/data.tar.xz" -C "$WORK/deb"
[ -d "$WORK/deb/opt/google" ] || die "chrome package did not contain opt/google"
rm -rf "$HOME/opt/google"
mv "$WORK/deb/opt/google" "$HOME/opt/"
fi

# Wrapper + desktop entry, refreshed on every run — but only if Chrome is
# actually present, so SKIP_CHROME=1 on a fresh machine cannot leave a wrapper
# pointing at a binary that does not exist.
if [ -x "$HOME/opt/google/chrome/google-chrome" ]; then
cat > "$HOME/.local/bin/google-chrome" <<'EOF'
#!/bin/sh
exec "$HOME/opt/google/chrome/google-chrome" "$@"
EOF
chmod +x "$HOME/.local/bin/google-chrome"
ln -sf google-chrome "$HOME/.local/bin/chrome"

CHROME_ICON="$(find "$HOME/opt/google/chrome" -maxdepth 1 -name '*logo*48*.png' | head -1)"
[ -n "$CHROME_ICON" ] || CHROME_ICON="$HOME/opt/google/chrome/product_logo_48.png"
cat > "$HOME/.local/share/applications/google-chrome.desktop" <<EOF
[Desktop Entry]
Name=Google Chrome
Comment=Web Browser
Exec=$HOME/.local/bin/google-chrome %U
Icon=$CHROME_ICON
Terminal=false
Type=Application
Categories=Network;WebBrowser;
EOF
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$HOME/.local/share/applications" || true
manifest_set chrome "$("$HOME/.local/bin/google-chrome" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
fi

# ------------------------------------------------------------------ gh -------
if [ "${SKIP_GH:-0}" = 1 ]; then
  log "GitHub CLI skipped (SKIP_GH=1)"
elif [ "$NEED_GH" = 0 ]; then
  log "GitHub CLI ${GH_VERSION} already installed — skipping"
else
log "Installing GitHub CLI ${GH_VERSION} -> ~/.local/bin/gh"
mkdir -p "$WORK/gh-x"
tar -xzf "$DL/gh.tar.gz" -C "$WORK/gh-x"
install -m 755 "$WORK/gh-x/gh_${GH_VERSION}_linux_amd64/bin/gh" "$HOME/.local/bin/gh"
manifest_set gh "$GH_VERSION"
fi
if [ -x "$HOME/.local/bin/gh" ]; then
  if [ -n "${GH_TOKEN:-}" ]; then
    printf '%s' "$GH_TOKEN" | "$HOME/.local/bin/gh" auth login --with-token >/dev/null 2>&1 \
      && log "gh authenticated (via GH_TOKEN)" || warn "GH_TOKEN rejected — check the token and re-run"
  elif ! "$HOME/.local/bin/gh" auth status >/dev/null 2>&1; then
    warn "gh is not authenticated — run 'gh auth login' in a terminal, or set GH_TOKEN and re-run"
  fi
fi

# -------------------------------------------------------------- shell setup --
# ~/.bashrc returns early for non-interactive shells ('[[ $- != *i* ]] && return'
# on line 6 of the Arch skeleton), so a block appended to it is invisible to
# 'ssh host cmd', 'bash -lc' and IDE-launched tools. Put the exports in one
# env file and source it from BOTH startup files: .bashrc covers interactive
# shells, .bash_profile covers every login shell, interactive or not.
log "Wiring environment into shell startup (JAVA_HOME + PATH)"
mkdir -p "$HOME/.config/dev-tools"
cat > "$HOME/.config/dev-tools/env.sh" <<'EOF'
# >>> dev-tools-managed >>>  (safe to delete; remove the two source lines too)
export JAVA_HOME="${JAVA_HOME:-$HOME/opt/jdk-27}"
case ":$PATH:" in
  *":$JAVA_HOME/bin:"*) ;;
  *) export PATH="$JAVA_HOME/bin:$HOME/.local/bin:$PATH" ;;
esac
# <<< dev-tools-managed <<<
EOF
python3 - <<'PY'
import os, re
pat  = re.compile(r'\n?# >>> dev-tools-managed >>>.*?# <<< dev-tools-managed <<<\n?', re.S)
block = '# >>> dev-tools-managed >>>\n. "$HOME/.config/dev-tools/env.sh"\n# <<< dev-tools-managed <<<'
for path in ('~/.bashrc', '~/.bash_profile'):
    p = os.path.expanduser(path)
    c = open(p).read() if os.path.exists(p) else ''
    c = pat.sub('', c).rstrip('\n')
    if c:
        c += '\n\n'
    open(p, 'w').write(c + block + '\n')
    print('    %s updated' % path)
PY

# fish, when it is the login shell, reads none of the above. conf.d/*.fish is the
# idiomatic drop-in; 'fish_add_path' is idempotent, and ~/.local/bin is already
# on fish's built-in default PATH, but re-adding it costs nothing.
if command -v fish >/dev/null 2>&1 || [ -d "$HOME/.config/fish" ]; then
  log "Wiring environment for fish (~/.config/fish/conf.d/dev-tools.fish)"
  mkdir -p "$HOME/.config/fish/conf.d"
  cat > "$HOME/.config/fish/conf.d/dev-tools.fish" <<'FISHEOF'
# >>> dev-tools-managed >>>  (delete this file to undo)
set -gx JAVA_HOME "$HOME/opt/jdk-27"
fish_add_path -gP "$JAVA_HOME/bin" "$HOME/.local/bin"
# <<< dev-tools-managed <<<
FISHEOF
fi

# zsh: ~/.zshenv is read by EVERY zsh invocation (interactive, login and script),
# whereas ~/.zshrc is interactive-only and ~/.zprofile login-only. One source
# line in .zshenv therefore covers all modes; zsh parses the POSIX env.sh fine.
if command -v zsh >/dev/null 2>&1 || [ -e "$HOME/.zshrc" ]; then
  log "Wiring environment for zsh (~/.zshenv)"
  python3 - <<'PY'
import os, re
path = os.path.expanduser('~/.zshenv')
pat  = re.compile(r'\n?# >>> dev-tools-managed >>>.*?# <<< dev-tools-managed <<<\n?', re.S)
block = '# >>> dev-tools-managed >>>\n. "$HOME/.config/dev-tools/env.sh"\n# <<< dev-tools-managed <<<'
c = open(path).read() if os.path.exists(path) else ''
c = pat.sub('', c).rstrip('\n')
if c:
    c += '\n\n'
open(path, 'w').write(c + block + '\n')
print('    %s updated' % path)
PY
fi

# ----------------------------------------------------------- verification ----
log "Verification (fresh bash login shell)"
env -i HOME="$HOME" TERM=xterm PATH=/usr/bin:/bin bash -lc '
  printf "%-11s %s\n" "java:"      "$(java -version 2>&1 | head -1)"
  printf "%-11s %s\n" "javac:"     "$(javac -version 2>&1)"
  printf "%-11s %s\n" "JAVA_HOME:" "$JAVA_HOME"
  printf "%-11s %s\n" "chrome:"    "$(google-chrome --version 2>&1)"
  printf "%-11s %s\n" "gh:"        "$(gh --version | head -1)"
  printf "%-11s %s\n" "git:"       "$(git --version)"
' || true
if command -v fish >/dev/null 2>&1; then
  log "Verification (fresh fish login shell)"
  env -i HOME="$HOME" TERM=xterm PATH=/usr/bin:/bin fish -l -c '
    # The type -q guards matter: without them fish prints a multi-line caret
    # diagram for a missing command inside a substitution, which reads like a crash.
    if type -q java
        echo "java:       "(java -version 2>&1 | head -1)
    else
        echo "java:       MISSING"
    end
    echo "JAVA_HOME:  "$JAVA_HOME
    if type -q google-chrome
        echo "chrome:     "(google-chrome --version)
    else
        echo "chrome:     MISSING"
    end
    if type -q gh
        echo "gh:         "(gh --version | head -1)
    else
        echo "gh:         MISSING"
    end
  ' 2>&1 || true
fi
if command -v zsh >/dev/null 2>&1; then
  log "Verification (fresh zsh login shell)"
  env -i HOME="$HOME" TERM=xterm PATH=/usr/bin:/bin zsh -lc '
    printf "%-11s %s\n" "java:"      "$(java -version 2>&1 | head -1)"
    printf "%-11s %s\n" "JAVA_HOME:" "$JAVA_HOME"
    printf "%-11s %s\n" "chrome:"    "$(google-chrome --version 2>&1)"
    printf "%-11s %s\n" "gh:"        "$(gh --version | head -1)"
  ' 2>&1 || true
fi
log "Manifest"
cat "$MANIFEST" 2>/dev/null || echo "    (empty — this run installed nothing)"
log "Done. Open a new terminal, or re-source this shell's file:"
echo "    fish: source ~/.config/fish/conf.d/dev-tools.fish"
echo "    bash: source ~/.bashrc      zsh: source ~/.zshenv"
