#!/usr/bin/env bash
# =============================================================================
# setup-claude-local.sh
#
# Replicates the "Claude Code on local models" stack on a fresh Ubuntu machine.
#
#   Claude Code -> normalizer (:4001) -> LiteLLM (:4000) -> your model server
#
# The model server must speak the OpenAI-compatible API (/v1/chat/completions,
# /v1/models): LM Studio, Bionic, llama.cpp's llama-server, vLLM, etc.
#
# Usage:
#   ./setup-claude-local.sh                 # install with defaults below
#   ./setup-claude-local.sh --test          # ...and run an end-to-end prompt
#   ./setup-claude-local.sh --remove        # disable services + delete files
#
# Configuration (environment variables):
#   API_BASE      OpenAI-compatible base URL   (default: http://localhost:1234/v1)
#   MODEL_ID      model id as served there     (default: qwen3.8-27b@q4_k_xl)
#   FRIENDLY_NAME name Claude Code uses        (default: qwen3-8-27b)
#
# Example for a different model / server:
#   API_BASE=http://localhost:8080/v1 MODEL_ID=llama-3.1-8b-instruct \
#   FRIENDLY_NAME=llama31 ./setup-claude-local.sh --test
#
# Requires: Ubuntu 22.04+, curl, python3 (>=3.9), pip. No sudo needed.
# =============================================================================
set -euo pipefail

API_BASE="${API_BASE:-http://localhost:1234/v1}"
MODEL_ID="${MODEL_ID:-qwen3.8-27b@q4_k_xl}"
FRIENDLY_NAME="${FRIENDLY_NAME:-qwen3-8-27b}"
LITELLM_PORT=4000
NORMALIZER_PORT=4001

CFG_DIR="$HOME/.config/litellm"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
RUN_TEST=0
REMOVE=0
for arg in "$@"; do
  case "$arg" in
    --test)   RUN_TEST=1 ;;
    --remove) REMOVE=1 ;;
    *) echo "Unknown option: $arg (expected --test or --remove)" >&2; exit 2 ;;
  esac
done

log() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }

# -----------------------------------------------------------------------------
if [ "$REMOVE" -eq 1 ]; then
  log "Removing claude-local stack (packages are kept)"
  if command -v systemctl >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
    systemctl --user disable --now litellm-bionic claude-normalizer 2>/dev/null || true
    rm -f "$UNIT_DIR/litellm-bionic.service" "$UNIT_DIR/claude-normalizer.service"
    systemctl --user daemon-reload
  fi
  rm -f "$CFG_DIR/config.yaml" \
        "$CFG_DIR/claude-bionic-normalizer.py" \
        "$BIN_DIR/claude-local"
  echo "Removed: $CFG_DIR/{config.yaml,claude-bionic-normalizer.py}, $BIN_DIR/claude-local, systemd units."
  echo "(Claude Code itself and LiteLLM packages were left in place.)"
  exit 0
fi

# -----------------------------------------------------------------------------
log "1/6 Checking prerequisites"
missing=()
command -v curl    >/dev/null 2>&1 || missing+=(curl)
command -v python3 >/dev/null 2>&1 || missing+=(python3)
if [ "${#missing[@]}" -gt 0 ]; then
  echo "Missing: ${missing[*]}. Install with:" >&2
  echo "  sudo apt update && sudo apt install -y ${missing[*]}" >&2
  exit 1
fi
python3 -m pip --version >/dev/null 2>&1 || {
  echo "pip is missing. Install with: sudo apt install -y python3-pip" >&2; exit 1; }
PYVER=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
echo "OK: curl, python3 ($PYVER), pip"

# -----------------------------------------------------------------------------
log "2/6 Installing Claude Code (native installer)"
if command -v claude >/dev/null 2>&1 || [ -x "$BIN_DIR/claude" ]; then
  echo "Already installed: $(command -v claude || echo "$BIN_DIR/claude")"
else
  curl -fsSL https://claude.ai/install.sh | bash
fi
[ -x "$BIN_DIR/claude" ] || { echo "ERROR: $BIN_DIR/claude not found after install" >&2; exit 1; }
echo "Claude Code $($BIN_DIR/claude --version 2>/dev/null | head -1)"

