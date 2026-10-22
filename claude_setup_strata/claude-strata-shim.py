#!/usr/bin/env python3
"""
Optional shim for Claude *Desktop*'s 3p gateway mode -> Strata.

You do NOT need this for Claude Code: Strata serves the Anthropic Messages API
natively on /v1/messages, so `claude-strata` points Claude Code straight at it.

Claude Desktop's enterprise-gateway (3p) mode has habits a raw Strata server
trips over, so this thin proxy exists for that path:

  1. Model discovery. Desktop calls GET /v1/models and wants the *Anthropic*
     model-list shape (data[].type == "model", display_name, first_id/last_id).
     Strata answers with the OpenAI shape -> "Gateway /v1/models returned an
     unexpected body". (Current builds skip discovery when inferenceModels is
     pinned, so this is belt-and-braces.)
  2. Model names. The name Desktop sends must exist in the app's *bundled*
     catalog or ConfigHealth rejects the config (state: 'config_model_rejected'
     in ~/.config/Claude-3p/logs/main.log). Strata rejects unknown ids with
     400 "Choose a loaded model ID." -> the shim rewrites `model` to whatever
     Strata reports loaded.
  3. Token counting. Desktop hammers POST /v1/messages/count_tokens, which
     Strata has no route for (404, and it retries ~20x). The shim answers it
     locally with an estimate (~4 chars/token) so the app stops retrying.

Plus two optional behaviors:

  --thinking off    rewrite `thinking` to {"type":"disabled"}. Strata honors
                    this on its Anthropic surface: no thinking block, so the
                    first *text* token lands sooner and reasoning tokens stop
                    eating the max_tokens budget. --thinking keep (default)
                    passes the app's choice through untouched.
  --normalize       from the older Bionic/LiteLLM chain: merge mid-conversation
                    role=system messages into the top-level system, and strip
                    $schema / propertyNames / string-only anyOf in tool
                    input_schemas. Strata accepts all of that already.

Everything else (including SSE) is streamed through byte-for-byte.

Usage:
  python3 claude-strata-shim.py [--port 4001]
                               [--upstream http://127.0.0.1:47831]
                               [--models claude-sonnet-4-6,claude-sonnet-4-5]
                               [--thinking keep|off]
                               [--normalize]
"""

import argparse
import json
import sys
import time
from urllib.parse import urlsplit
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Desktop names the app's bundled catalog is known to accept (catalog v2831 of
# app 3.1623.1 includes claude-sonnet-4-6 and claude-sonnet-5).
DEFAULT_MODELS = ["claude-sonnet-4-6", "claude-sonnet-4-5"]

LABEL = "Strata (local)"
CHARS_PER_TOKEN = 4.0


class Upstream:
    """Where the Strata server lives, plus a cached loaded-model id."""

    host = "127.0.0.1"
    port = 47831
    prefix = ""  # path prefix, if the API is mounted under one
    _model = None
    _model_ts = 0.0
    model_ttl = 30.0

    @classmethod
    def loaded_model(cls):
        now = time.time()
        if cls._model and now - cls._model_ts < cls.model_ttl:
            return cls._model
        try:
            conn = HTTPConnection(cls.host, cls.port, timeout=10)
            conn.request("GET", cls.prefix + "/v1/models", headers={"accept": "application/json"})
            resp = conn.getresponse()
            body = resp.read()
            conn.close()
            data = json.loads(body)
            ids = [m.get("id") for m in data.get("data", []) if isinstance(m, dict) and m.get("id")]
            if ids:
                cls._model = ids[0]
                cls._model_ts = now
        except Exception as exc:  # noqa: BLE001 - fall back to last known id
            sys.stderr.write("[strata-shim] model discovery failed: %r\n" % (exc,))
        return cls._model or ""


def _system_text(content):
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


