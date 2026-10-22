#!/usr/bin/env bash
# =============================================================================
# setup-claude-strata.sh
#
# Replicates the "Claude Code on a local model" stack on Ubuntu, pointed at a
# Strata server instead of Bionic/LM Studio.
#
#   Claude Code -> Strata /v1/messages   (nothing in between)
#
# Strata serves the Anthropic Messages API natively (verified: tool_use blocks,
# tool_result round-trips, SSE streaming, tolerant of Claude Code's extra
# params), so the LiteLLM + normalizer proxies the Bionic setup needed are gone.
#
# Claude Desktop's undocumented 3p gateway mode is the one place a proxy still
# helps (it needs an Anthropic-shaped /v1/models and can only send model names
# from the app's bundled catalog). --desktop installs the thin shim for it:
#
#   Claude Desktop -> strata-shim (:4001) -> Strata
#
# Usage:
#   ./setup-claude-strata.sh                 # install Claude Code + claude-strata
#   ./setup-claude-strata.sh --test          # ...and run an end-to-end prompt
#   ./setup-claude-strata.sh --write-settings # also write ~/.claude/settings.json
#   ./setup-claude-strata.sh --desktop       # also wire Claude Desktop 3p via the shim
#   ./setup-claude-strata.sh --fix-cowork-sandbox  # stop Claude Code's inner sandbox
#                                          # nesting inside Desktop's (otherwise
#                                          # every Bash tool call fails: seccomp)
#   ./setup-claude-strata.sh --remove        # remove everything this script wrote
#
# Configuration (environment variables):
#   STRATA_URL                server address      (default: http://127.0.0.1:47831)
#   STRATA_MODEL              model id as served  (default: discovered from /v1/models)
#   STRATA_KEY                bearer token        (default: strata-local; loopback, unchecked)
#   STRATA_CONTEXT            served context      (default: from the Strata tuning preset)
#   STRATA_MAX_OUTPUT_TOKENS  output cap          (default: 4096)
#   SHIM_PORT                 Desktop shim port   (default: 4001)
#   SHIM_THINKING             keep | off          (default: keep; off forces
#                                                  thinking disabled -> faster
#                                                  first text token, more budget
#                                                  for the answer itself)
#   DESKTOP_MODEL             catalog name for Desktop (default: claude-sonnet-4-6)
#
# Requires: Ubuntu 22.04+, curl, python3. No sudo needed (--desktop included);
# installing the Claude Desktop .deb itself is what needs sudo, see
# install-claude-desktop.sh.
# =============================================================================
set -euo pipefail

STRATA_URL="${STRATA_URL:-http://127.0.0.1:47831}"
STRATA_MODEL="${STRATA_MODEL:-}"
STRATA_KEY="${STRATA_KEY:-strata-local}"
STRATA_CONTEXT="${STRATA_CONTEXT:-}"
STRATA_MAX_OUTPUT_TOKENS="${STRATA_MAX_OUTPUT_TOKENS:-4096}"
SHIM_PORT="${SHIM_PORT:-4001}"
SHIM_THINKING="${SHIM_THINKING:-keep}"
case "$SHIM_THINKING" in keep|off) ;; *) echo "SHIM_THINKING must be 'keep' or 'off' (got '$SHIM_THINKING')" >&2; exit 2 ;; esac
DESKTOP_MODEL="${DESKTOP_MODEL:-claude-sonnet-4-6}"
DESKTOP_MODELS="${DESKTOP_MODELS:-claude-sonnet-4-6,claude-sonnet-4-5}"

BIN_DIR="$HOME/.local/bin"
CFG_DIR="$HOME/.config/claude-strata"
UNIT_DIR="$HOME/.config/systemd/user"
RUN_TEST=0
REMOVE=0
WITH_DESKTOP=0
WRITE_SETTINGS=0
FIX_SANDBOX=0
for arg in "$@"; do
  case "$arg" in
    --test)           RUN_TEST=1 ;;
    --remove)         REMOVE=1 ;;
    --desktop)        WITH_DESKTOP=1 ;;
    --write-settings) WRITE_SETTINGS=1 ;;
    --fix-cowork-sandbox) FIX_SANDBOX=1 ;;
    *) echo "Unknown option: $arg (expected --test, --remove, --desktop, --write-settings or --fix-cowork-sandbox)" >&2; exit 2 ;;
  esac
done

log() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }

# Claude Desktop 3p config lives here; the uuid file is our own so --remove can
# find and delete exactly what we wrote.
C3P_DIR="$HOME/.config/Claude-3p"
SETTINGS_JSON="$HOME/.claude/settings.json"