# Make sure ~/.local/bin is on PATH in new shells.
if ! grep -qs 'export PATH="$HOME/.local/bin' "$HOME/.bashrc" 2>/dev/null; then
  echo '' >> "$HOME/.bashrc"
  echo '# Added by setup-claude-local.sh: user-installed binaries (claude, litellm)' >> "$HOME/.bashrc"
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
  echo "Added ~/.local/bin to PATH in ~/.bashrc (open a new shell or run: source ~/.bashrc)"
fi

# -----------------------------------------------------------------------------
log "3/6 Installing LiteLLM proxy (pip, user site)"
PIP_FLAGS=(--user)
if python3 -c 'import os,sysconfig; raise SystemExit(0 if os.path.exists(os.path.join(sysconfig.get_path("stdlib"),"EXTERNALLY-MANAGED")) else 1)'; then
  # Ubuntu 23.04+/24.04+: PEP 668 externally-managed environment
  PIP_FLAGS+=(--break-system-packages)
fi
python3 -m pip install "${PIP_FLAGS[@]}" --quiet 'litellm[proxy]'
[ -x "$BIN_DIR/litellm" ] || { echo "ERROR: $BIN_DIR/litellm not found after pip install" >&2; exit 1; }
LITELLM_VER=$("$BIN_DIR/litellm" --version 2>/dev/null | grep -i 'version' | head -1 || true)
echo "LiteLLM installed: ${LITELLM_VER:-unknown}"

# -----------------------------------------------------------------------------
log "4/6 Writing config, normalizer and claude-local wrapper"
mkdir -p "$CFG_DIR" "$BIN_DIR"

cat > "$CFG_DIR/config.yaml" <<EOF
model_list:
  - model_name: $FRIENDLY_NAME
    litellm_params:
      model: openai/$MODEL_ID
      api_base: $API_BASE
      api_key: local-bridge
EOF
echo "Wrote $CFG_DIR/config.yaml (model '$FRIENDLY_NAME' -> $MODEL_ID @ $API_BASE)"

cat > "$CFG_DIR/claude-bionic-normalizer.py" <<'PYEOF'
#!/usr/bin/env python3
"""
Anthropic /v1/messages normalizer for Claude Code -> local OpenAI-compatible models.

Claude Code (>= 2.1) sends "mid-conversation system" messages: role=system
items *inside* the messages array, after user turns. Qwen-family chat
templates (used by llama-server in LM Studio / Bionic) require a single system
message at position 0 and reject anything else with:

    Jinja Exception: System message must be at the beginning.

This proxy sits in front of LiteLLM and rewrites each /v1/messages request:
  * collects every role=system item from messages[] (string or text blocks)
  * merges them with the top-level `system` field into ONE plain string
  * puts that string back as the top-level `system` field

Everything else (tools, thinking, streaming, headers) is passed through
untouched; responses are streamed back byte-for-byte.

Usage:  python3 claude-bionic-normalizer.py [--port 4001] [--upstream http://localhost:4000]
"""