def _clean_schema(node):
    """Recursively strip JSON-Schema features strict llama.cpp servers reject."""
    if isinstance(node, list):
        return [_clean_schema(x) for x in node]
    if not isinstance(node, dict):
        return node
    branches = node.get("anyOf")
    if (
        isinstance(branches, list)
        and branches
        and all(isinstance(b, dict) and b.get("type") == "string" for b in branches)
    ):
        enums = []
        for b in branches:
            if isinstance(b.get("enum"), list):
                enums.extend(b["enum"])
            elif "const" in b:
                enums.append(b["const"])
        merged = {k: _clean_schema(v) for k, v in node.items() if k != "anyOf"}
        merged["type"] = "string"
        if enums:
            seen = set()
            merged["enum"] = [e for e in enums if not (e in seen or seen.add(e))]
        return merged
    out = {}
    for key, value in node.items():
        if key in ("$schema", "propertyNames"):
            continue
        out[key] = _clean_schema(value)
    return out


def normalize(body):
    """Rewrite /v1/messages: pin the loaded model id (+ opt-in behaviors)."""
    data = json.loads(body)

    loaded = Upstream.loaded_model()
    if loaded and data.get("model") != loaded:
        data["model"] = loaded

    if Handler.thinking_mode == "off":
        # Set it even when the app omitted the param: without an explicit
        # disable, Strata's Qwen template reasons first and the thinking text
        # lands before (and instead of) the answer.
        data["thinking"] = {"type": "disabled"}

    if Handler.normalize_enabled:
        messages = data.get("messages")
        if isinstance(messages, list):
            extra_systems, kept = [], []
            for msg in messages:
                if isinstance(msg, dict) and msg.get("role") == "system":
                    text = _system_text(msg.get("content"))
                    if text:
                        extra_systems.append(text)
                else:
                    kept.append(msg)
            merged = [t for t in [_system_text(data.get("system")), *extra_systems] if t]
            data["messages"] = kept
            if merged:
                data["system"] = "\n\n".join(merged)

        tools = data.get("tools")
        if isinstance(tools, list):
            data["tools"] = [
                {**t, "input_schema": _clean_schema(t["input_schema"])}
                if isinstance(t, dict) and isinstance(t.get("input_schema"), (dict, list))
                else t
                for t in tools
            ]

    return json.dumps(data, ensure_ascii=False).encode("utf-8")


def _text_bits(node, out):
    """Collect every string reachable in a messages/tools structure."""
    if isinstance(node, str):
        out.append(node)
    elif isinstance(node, list):
        for item in node:
            _text_bits(item, out)
    elif isinstance(node, dict):
        for key, value in node.items():
            if key in ("type", "id", "role", "signature", "cache_control"):
                continue
            _text_bits(value, out)


def count_tokens_body(body):
    """Answer /v1/messages/count_tokens locally: Strata has no such route.

    Anthropic's real answer is tokenizer-exact; this is a ~chars/4 estimate,
    which is what the app uses its context meter with. Errors in either
    direction are a few percent and only affect the usage display.
    """
    try:
        data = json.loads(body)
    except Exception:  # noqa: BLE001
        return json.dumps({"input_tokens": 1}).encode()
    bits = []
    _text_bits(data.get("system"), bits)
    _text_bits(data.get("messages"), bits)
    _text_bits(data.get("tools"), bits)
    _text_bits(data.get("tool_choice"), bits)
    total = int(sum(len(b) for b in bits) / CHARS_PER_TOKEN)
    return json.dumps({"input_tokens": max(1, total)}).encode()