strip_v1() { local u="${1%/}"; printf '%s' "${u%/v1}"; }
api_root() { printf '%s' "$(strip_v1 "$STRATA_URL")"; }
health_url() { printf '%s/v1/models' "$(api_root)"; }

have_systemd() { command -v systemctl >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; }

# -----------------------------------------------------------------------------
if [ "$REMOVE" -eq 1 ]; then
  log "Removing claude-strata files (Claude Code itself is kept)"
  rm -f "$BIN_DIR/claude-strata"
  if [ -d "$CFG_DIR" ]; then
    rm -f "$CFG_DIR/claude-strata-shim.py"
    rmdir "$CFG_DIR" 2>/dev/null || true
  fi

  if have_systemd; then
    systemctl --user disable --now claude-strata-shim 2>/dev/null || true
    rm -f "$UNIT_DIR/claude-strata-shim.service"
    systemctl --user daemon-reload
  fi

  # Desktop launcher integration (only remove our own symlink).
  if [ -L "$BIN_DIR/claude-desktop" ] && [ "$(readlink "$BIN_DIR/claude-desktop")" = "claude-desktop-strata" ]; then
    rm -f "$BIN_DIR/claude-desktop"
  fi
  rm -f "$BIN_DIR/claude-desktop-strata" \
        "$HOME/.local/share/applications/com.anthropic.Claude.desktop"

  # Undo --write-settings: drop only env keys whose values are the ones we wrote.
  # A Strata model id never starts with "claude", so a real Anthropic id you set
  # yourself survives even when the setup probe cannot reach the server.
  if [ -f "$SETTINGS_JSON" ]; then
    python3 - "$SETTINGS_JSON" "$(api_root)" "$STRATA_KEY" "$(curl -s --max-time 3 "$(health_url)" 2>/dev/null || true)" <<'PY' || true
import json, re, sys
path, url, key, models_json = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    cfg = json.load(open(path))
except Exception:
    sys.exit(0)
env = cfg.get("env") or {}

live = set(re.findall(r'"id"\s*:\s*"([^"]+)"', models_json))
def ours_model(v):
    return isinstance(v, str) and bool(v) and (v in live or not v.lower().startswith("claude"))

removed = [k for k, v in (("ANTHROPIC_BASE_URL", url), ("ANTHROPIC_AUTH_TOKEN", key)) if env.get(k) == v]
removed += [k for k in ("ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
                        "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL")
            if ours_model(env.get(k))]
