"""Step 03 — real Anthropic calls through the gateway, one per claim. Claude Haiku 4.5, short replies.

  .venv-v4/bin/python labs/v4/ai-gateway/03-calls.py            # all scenarios
  FAULT=1 .venv-v4/bin/python labs/v4/ai-gateway/03-calls.py    # injected fault, 05-check.py must fail
  SKIP_CLAUDE_CODE=1 ...                                         # without scenario s7

  s1 sdk-basic          alice's user key, Anthropic SDK; only base_url and api_key differ from a direct call
  s2 sdk-stream         the same with stream=True and the prefixed model ID anthropic-lab:<model>
  s3 user-key-override  bob's user key with langfuse-user-id: mallory@example.com (must be ignored)
  s4 service-end-user   service account key with langfuse-user-id, session, environment, tags, metadata
  s5 service-default    service account key, no headers: the trace user falls back to the key name
  s6 sdk-traceparent    Langfuse SDK span → traceparent on the gateway call → one trace
  s7 claude-code        `claude -p` with ANTHROPIC_BASE_URL and ANTHROPIC_AUTH_TOKEN = alice's key

FAULT=1 drops langfuse-user-id in s4 and traceparent in s6, as a client that forgot them would.
The call results (trace and observation IDs from the response headers) go to .run/state.json.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import time
import uuid

import anthropic

import lablib as L

e = L.env()
st = L.state()
keys = st["keys"]
FAULT = os.environ.get("FAULT") == "1"
RUN = uuid.uuid4().hex[:8]
PROMPT = [{"role": "user", "content": "Reply with exactly one word: pong"}]
calls: dict[str, dict] = {}


def client(key: str, **headers) -> anthropic.Anthropic:
    # The only difference from a direct Anthropic call: base_url and api_key.
    return anthropic.Anthropic(base_url=f"{L.GATEWAY}/anthropic", api_key=key,
                               default_headers=headers or None, max_retries=0)


def record(name: str, raw, model: str, usage, text: str, **expect) -> None:
    h = raw.headers
    calls[name] = {
        "http_status": raw.status_code,
        "trace_id": h.get("langfuse-trace-id"),
        "observation_id": h.get("langfuse-observation-id"),
        "request_id": h.get("langfuse-request-id"),
        "provider": h.get("langfuse-provider"),
        "provider_request_id": h.get("request-id"),
        "response_model": model,
        "usage": {"input": usage.input_tokens, "output": usage.output_tokens},
        "text": text.strip(),
        **expect,
    }
    c = calls[name]
    print(f"✓ {name:20} HTTP {c['http_status']} {c['response_model']} {c['usage']} "
          f"trace {c['trace_id']} '{c['text']}'")


def done(name: str, raw, **expect) -> None:
    msg = raw.parse()
    record(name, raw, msg.model, msg.usage, "".join(b.text for b in msg.content if b.type == "text"), **expect)


# s1 — the minimal change -------------------------------------------------------------------
raw = client(keys["alice-laptop"]["secret"]).messages.with_raw_response.create(
    model=L.MODEL, max_tokens=10, messages=PROMPT)
done("s1-sdk-basic", raw, key="alice-laptop", user=st["people"]["alice"]["email"])

# s2 — streaming, prefixed model ID ---------------------------------------------------------
with client(keys["alice-laptop"]["secret"]).messages.with_streaming_response.create(
        model=f"{L.CONNECTION}:{L.MODEL}", max_tokens=10, messages=PROMPT, stream=True) as resp:
    text, model, usage = "", None, None
    for event in resp.parse():
        if event.type == "message_start":
            model, usage = event.message.model, event.message.usage
        elif event.type == "content_block_delta" and event.delta.type == "text_delta":
            text += event.delta.text
        elif event.type == "message_delta":
            usage.output_tokens = event.usage.output_tokens
    record("s2-sdk-stream", resp, model, usage, text, key="alice-laptop", user=st["people"]["alice"]["email"])

# s3 — a user key cannot claim another user ---------------------------------------------------
raw = client(keys["bob-laptop"]["secret"], **{"langfuse-user-id": "mallory@example.com"}).messages.with_raw_response.create(
    model=L.MODEL, max_tokens=10, messages=PROMPT)
done("s3-user-key-override", raw, key="bob-laptop", user=st["people"]["bob"]["email"])

# s4 — a service forwards its end user and context ----------------------------------------------
hdr = {
    "langfuse-user-id": "end-user-42",
    "langfuse-session-id": f"checkout-{RUN}",
    "langfuse-environment": "production",
    "langfuse-tags": "checkout,beta",
    "langfuse-metadata": "order:A-1001,region:kr",
    "langfuse-trace-name": "checkout-summary",
}
if FAULT:
    hdr.pop("langfuse-user-id")
raw = client(keys["checkout-service"]["secret"], **hdr).messages.with_raw_response.create(
    model=L.MODEL, max_tokens=10, messages=PROMPT)
done("s4-service-end-user", raw, key="checkout-service", user="end-user-42",
       session=f"checkout-{RUN}", environment="production", tags=["beta", "checkout"],
       metadata={"order": "A-1001", "region": "kr"}, trace_name="checkout-summary")

# s5 — a service without headers ----------------------------------------------------------------
raw = client(keys["checkout-service"]["secret"]).messages.with_raw_response.create(
    model=L.MODEL, max_tokens=10, messages=PROMPT)
done("s5-service-default", raw, key="checkout-service", user="checkout-service")

# s6 — the gateway generation inside an app's own trace -----------------------------------------
os.environ.setdefault("OTEL_SERVICE_NAME", "checkout-app")
from langfuse import Langfuse  # noqa: E402
from opentelemetry import propagate  # noqa: E402

lf = Langfuse(public_key=e["LANGFUSE_INIT_PROJECT_PUBLIC_KEY"], secret_key=e["LANGFUSE_INIT_PROJECT_SECRET_KEY"], host=L.WEB)
with lf.start_as_current_observation(name="checkout-request", as_type="span", input={"order": "A-1002"}) as span:
    carrier: dict[str, str] = {}
    propagate.inject(carrier)  # W3C traceparent of the current span
    if FAULT:
        carrier.pop("traceparent", None)
    raw = client(keys["checkout-service"]["secret"], **carrier).messages.with_raw_response.create(
        model=L.MODEL, max_tokens=10, messages=PROMPT)
    span.update(output={"reply": raw.parse().content[0].text})
    app_trace, app_span = span.trace_id, span.id
lf.flush()
done("s6-sdk-traceparent", raw, key="checkout-service", app_trace_id=app_trace, app_span_id=app_span)

# s7 — Claude Code through the gateway ----------------------------------------------------------
if os.environ.get("SKIP_CLAUDE_CODE") != "1" and shutil.which("claude"):
    cfg = tempfile.mkdtemp(prefix="cc-gateway-")  # fresh config dir: no stored login is used
    env = {k: v for k, v in os.environ.items() if not k.startswith(("ANTHROPIC_", "CLAUDE_"))}
    env.update({
        "CLAUDE_CONFIG_DIR": cfg,
        "ANTHROPIC_BASE_URL": f"{L.GATEWAY}/anthropic",      # no /v1: Claude Code appends /v1/messages
        "ANTHROPIC_AUTH_TOKEN": keys["alice-laptop"]["secret"],  # sent as Authorization: Bearer
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    })
    t0 = L.now()
    p = subprocess.run(["claude", "-p", "Reply with exactly: hello gateway", "--model", L.MODEL,
                        "--max-turns", "1"],
                       env=env, cwd=cfg, capture_output=True, text=True, timeout=180)
    version = subprocess.run(["claude", "--version"], capture_output=True, text=True).stdout.strip()
    shutil.rmtree(cfg, ignore_errors=True)
    calls["s7-claude-code"] = {"exit": p.returncode, "stdout": p.stdout.strip()[-200:], "stderr": p.stderr.strip()[-300:],
                               "since": t0.isoformat(), "claude_version": version, "key": "alice-laptop",
                               "user": st["people"]["alice"]["email"]}
    print(f"{'✓' if p.returncode == 0 else '✗'} s7-claude-code      exit {p.returncode} ({version}) '{p.stdout.strip()[:60]}'")
else:
    print("· s7-claude-code skipped")

L.update_state(calls=calls, run_id=RUN, fault=FAULT, calls_at=L.now().isoformat())
time.sleep(1)
print(f"→ run {RUN}{' (FAULT)' if FAULT else ''} recorded in .run/state.json — next: 04-controls.py, then 05-check.py")