def model_list_body():
    ids = Handler.desktop_models
    return json.dumps(
        {
            "data": [
                {
                    "type": "model",
                    "id": mid,
                    "display_name": "%s - %s" % (mid, LABEL),
                    "created_at": "2026-01-01T00:00:00Z",
                }
                for mid in ids
            ],
            "has_more": False,
            "first_id": ids[0],
            "last_id": ids[-1],
        }
    ).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    normalize_enabled = False
    desktop_models = list(DEFAULT_MODELS)
    thinking_mode = "keep"

    def log_message(self, fmt, *args):  # errors go to stderr, stdout stays quiet
        sys.stderr.write("[strata-shim] %s\n" % (fmt % args))

    def handle(self):
        # Desktop drops the connection whenever a turn is cancelled or times out.
        # socketserver prints a whole traceback for that; it is routine traffic.
        try:
            super().handle()
        except (ConnectionResetError, BrokenPipeError, TimeoutError):
            pass

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "content-type, authorization, x-api-key, anthropic-version, anthropic-beta")

    def _send_json(self, payload, status=200):
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self._cors()
        self.end_headers()
        self.wfile.write(payload)

    def _forward(self, body):
        conn = HTTPConnection(Upstream.host, Upstream.port, timeout=600)
        headers = {}
        for key, value in self.headers.items():
            # Host/content-length are recomputed; accept-encoding is dropped so
            # the upstream answers uncompressed and we can stream it verbatim.
            if key.lower() in ("host", "content-length", "accept-encoding"):
                continue
            headers[key] = value
        if body is not None:
            headers["Content-Length"] = str(len(body))
        conn.request(self.command, Upstream.prefix + self.path, body=body, headers=headers)
        resp = conn.getresponse()

        self.send_response(resp.status)
        for key in ("content-type", "cache-control", "x-request-id", "content-encoding"):
            value = resp.getheader(key)
            if value:
                self.send_header(key, value)
        self._cors()
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
        path = self.path.split("?", 1)[0]
        try:
            if path == "/v1/messages/count_tokens":
                self._send_json(count_tokens_body(body or b"{}"))
                return
            if path.startswith("/v1/messages") and body is not None:
                try:
                    body = normalize(body)
                except Exception as exc:  # noqa: BLE001 - forward as-is if we can't parse
                    sys.stderr.write("[strata-shim] normalize skipped: %r\n" % (exc,))
            self._forward(body)
        except (BrokenPipeError, ConnectionResetError):
            # The app hung up (its own timeout, a cancelled turn, or a window
            # close). Nothing to report to a client that is already gone.
            sys.stderr.write("[strata-shim] client aborted %s\n" % path)
        except Exception as exc:  # noqa: BLE001 - report upstream failures to client
            sys.stderr.write("[strata-shim] error: %r\n" % (exc,))
            try:
                payload = json.dumps(
                    {"type": "error", "error": {"type": "api_error", "message": repr(exc)}}
                ).encode()
                self._send_json(payload, 502)
            except Exception:
                pass

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/healthz", "/health"):
            body = {"status": "ok", "upstream": "%s:%d" % (Upstream.host, Upstream.port)}
            loaded = Upstream.loaded_model()
            if loaded:
                body["model"] = loaded
            if Handler.thinking_mode != "keep":
                body["thinking"] = Handler.thinking_mode
            self._send_json(json.dumps(body).encode())
            return
        if path == "/v1/models":
            self._send_json(model_list_body())
            return
        try:
            self._forward(None)
        except (BrokenPipeError, ConnectionResetError):
            sys.stderr.write("[strata-shim] client aborted %s\n" % path)

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.send_header("Content-Length", "0")
        self.end_headers()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=4001)
    parser.add_argument("--upstream", default="http://127.0.0.1:47831")
    parser.add_argument("--models", default=",".join(DEFAULT_MODELS),
                        help="comma-separated Desktop model names to advertise")
    parser.add_argument("--thinking", choices=("keep", "off"), default="keep",
                        help="keep = pass the app's thinking param through;"
                             " off = force thinking disabled (faster first text token)")
    parser.add_argument("--normalize", action="store_true",
                        help="also merge mid-conversation system messages and clean tool schemas")
    args = parser.parse_args()

    parts = urlsplit(args.upstream)
    Upstream.host = parts.hostname or "127.0.0.1"
    Upstream.port = parts.port or 80
    Upstream.prefix = parts.path.rstrip("/")
    Handler.normalize_enabled = bool(args.normalize)
    Handler.thinking_mode = args.thinking
    Handler.desktop_models = [m.strip() for m in args.models.split(",") if m.strip()]

    loaded = Upstream.loaded_model()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    sys.stderr.write(
        "[strata-shim] http://127.0.0.1:%d -> %s%s (model=%s, desktop names=%s, thinking=%s, normalize=%s)\n"
        % (args.port, args.upstream, Upstream.prefix, loaded or "unknown",
           ",".join(Handler.desktop_models), Handler.thinking_mode, Handler.normalize_enabled)
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
