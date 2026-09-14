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