removed += [k for k in ("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "DISABLE_AUTOUPDATER", "DISABLE_TELEMETRY")
            if env.get(k) in ("1", 1)]
removed += [k for k in ("CLAUDE_CODE_MAX_CONTEXT_TOKENS", "CLAUDE_CODE_MAX_OUTPUT_TOKENS")
            if str(env.get(k, "")).isdigit()]
for k in removed:
    env.pop(k, None)
if not env:
    cfg.pop("env", None)
json.dump(cfg, open(path, "w"), indent=2)
print("cleaned %d key(s) from %s%s" % (len(removed), path,
      "" if removed else " (none of ours found; your own env left untouched)"))
PY
  fi

  # Undo --fix-cowork-sandbox: drop the sandbox key only if it is exactly ours.
  if [ -f "$SETTINGS_JSON" ]; then
    python3 - "$SETTINGS_JSON" <<'PY' || true
import json, sys
path = sys.argv[1]
try:
    cfg = json.load(open(path))
except Exception:
    sys.exit(0)
if isinstance(cfg, dict) and cfg.get("sandbox") == {"enabled": False}:
    del cfg["sandbox"]
    json.dump(cfg, open(path, "w"), indent=2)
    print("restored sandbox default in", path)
PY
  fi

  # Undo --desktop: delete the configLibrary entries we recognize (our
  # labelOverride is the marker) + revert deploymentMode if nothing of ours is left.
  if [ -d "$C3P_DIR/configLibrary" ]; then
    python3 - "$C3P_DIR" "$SHIM_PORT" <<'PY' || true
import json, os, sys
c3p, port = sys.argv[1], sys.argv[2]
lib = os.path.join(c3p, "configLibrary")
meta_p = os.path.join(lib, "_meta.json")
try:
    meta = json.load(open(meta_p))
except Exception:
    sys.exit(0)
changed = False
for eid in [e.get("id") for e in meta.get("entries", []) if isinstance(e, dict)]:
    p = os.path.join(lib, "%s.json" % eid)
    try:
        d = json.load(open(p))
    except Exception:
        continue
    ours = (d.get("inferenceProvider") == "gateway"
            and str(d.get("inferenceGatewayBaseUrl", "")).rstrip("/").endswith("://localhost:%s" % port)
            and any(isinstance(m, dict) and m.get("labelOverride") == "Strata (local)"
                    for m in (d.get("inferenceModels") or [{}])))
    if not ours:
        print("kept %s (not written by this script)" % p)
        continue
    os.remove(p)
    meta["entries"] = [e for e in meta.get("entries", []) if e.get("id") != eid]
    if meta.get("appliedId") == eid:
        meta["appliedId"] = None
    changed = True
    print("removed", p)
if changed:
    json.dump(meta, open(meta_p, "w"), indent=2)
    cfg_p = os.path.join(c3p, "claude_desktop_config.json")
    try:
        cfg = json.load(open(cfg_p))
        if cfg.get("deploymentMode") == "3p" and not meta.get("entries"):
            cfg.pop("deploymentMode", None)
            json.dump(cfg, open(cfg_p, "w"), indent=2)
            print("reverted deploymentMode in", cfg_p)
    except Exception:
        pass
PY
  fi

  echo "Removed: $BIN_DIR/claude-strata, $CFG_DIR/, the shim unit, the Claude Desktop"
  echo "launcher integration, and any --desktop / --write-settings entries we added."
  exit 0
fi

# -----------------------------------------------------------------------------
log "1/5 Checking prerequisites + the Strata server"
missing=()
command -v curl    >/dev/null 2>&1 || missing+=(curl)
command -v python3 >/dev/null 2>&1 || missing+=(python3)
if [ "${#missing[@]}" -gt 0 ]; then
  echo "Missing: ${missing[*]}. Install with:" >&2
  echo "  sudo apt update && sudo apt install -y ${missing[*]}" >&2
  exit 1
fi

MODELS_JSON=$(curl -s --max-time 5 "$(health_url)" 2>/dev/null || true)
if [ -z "$MODELS_JSON" ]; then
  echo "No Strata server answering at $(api_root)" >&2
  echo "Start one first:" >&2
  echo "  strata launch                       # guided screens, then the monitor" >&2
  echo "  strata runtime start --preset NAME  # background service" >&2
  echo "or re-run with the right address:  STRATA_URL=http://127.0.0.1:8080 $0" >&2
  exit 1
fi

if [ -z "$STRATA_MODEL" ]; then
  STRATA_MODEL=$(printf '%s' "$MODELS_JSON" | tr ',' '\n' \
    | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
fi
[ -n "$STRATA_MODEL" ] || { echo "Could not read a model id from $(health_url): $MODELS_JSON" >&2; exit 1; }

# Served context: an explicit value wins, then the active Strata tuning preset.
if [ -z "$STRATA_CONTEXT" ]; then
  STRATA_CONTEXT=$(python3 - <<'PY'
import json, os
base = os.path.expanduser("~/.config/strata/presets")
best = 0
try:
    for inst, v in json.load(open(os.path.join(base, "active.json"))).items():
        aid = v.get("active")
        if not aid:
            continue
        ctx = json.load(open(os.path.join(base, "%s.json" % aid))).get("choices", {}).get("context")
        if isinstance(ctx, int) and ctx > best:
            best = ctx
except Exception:
    pass
print(best or 32768)
PY
)
  CTX_SOURCE="Strata preset (fallback 32768)"
else
  CTX_SOURCE="STRATA_CONTEXT"
fi

# The model id is the one thing that must match the server exactly.
if ! curl -s --max-time 60 "$(api_root)/v1/messages" -H 'content-type: application/json' \
      -H "authorization: Bearer $STRATA_KEY" -H 'anthropic-version: 2023-06-01' \
      -d "{\"model\":\"$STRATA_MODEL\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}]}" \
      | grep -q '"type": *"message"'; then
  echo "Strata answered $(api_root)/v1/messages but not with an Anthropic message." >&2
  echo "Check the model id: strata connect claude-code --url $(api_root) --show-key" >&2
  exit 1
fi

echo "Strata:   $(api_root)"
echo "Model:    $STRATA_MODEL"
echo "Context:  $STRATA_CONTEXT ($CTX_SOURCE)"
echo "Probe:    /v1/messages OK (prompt accepted)"

# -----------------------------------------------------------------------------
log "2/5 Installing Claude Code (native installer)"
if command -v claude >/dev/null 2>&1 || [ -x "$BIN_DIR/claude" ]; then
  echo "Already installed: $(command -v claude || echo "$BIN_DIR/claude")"
else
  curl -fsSL https://claude.ai/install.sh | bash
fi
[ -x "$BIN_DIR/claude" ] || { echo "ERROR: $BIN_DIR/claude not found after install" >&2; exit 1; }
echo "Claude Code $($BIN_DIR/claude --version 2>/dev/null | head -1)"

if ! grep -qs 'export PATH="$HOME/.local/bin' "$HOME/.bashrc" 2>/dev/null; then
  echo '' >> "$HOME/.bashrc"
  echo '# Added by setup-claude-strata.sh: user-installed binaries (claude)' >> "$HOME/.bashrc"
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
  echo "Added ~/.local/bin to PATH in ~/.bashrc (open a new shell or run: source ~/.bashrc)"
fi

# -----------------------------------------------------------------------------
log "3/5 Writing the claude-strata wrapper"
mkdir -p "$BIN_DIR" "$CFG_DIR"
cat > "$BIN_DIR/claude-strata" <<'WRAPPEOF'
#!/usr/bin/env bash
# Run Claude Code against the local Strata server (generated by
# setup-claude-strata.sh). Chain: Claude Code -> Strata /v1/messages, no proxy.
#
# Usage: claude-strata [CONTEXT] [claude args...]
#   CONTEXT  optional context window for auto-compact:
#              "135k" / "256k"  -> k = x1024, m = x1024^2
#              or an exact token count >= 1024, e.g. 131072
#              (default: the context Strata was started with)
#
# Overrides: STRATA_URL, STRATA_MODEL, STRATA_KEY, STRATA_CONTEXT,
#            STRATA_MAX_OUTPUT_TOKENS
set -uo pipefail

STRATA_URL="${STRATA_URL:-__URL__}"
STRATA_KEY="${STRATA_KEY:-__KEY__}"
STRATA_MODEL="${STRATA_MODEL:-}"
DEFAULT_CTX=__CTX__
MAX_OUTPUT="${STRATA_MAX_OUTPUT_TOKENS:-__MAXOUT__}"

# Claude Code appends /v1/messages itself, so the base must not end in /v1.
STRATA_URL="${STRATA_URL%/}"
STRATA_URL="${STRATA_URL%/v1}"

CTX_TOKENS=$DEFAULT_CTX
if [[ $# -gt 0 && $1 =~ ^([0-9]+)([kmKM])?$ ]]; then
  num=${BASH_REMATCH[1]}
  suffix=${BASH_REMATCH[2]:-}
  if [[ -n $suffix ]]; then
    case "${suffix,,}" in
      k) CTX_TOKENS=$((num * 1024)) ;;
      m) CTX_TOKENS=$((num * 1024 * 1024)) ;;
    esac
    shift
  elif (( num >= 1024 )); then
    CTX_TOKENS=$num   # bare number = exact token count (small numbers go to claude)
    shift
  fi
fi

# Ask the server which model it actually has loaded: survives model swaps in
# the Strata app, where an id baked in at setup time would 400.
MODEL=$STRATA_MODEL
if [[ -z $MODEL ]]; then
  BODY=$(curl -s --max-time 3 "$STRATA_URL/v1/models" 2>/dev/null || true)
  if [[ -z $BODY ]]; then
    echo "claude-strata: no Strata server at $STRATA_URL" >&2
    echo "  start it:  strata launch              (guided, with the monitor)" >&2
    echo "             strata runtime start ...   (background service)" >&2
    echo "  or point me at it: STRATA_URL=http://127.0.0.1:8080 claude-strata" >&2
    exit 1
  fi
  MODEL=$(printf '%s' "$BODY" | tr ',' '\n' \
    | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
fi
if [[ -z $MODEL ]]; then
  echo "claude-strata: could not read a model id from $STRATA_URL/v1/models" >&2
  exit 1
fi

export ANTHROPIC_BASE_URL="$STRATA_URL"
export ANTHROPIC_AUTH_TOKEN="$STRATA_KEY"
export ANTHROPIC_MODEL="$MODEL"
export ANTHROPIC_SMALL_FAST_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export DISABLE_AUTOUPDATER=1
export DISABLE_TELEMETRY=1
export CLAUDE_CODE_MAX_CONTEXT_TOKENS=$CTX_TOKENS
export CLAUDE_CODE_MAX_OUTPUT_TOKENS=$MAX_OUTPUT

exec claude --model "$MODEL" "$@"
WRAPPEOF
sed -i "s|__URL__|$(api_root)|g; s|__KEY__|$STRATA_KEY|g; s|__CTX__|$STRATA_CONTEXT|g; s|__MAXOUT__|$STRATA_MAX_OUTPUT_TOKENS|g" "$BIN_DIR/claude-strata"
chmod +x "$BIN_DIR/claude-strata"
echo "Wrote $BIN_DIR/claude-strata (model auto-detected at launch, default ${STRATA_CONTEXT} token window)"

# -----------------------------------------------------------------------------
log "4/5 App configuration"
if [ "$WRITE_SETTINGS" -eq 1 ]; then
  mkdir -p "$(dirname "$SETTINGS_JSON")"
  python3 - "$SETTINGS_JSON" "$(api_root)" "$STRATA_MODEL" "$STRATA_KEY" "$STRATA_CONTEXT" "$STRATA_MAX_OUTPUT_TOKENS" <<'PY'
import json, os, shutil, sys
path, url, model, key, ctx, max_out = sys.argv[1:7]
cfg = {}
if os.path.exists(path):
    try:
        cfg = json.load(open(path))
    except Exception as exc:
        shutil.copy2(path, path + ".bak")
        print("existing %s is not valid JSON; backed up to %s.bak and starting fresh" % (path, path))
        cfg = {}
env = cfg.setdefault("env", {})
env.update({
    "ANTHROPIC_BASE_URL": url,               # no /v1: Claude Code adds /v1/messages
    "ANTHROPIC_AUTH_TOKEN": key,
    "ANTHROPIC_MODEL": model,
    "ANTHROPIC_SMALL_FAST_MODEL": model,
    "ANTHROPIC_DEFAULT_SONNET_MODEL": model,
    "ANTHROPIC_DEFAULT_OPUS_MODEL": model,
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": model,
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "DISABLE_AUTOUPDATER": "1",
    "DISABLE_TELEMETRY": "1",
    "CLAUDE_CODE_MAX_CONTEXT_TOKENS": str(ctx),
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS": str(max_out),
})
json.dump(cfg, open(path, "w"), indent=2)
print("Wrote %s -> %s (%s)" % (path, url, model))
PY
else
  echo "Skipped ~/.claude/settings.json (pass --write-settings to make Strata the"
  echo "default for every 'claude' launch; the claude-strata wrapper needs neither)."
fi

if [ "$FIX_SANDBOX" -eq 1 ]; then
  # Claude Desktop already runs the CLI inside a user namespace, so Claude Code's
  # own bubblewrap sandbox cannot nest another one. The kernel refuses it and
  # every Bash tool call dies before it runs:
  #   apply-seccomp: write /proc/self/setgroups (nested userns is
  #   capability-restricted; caller must provide CAP_SYS_ADMIN): Permission denied
  # The model retries, then gives up and ends the turn - which looks like replies
  # stopping half-finished. Drop the inner sandbox; Desktop's outer one stays.
  mkdir -p "$(dirname "$SETTINGS_JSON")"
  python3 - "$SETTINGS_JSON" <<'PY'
import json, os, shutil, sys
path = sys.argv[1]
cfg = {}
if os.path.exists(path):
    try:
        cfg = json.load(open(path))
    except Exception:
        shutil.copy2(path, path + ".bak")
        print("existing %s is not valid JSON; backed up to %s.bak" % (path, path))
        cfg = {}
if not isinstance(cfg, dict):
    cfg = {}
sb = cfg.get("sandbox")
if not isinstance(sb, dict):
    sb = {}
    cfg["sandbox"] = sb
sb["enabled"] = False
json.dump(cfg, open(path, "w"), indent=2)
print("Wrote %s -> sandbox.enabled = false" % path)
print("(Desktop still sandboxes the CLI itself, so commands are not running bare.)")
PY
else
  echo "Skipped the Cowork sandbox fix (use --fix-cowork-sandbox if Desktop turns"
  echo "shell commands into 'apply-seccomp: ... Permission denied')."
fi

if [ "$WITH_DESKTOP" -eq 1 ]; then
  cp -f "$(dirname "$(readlink -f "$0")")/claude-strata-shim.py" "$CFG_DIR/claude-strata-shim.py"
  echo "Wrote $CFG_DIR/claude-strata-shim.py (Desktop shim -> $(api_root))"

  if have_systemd; then
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/claude-strata-shim.service" <<EOF
[Unit]
Description=Claude Desktop 3p shim -> Strata (port $SHIM_PORT)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 %h/.config/claude-strata/claude-strata-shim.py --port $SHIM_PORT --upstream $(api_root) --models $DESKTOP_MODELS --thinking $SHIM_THINKING
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    echo "Wrote $UNIT_DIR/claude-strata-shim.service"
  else
    echo "No systemd user session here; the Desktop launcher below starts the shim"
    echo "with nohup instead."
  fi

  # Launcher: bring the shim up before Desktop, stop it when the last window exits.
  # Resolve the REAL Claude Desktop binary. Never accept ~/.local/bin/claude-desktop:
  # that is our own symlink to this wrapper, and launching it recurses forever.
  SELF_RESOLVED=$(readlink -f "$BIN_DIR/claude-desktop-strata" 2>/dev/null \
                  || printf '%s' "$BIN_DIR/claude-desktop-strata")
  DESKTOP_REAL=""
  for cand in /usr/bin/claude-desktop /usr/lib/claude-desktop/claude-desktop \
              "$(command -v claude-desktop 2>/dev/null || true)"; do
    [ -n "$cand" ] && [ -x "$cand" ] || continue
    case "$cand" in "$BIN_DIR"/*|*claude-desktop-strata) continue ;; esac
    res=$(readlink -f "$cand" 2>/dev/null || printf '%s' "$cand")
    [ "$res" = "$SELF_RESOLVED" ] && continue
    DESKTOP_REAL="$cand"
    break
  done
  [ -n "$DESKTOP_REAL" ] || DESKTOP_REAL="/usr/bin/claude-desktop"
  echo "Launcher target: $DESKTOP_REAL"

  cat > "$BIN_DIR/claude-desktop-strata" <<'DESKWRAPPEOF'
#!/usr/bin/env bash
# Launch Claude Desktop with the Strata shim (:4001) running behind it.
# Starts the shim, waits for health, launches Claude Desktop, and stops the shim
# again when the last Desktop instance exits. Log: ~/claude-desktop-strata.log
set -u

SHIM_PORT=__SHIM_PORT__
SHIM_UPSTREAM="__SHIM_UPSTREAM__"
DESKTOP_MODELS="__DESKTOP_MODELS__"
SHIM_THINKING="__THINKING__"
SHIM_SERVICE=claude-strata-shim
DESKTOP_BIN="${CLAUDE_DESKTOP_BIN:-__DESKTOP_BIN__}"
LOG="$HOME/claude-desktop-strata.log"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >&2; }

# Never let a repeated failure grow the log without bound.
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  : > "$LOG"
fi

# --- never launch ourselves ---------------------------------------------------
# A past build resolved DESKTOP_BIN to ~/.local/bin/claude-desktop, a symlink
# back to this script: every level re-launched the wrapper, forking forever and
# stopping the shim as each level unwound. Repair the target, then refuse it.
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
resolve() { readlink -f "$1" 2>/dev/null || printf '%s' "$1"; }
if [ "$(resolve "$DESKTOP_BIN")" = "$SELF" ]; then
  for cand in /usr/bin/claude-desktop /usr/lib/claude-desktop/claude-desktop; do
    [ -x "$cand" ] || continue
    [ "$(resolve "$cand")" = "$SELF" ] && continue
    log "Repairing self-referencing target: $DESKTOP_BIN -> $cand"
    DESKTOP_BIN="$cand"
    break
  done
fi
if [ "$(resolve "$DESKTOP_BIN")" = "$SELF" ]; then
  log "ERROR: Claude Desktop binary not found (target would launch itself: $DESKTOP_BIN)."
  log "       Install it with install-claude-desktop.sh, or export CLAUDE_DESKTOP_BIN=/path/to/claude-desktop."
  exit 1
fi
if [ -n "${CLAUDE_DESKTOP_STRATA_ACTIVE:-}" ]; then
  # Another instance already owns the shim lifecycle; just hand off.
  exec "$DESKTOP_BIN" "$@"
fi

have_systemd=0
if command -v systemctl >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
  have_systemd=1
fi
up() { curl -s --max-time 3 "$1" >/dev/null 2>&1; }
wait_for() { for _ in $(seq 1 "$2"); do sleep 1; up "$1" && return 0; done; return 1; }
desktop_running() {
  # Match the executable, not the command line: `pgrep -f` also hits shells or
  # editors that merely mention the path, which used to keep the shim alive.
  # Electron helpers share the same exe and comm, so they count as "running".
  local target pid
  target="$(resolve "$DESKTOP_BIN")"
  for pid in $(pgrep -x "$(basename "$DESKTOP_BIN")" 2>/dev/null); do
    [ "$(readlink -f "/proc/$pid/exe" 2>/dev/null)" = "$target" ] && return 0
  done
  return 1
}

started_shim=0
if ! up "http://localhost:$SHIM_PORT/healthz"; then
  started_shim=1
  if [ "$have_systemd" -eq 1 ]; then
    log "Starting the Strata shim (systemd user service)..."
    systemctl --user start "$SHIM_SERVICE" 2>>"$LOG" || true
  else
    log "No systemd user session - starting the shim via nohup..."
    nohup /usr/bin/python3 "$HOME/.config/claude-strata/claude-strata-shim.py" \
      --port "$SHIM_PORT" --upstream "$SHIM_UPSTREAM" --models "$DESKTOP_MODELS" --thinking "$SHIM_THINKING" \
      >> ~/claude-strata-shim.log 2>&1 &
  fi
fi
if up "http://localhost:$SHIM_PORT/healthz"; then
  log "Shim ready :$SHIM_PORT -> $SHIM_UPSTREAM. Launching Claude Desktop ($DESKTOP_BIN)..."
elif wait_for "http://localhost:$SHIM_PORT/healthz" 20; then
  log "Shim ready :$SHIM_PORT. Launching Claude Desktop ($DESKTOP_BIN)..."
else
  started_shim=0
  log "WARNING: shim :$SHIM_PORT did not come up (see ~/claude-strata-shim.log) - launching anyway."
fi

export CLAUDE_DESKTOP_STRATA_ACTIVE=1
"$DESKTOP_BIN" "$@" &
child=$!
cleanup() {
  # Electron helpers (zygote, gpu-process) linger a few seconds after the main
  # process, and a second instance keeps needing the shim: wait, then decide.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    desktop_running || break
    sleep 1
  done
  if desktop_running; then
    log "A Claude Desktop instance is still running - leaving the shim up."
  elif [ "$started_shim" -eq 1 ] && [ "$have_systemd" -eq 1 ]; then
    log "Claude Desktop exited - stopping the shim."
    systemctl --user stop "$SHIM_SERVICE" 2>>"$LOG" || true
  fi
}
trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; cleanup; exit 130' INT
trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; cleanup; exit 143' TERM
wait "$child"; rc=$?
cleanup
exit $rc
DESKWRAPPEOF
  sed -i "s|__SHIM_PORT__|$SHIM_PORT|g; s|__SHIM_UPSTREAM__|$(api_root)|g; s|__DESKTOP_MODELS__|$DESKTOP_MODELS|g; s|__THINKING__|$SHIM_THINKING|g; s|__DESKTOP_BIN__|$DESKTOP_REAL|g" "$BIN_DIR/claude-desktop-strata"
  chmod +x "$BIN_DIR/claude-desktop-strata"
  ln -sfn claude-desktop-strata "$BIN_DIR/claude-desktop"
  echo "Wrote $BIN_DIR/claude-desktop-strata (+ claude-desktop -> it)"

  DESKTOP_OVERRIDE="$HOME/.local/share/applications/com.anthropic.Claude.desktop"
  mkdir -p "$(dirname "$DESKTOP_OVERRIDE")"
  cat > "$DESKTOP_OVERRIDE" <<EOF
[Desktop Entry]
Name=Claude
Comment=Desktop application for Claude.ai (routes to the local Strata server)
GenericName=AI Assistant
Keywords=AI;Chat;Assistant;Claude;Code;LLM;
Exec=$BIN_DIR/claude-desktop-strata %U
Icon=claude-desktop
Type=Application
StartupNotify=true
StartupWMClass=com.anthropic.Claude
SingleMainWindow=true
Categories=Utility;Development;
MimeType=x-scheme-handler/claude;
Actions=NewChat;NewCode;

[Desktop Action NewChat]
Name=New Chat
Exec=$BIN_DIR/claude-desktop-strata "claude://claude.ai/new?surface=chat&source=desktop_action"

[Desktop Action NewCode]
Name=New Claude Code Session
Exec=$BIN_DIR/claude-desktop-strata "claude://code/new?source=desktop_action"
EOF
  echo "Wrote $DESKTOP_OVERRIDE (app menu launches through the shim)"

  # The 3p gateway config: model names must exist in the app's bundled catalog,
  # so we advertise catalog names and let the shim map them to the loaded id.
  python3 - "$C3P_DIR" "$SHIM_PORT" "$STRATA_KEY" "$DESKTOP_MODEL" <<'PY'
import json, os, sys, uuid
c3p, port, key, model = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
lib = os.path.join(c3p, "configLibrary")
os.makedirs(lib, exist_ok=True)

cfg_p = os.path.join(c3p, "claude_desktop_config.json")
cfg = {}
if os.path.exists(cfg_p):
    try:
        cfg = json.load(open(cfg_p))
    except Exception:
        cfg = {}
cfg["deploymentMode"] = "3p"
json.dump(cfg, open(cfg_p, "w"), indent=2)
print("Wrote", cfg_p, "(deploymentMode: 3p)")

def is_ours(d):
    return (isinstance(d, dict) and d.get("inferenceProvider") == "gateway"
            and str(d.get("inferenceGatewayBaseUrl", "")).rstrip("/").endswith("://localhost:%s" % port)
            and any(isinstance(m, dict) and m.get("labelOverride") == "Strata (local)"
                    for m in (d.get("inferenceModels") or [{}])))

meta_p = os.path.join(lib, "_meta.json")
try:
    meta = json.load(open(meta_p))
    if not isinstance(meta, dict):
        raise ValueError
except Exception:
    meta = {"appliedId": None, "entries": []}

# Drop entries we wrote on an earlier run (marker: our labelOverride on this
# port), so re-running --desktop replaces instead of piling up gateways.
kept = []
for e in meta.get("entries", []):
    if not isinstance(e, dict) or not e.get("id"):
        continue
    p = os.path.join(lib, "%s.json" % e["id"])
    try:
        prev = json.load(open(p))
    except Exception:
        prev = None
    if prev is not None and is_ours(prev):
        os.remove(p)
        print("replaced earlier entry", e["id"])
        continue
    kept.append(e)
meta["entries"] = kept

# Deterministic id: re-runs land on the same file instead of minting a new one.
entry_id = str(uuid.uuid5(uuid.NAMESPACE_URL, "claude-strata://localhost:%s/%s" % (port, model)))
entry = {
    "inferenceProvider": "gateway",
    "inferenceCredentialKind": "static",
    "inferenceGatewayApiKey": key,
    "inferenceGatewayAuthScheme": "bearer",
    "inferenceGatewayBaseUrl": "http://localhost:%s/" % port,
    "inferenceModels": [{"name": model, "labelOverride": "Strata (local)"}],
}
json.dump(entry, open(os.path.join(lib, entry_id + ".json"), "w"), indent=2)

meta["entries"] = [e for e in meta["entries"] if e.get("id") != entry_id]
meta["entries"].append({"id": entry_id, "name": model})
meta["appliedId"] = entry_id
json.dump(meta, open(meta_p, "w"), indent=2)
print("Wrote", os.path.join(lib, entry_id + ".json"), "and", meta_p)
print("configLibrary id:", entry_id)
PY

  if have_systemd; then
    systemctl --user disable claude-strata-shim 2>/dev/null || true
    systemctl --user restart claude-strata-shim 2>/dev/null || true
  fi
  echo "Fully quit Claude Desktop (tray -> Quit) and relaunch it through the app"
  echo "menu or 'claude-desktop'; pick '$DESKTOP_MODEL'."
else
  echo "Skipped Claude Desktop wiring (pass --desktop to configure the 3p gateway)."
fi

# -----------------------------------------------------------------------------
log "5/5 Verifying"
ok=1
curl -s --max-time 5 "$(health_url)" >/dev/null 2>&1 \
  && echo "Strata        $(api_root) ... OK ($STRATA_MODEL)" \
  || { echo "Strata        $(api_root) ... FAILED" >&2; ok=0; }
[ -x "$BIN_DIR/claude-strata" ] && echo "Wrapper       $BIN_DIR/claude-strata ... OK" \
  || { echo "Wrapper missing" >&2; ok=0; }

if [ "$WITH_DESKTOP" -eq 1 ]; then
  if curl -s --max-time 3 "http://localhost:$SHIM_PORT/healthz" >/dev/null 2>&1; then
    echo "Desktop shim  :$SHIM_PORT ... OK"
    curl -s --max-time 3 "http://localhost:$SHIM_PORT/v1/models" | head -c 200; echo
  else
    echo "Desktop shim  :$SHIM_PORT ... not running (the Desktop launcher starts it on demand)"
  fi
fi

if [ "$ok" -eq 1 ] && [ "$RUN_TEST" -eq 1 ]; then
  log "End-to-end test: claude-strata -p 'Reply with exactly: OK'"
  "$BIN_DIR/claude-strata" -p "Reply with exactly: OK" 2>&1 | tail -3 || true
fi

echo
if [ "$ok" -eq 1 ]; then
  echo "Setup complete. Usage:"
  echo "  claude-strata                    # interactive Claude Code on Strata"
  echo "  claude-strata 135k               # ...with a 135k window (default: $STRATA_CONTEXT)"
  echo "  claude-strata -p 'your prompt'   # one-shot / headless"
else
  echo "Setup finished with errors - check the messages above." >&2
  exit 1
fi
