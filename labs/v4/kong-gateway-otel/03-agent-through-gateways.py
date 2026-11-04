"""Scenario B — two gateways and an SDK-instrumented agent in one trace.

    client --> Kong agent gateway :18100 --> agent (this script, :18200, Langfuse SDK)
                                               +--> Kong model gateway :18000/chat --> mock model

Kong (agent gateway) creates the trace and injects W3C traceparent; the agent extracts it, so
its SDK spans become children of Kong's span, and injects it again on the model call, so the
model gateway's spans become children of the agent's span. The header contract
(x-user-id, x-session-id, x-agent-id, x-project-id) is forwarded hop by hop; each producer
maps it to Langfuse attributes itself (Kong: pre-function; agent: propagate_attributes).

Run with the v4 venv:  .venv-v4/bin/python labs/v4/kong-gateway-otel/03-agent-through-gateways.py
"""
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import httpx
from opentelemetry import context as otel_context
from opentelemetry import propagate

HERE = Path(__file__).resolve().parent


def load_env(path: Path) -> None:
    """Minimal .env reader (KEY=value, # comments); values already in the shell win."""
    if not path.is_file():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        val = val.split(" #", 1)[0].strip().strip('"').strip("'")
        os.environ.setdefault(key.strip(), val)


load_env(Path(os.environ.get("LF_ENV_FILE", HERE.parents[2] / "_base" / ".env")))
os.environ.setdefault("OTEL_SERVICE_NAME", "support-agent")  # resource service.name of the SDK spans

from langfuse import Langfuse, propagate_attributes  # noqa: E402  (after the env is loaded)

langfuse = Langfuse(
    public_key=os.environ["LANGFUSE_INIT_PROJECT_PUBLIC_KEY"],
    secret_key=os.environ["LANGFUSE_INIT_PROJECT_SECRET_KEY"],
    host=os.environ.get("LANGFUSE_HOST", "http://localhost:3000"),
)
CONTRACT = ("x-user-id", "x-session-id", "x-agent-id", "x-project-id")
MODEL_GATEWAY = "http://localhost:18000/chat"
AGENT_GATEWAY = "http://localhost:18100/agent"


class Agent(BaseHTTPRequestHandler):
    def do_POST(self):
        question = json.loads(self.rfile.read(int(self.headers["content-length"])))["question"]
        incoming = {k.lower(): v for k, v in self.headers.items()}
        token = otel_context.attach(propagate.extract(incoming))  # join Kong's trace
        try:
            with propagate_attributes(
                user_id=incoming.get("x-user-id"),
                session_id=incoming.get("x-session-id"),
                metadata={"agent_id": incoming.get("x-agent-id", ""), "project_id": incoming.get("x-project-id", ""), "gateway": "sdk"},
            ):
                with langfuse.start_as_current_observation(name="support-agent", as_type="agent", input=question) as agent:
                    with langfuse.start_as_current_observation(name="lookup-policy", as_type="tool", input={"q": question}) as tool:
                        tool.update(output={"policy": "refunds within 30 days"})
                    out = {k: incoming[k] for k in CONTRACT if k in incoming}
                    propagate.inject(out)  # traceparent of the agent span -> model gateway
                    r = httpx.post(MODEL_GATEWAY, headers=out, json={"messages": [
                        {"role": "system", "content": "Answer with the policy."},
                        {"role": "user", "content": question},
                    ]}, timeout=10)
                    r.raise_for_status()
                    answer = r.json()["choices"][0]["message"]["content"]
                    agent.update(output=answer)
        finally:
            otel_context.detach(token)
        data = json.dumps({"answer": answer}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def main() -> None:
    server = ThreadingHTTPServer((os.environ.get("AGENT_BIND", "127.0.0.1"), 18200), Agent)  # Linux Docker Engine: AGENT_BIND=0.0.0.0
    threading.Thread(target=server.serve_forever, daemon=True).start()
    run = f"run-{int(time.time())}"
    r = httpx.post(AGENT_GATEWAY, timeout=15, json={"question": "Can I get a refund?"}, headers={
        "x-user-id": "user-1001", "x-session-id": f"{run}-agent", "x-agent-id": "support-agent-v1", "x-project-id": "demo-project",
    })
    r.raise_for_status()
    trace_id = r.headers["x-trace-id"]
    print(f"agent  trace {trace_id}  answer: {r.json()['answer']}")
    langfuse.flush()
    server.shutdown()
    run_dir = HERE / ".run"
    run_dir.mkdir(exist_ok=True)
    with open(run_dir / "traces.env", "a") as f:
        f.write(f"AGENT_TRACE={trace_id}\nAGENT_SESSION={run}-agent\n")


if __name__ == "__main__":
    main()