import argparse
import json
import sys
from urllib.parse import urlsplit
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def _system_text(content) -> str:
    """Extract plain text from an Anthropic system field (str or block list)."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                text = block.get("text", "")
                if text:
                    parts.append(text)
        return "\n\n".join(parts)
    return ""


def normalize(body: bytes) -> bytes:
    """Merge mid-conversation system messages into a single leading system."""
    data = json.loads(body)
    messages = data.get("messages")
    if not isinstance(messages, list):
        return body

    extra_systems = []
    kept_messages = []
    for msg in messages:
        if isinstance(msg, dict) and msg.get("role") == "system":
            text = _system_text(msg.get("content"))
            if text:
                extra_systems.append(text)
        else:
            kept_messages.append(msg)

    top_system = _system_text(data.get("system"))
    merged = [t for t in [top_system, *extra_systems] if t]

    # Nothing to do: no system content anywhere.
    if not merged and not extra_systems:
        return body

    data["messages"] = kept_messages
    data["system"] = "\n\n".join(merged)
    return json.dumps(data, ensure_ascii=False).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    upstream_host = "localhost"
    upstream_port = 4000

    def log_message(self, fmt, *args):  # keep stdout quiet; errors go to stderr
        sys.stderr.write("[normalizer] %s\n" % (fmt % args))

    def _forward(self, body: bytes | None):
        conn = HTTPConnection(self.upstream_host, self.upstream_port, timeout=600)
        headers = {}
        for key, value in self.headers.items():
            if key.lower() in ("host", "content-length"):
                continue
            headers[key] = value
        if body is not None:
            headers["Content-Length"] = str(len(body))
        conn.request(self.command, self.path, body=body, headers=headers)
        resp = conn.getresponse()

        self.send_response(resp.status)
        for key in ("content-type", "cache-control", "x-request-id"):
            value = resp.getheader(key)
            if value:
                self.send_header(key, value)
        # Stream without buffering; fall back to content-length when present.
        length = resp.getheader("content-length")
        if length is None and resp.will_close:
            self.close_connection = True
        elif length is not None:
            self.send_header("Content-Length", length)
        else:
            self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        try:
            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                if length is None and not resp.will_close:
                    # manual chunked framing
                    self.wfile.write(b"%x\r\n" % len(chunk))
                    self.wfile.write(chunk + b"\r\n")
                else:
                    self.wfile.write(chunk)
                self.wfile.flush()
            if length is None and not resp.will_close:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
        finally:
            conn.close()

    def do_POST(self):
        length = int(self.headers.get("content-length", 0))
        body = self.rfile.read(length) if length else None
        try:
            if self.path.startswith("/v1/messages") and body is not None:
                body = normalize(body)
            self._forward(body)
        except Exception as exc:  # noqa: BLE001 - report upstream failures to client
            sys.stderr.write("[normalizer] error: %r\n" % (exc,))
            try:
                payload = json.dumps({"error": str(exc)}).encode()
                self.send_response(502)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            except Exception:
                pass

    def do_GET(self):
        if self.path in ("/healthz", "/health"):
            payload = b'{"status":"ok"}'
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self._forward(None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=4001)
    parser.add_argument("--upstream", default="http://localhost:4000")
    args = parser.parse_args()

    parts = urlsplit(args.upstream)
    Handler.upstream_host = parts.hostname or "localhost"
    Handler.upstream_port = parts.port or 4000

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    sys.stderr.write(
        "[normalizer] listening on http://127.0.0.1:%d -> %s\n" % (args.port, args.upstream)
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
PYEOF
echo "Wrote $CFG_DIR/claude-bionic-normalizer.py"

cat > "$BIN_DIR/claude-local" <<'WRAPPEOF'
#!/usr/bin/env bash
# Run Claude Code against local models (generated by setup-claude-local.sh).
# Chain: Claude Code -> normalizer (:4001) -> LiteLLM (:4000) -> model server.
# Both bridges run as systemd user services when available; the fallbacks
# below only kick in if systemd isn't running (e.g. headless SSH session).
#
# Usage: claude-local [CONTEXT] [claude args...]
#   CONTEXT  optional context window for auto-compact:
#              "135k" / "256k" (default)  -> k = x1024, m = x1024^2
#              or an exact token count >= 1024, e.g. 131072

export ANTHROPIC_BASE_URL=http://localhost:4001
export ANTHROPIC_API_KEY=local-bridge

# --- context window (default 256k) ------------------------------------------
CTX_TOKENS=$((256 * 1024))
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
    # bare number: treat as exact token count (small numbers are left for claude)
    CTX_TOKENS=$num
    shift
  fi
fi
export CLAUDE_CODE_MAX_CONTEXT_TOKENS=$CTX_TOKENS

wait_for() { # url seconds
  for _ in $(seq 1 "$2"); do
    sleep 1
    curl -s --max-time 3 "$1" >/dev/null 2>&1 && return 0
  done
  return 1
}

# 1) LiteLLM bridge (Anthropic <-> OpenAI translation). The env flag forces
#    the chat/completions path instead of the Responses API, which Qwen-family
#    servers handle more reliably.
if ! curl -s --max-time 3 http://localhost:4000/health >/dev/null 2>&1; then
  echo "Starting LiteLLM bridge on :4000..." >&2
  LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES=true \
    nohup ~/.local/bin/litellm --config ~/.config/litellm/config.yaml --port 4000 >> ~/litellm-bionic.log 2>&1 &
  wait_for http://localhost:4000/health 30 || { echo "LiteLLM failed to start (see ~/litellm-bionic.log)" >&2; exit 1; }
fi

# 2) System-message normalizer (Qwen templates need system at position 0).
if ! curl -s --max-time 2 http://localhost:4001/healthz >/dev/null 2>&1; then
  echo "Starting message normalizer on :4001..." >&2
  nohup python3 ~/.config/litellm/claude-bionic-normalizer.py --port 4001 >> ~/claude-normalizer.log 2>&1 &
  wait_for http://localhost:4001/healthz 15 || { echo "Normalizer failed to start (see ~/claude-normalizer.log)" >&2; exit 1; }
fi

exec claude --model __FRIENDLY_NAME__ "$@"
WRAPPEOF
sed -i "s/__FRIENDLY_NAME__/$FRIENDLY_NAME/g" "$BIN_DIR/claude-local"
chmod +x "$BIN_DIR/claude-local"
echo "Wrote $BIN_DIR/claude-local (model: $FRIENDLY_NAME)"

# -----------------------------------------------------------------------------
log "5/6 Installing systemd user services"
if command -v systemctl >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_DIR/litellm-bionic.service" <<EOF
[Unit]
Description=LiteLLM bridge for Claude Code -> local models (port $LITELLM_PORT)
After=network.target

[Service]
Type=simple
Environment=LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES=true
ExecStart=%h/.local/bin/litellm --config %h/.config/litellm/config.yaml --port $LITELLM_PORT
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
  cat > "$UNIT_DIR/claude-normalizer.service" <<EOF
[Unit]
Description=Claude Code message normalizer for Qwen chat templates (port $NORMALIZER_PORT)
After=litellm-bionic.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 %h/.config/litellm/claude-bionic-normalizer.py --port $NORMALIZER_PORT
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now litellm-bionic claude-normalizer
  # restart so any previously running instances pick up the new config
  systemctl --user restart litellm-bionic claude-normalizer || true
  echo "Services enabled (auto-start at login) and started."
else
  echo "systemd user session not available - skipping services."
  echo "claude-local will auto-start the bridges on demand instead."
fi

# -----------------------------------------------------------------------------
log "6/6 Verifying"
ok=1
for i in $(seq 1 30); do
  curl -s --max-time 3 "http://localhost:$LITELLM_PORT/health" >/dev/null 2>&1 && break || sleep 1
done
curl -s --max-time 3 "http://localhost:$LITELLM_PORT/health" >/dev/null 2>&1 \
  && echo "LiteLLM bridge :$LITELLM_PORT ... OK" || { echo "LiteLLM bridge :$LITELLM_PORT ... FAILED (see ~/litellm-bionic.log)" >&2; ok=0; }
curl -s --max-time 3 "http://localhost:$NORMALIZER_PORT/healthz" >/dev/null 2>&1 \
  && echo "Normalizer      :$NORMALIZER_PORT ... OK" || { echo "Normalizer      :$NORMALIZER_PORT ... FAILED (see ~/claude-normalizer.log)" >&2; ok=0; }

if [ "$ok" -eq 1 ] && [ "$RUN_TEST" -eq 1 ]; then
  log "End-to-end test: claude-local -p 'Reply with exactly: OK'"
  if "$BIN_DIR/claude-local" -p "Reply with exactly: OK" 2>&1 | tail -3; then :; fi
fi

echo
if [ "$ok" -eq 1 ]; then
  echo "Setup complete. Usage:"
  echo "  claude-local                 # interactive Claude Code on the local model"
  echo "  claude-local 135k            # ...with a 135k context window (default: 256k)"
  echo "  claude-local -p 'your prompt'  # one-shot / headless"
else
  echo "Setup finished with errors - check the messages above." >&2
  exit 1
fi
