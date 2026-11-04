"""OpenAI-compatible stand-in for a model: POST /v1/chat/completions, no key, no cost.

Answers "mock reply to: <last user message>" with a fixed usage block, so Kong's ai-proxy
can parse model, tokens and body exactly as it would from a real provider.
Runs in a python:3.12-slim container (docker-compose.yml); standard library only.
"""
import json
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        last = next((m.get("content", "") for m in reversed(body.get("messages", [])) if m.get("role") == "user"), "")
        text = f"mock reply to: {last}"
        out = {
            "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": body.get("model", "mock-model"),
            "choices": [{"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": text}}],
            "usage": {"prompt_tokens": 11 + len(last.split()), "completion_tokens": len(text.split()), "total_tokens": 11 + len(last.split()) + len(text.split())},
        }
        time.sleep(0.05)
        data = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
