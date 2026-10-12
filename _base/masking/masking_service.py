#!/usr/bin/env python3
"""masking_service.py — a minimal server-side ingestion-masking callback for Langfuse EE.

Langfuse's WORKER POSTs each ingested OpenTelemetry trace (an OTLP Trace Request,
JSON-encoded) to LANGFUSE_INGESTION_MASKING_CALLBACK_URL. This service walks the
JSON, redacts anything that looks like a secret / PII in the string LEAF values,
and returns the SAME structure — only values changed, never adding, removing or
renaming fields (that is the contract) — with HTTP 200.

Masking happens BEFORE Langfuse persists the trace to ClickHouse, so the raw
secret never lands in the traces / observations tables. Lab 08 proves exactly
that with SQL against ClickHouse (08-verify-masking.sql).

Scope: server-side ingestion masking only applies to events sent to the OTLP
endpoint /api/public/otel (Python SDK v3+, JS SDK v4+) — which is precisely what
08-generate-pii-traces.py uses.

Runs on a bare `python:3-slim` image with NO pip install (stdlib only).
Docs: https://langfuse.com/self-hosting/security/data-masking
"""
import json
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ── Redaction rules: (compiled regex, replacement). Specific patterns first. ───
RULES = [
    (re.compile(r"sk-[A-Za-z0-9_\-]{6,}"),                          "[REDACTED_API_KEY]"),
    (re.compile(r"\b\d{6}-\d{7}\b"),                                "[REDACTED_KR_RRN]"),    # 주민등록번호
    (re.compile(r"\b\d{4}[ -]?\d{4}[ -]?\d{4}[ -]?\d{4}\b"),        "[REDACTED_CC]"),        # 16-digit card
    (re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b"),                   "[REDACTED_EMAIL]"),
    (re.compile(r"\b01[016789][ -]?\d{3,4}[ -]?\d{4}\b"),           "[REDACTED_KR_PHONE]"),
]

# Per-project extra rule (lab 12): only for the project ids in MASK_STRICT_PROJECT_IDS
# (comma list, matched against the X-Langfuse-Project-Id header). Unset = lab 08 behaviour.
STRICT_RULES = [
    (re.compile(r"\b\d{3}-\d{2}-\d{6}\b"),                        "[REDACTED_ACCOUNT]"),
]
STRICT_PROJECT_IDS = {p.strip() for p in os.environ.get("MASK_STRICT_PROJECT_IDS", "").split(",") if p.strip()}
# Lab 12 failure modes: POST /mask-slow sleeps this long before masking, POST /mask-500 fails.
SLOW_SECONDS = float(os.environ.get("MASK_SLOW_SECONDS", "2") or 2)

_hits = {"count": 0}


def redact(text: str, rules=RULES) -> str:
    for rx, repl in rules:
        text, n = rx.subn(repl, text)
        _hits["count"] += n
    return text


def walk(node, rules=RULES):
    """Recursively mask every string LEAF in the JSON, preserving structure."""
    if isinstance(node, dict):
        return {k: walk(v, rules) for k, v in node.items()}
    if isinstance(node, list):
        return [walk(v, rules) for v in node]
    if isinstance(node, str):
        return redact(node, rules)
    return node


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: bytes = b"") -> None:
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802 — health probe for the compose healthcheck
        self._send(200, b'{"status":"ok"}')

    def do_POST(self):  # noqa: N802 — the masking callback itself
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            payload = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            self._send(400, b'{"error":"invalid json"}')
            return
        project = self.headers.get("X-Langfuse-Project-Id", "?")
        if self.path == "/mask-500":
            sys.stderr.write(f"[mask] project={project} path={self.path} -> HTTP 500\n")
            sys.stderr.flush()
            self._send(500, b'{"error":"simulated failure"}')
            return
        if self.path == "/mask-slow":
            time.sleep(SLOW_SECONDS)
        strict = project in STRICT_PROJECT_IDS
        rules = RULES + STRICT_RULES if strict else RULES
        _hits["count"] = 0
        masked = walk(payload, rules)
        sys.stderr.write(f"[mask] project={project} path={self.path} "
                         f"rules={'base+strict' if strict else 'base'} redactions={_hits['count']}\n")
        sys.stderr.flush()
        self._send(200, json.dumps(masked).encode("utf-8"))

    def log_message(self, *args):  # silence default per-request access logging
        pass


if __name__ == "__main__":
    PORT = 3100
    print(f"masking-callback listening on :{PORT} (POST /mask /mask-slow /mask-500, GET /health)", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
