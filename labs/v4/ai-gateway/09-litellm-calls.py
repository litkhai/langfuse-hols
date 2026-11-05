"""Step 09 — the same calls and controls against LiteLLM Proxy, plus the gateway's side where LiteLLM has
a feature the gateway does not (#89). Real Anthropic calls, Claude Haiku 4.5, max_tokens 10 or less.

  .venv-v4/bin/python labs/v4/ai-gateway/09-litellm-calls.py            # ~2 minutes
  FAULT=1 .venv-v4/bin/python labs/v4/ai-gateway/09-litellm-calls.py    # injected fault, 10-compare-check.py must fail
  SKIP_CLAUDE_CODE=1 ...                                                 # without l7

Calls (same names as 03-calls.py, prefix l):
  l1 sdk-basic          alice's key, Anthropic SDK with base_url = LiteLLM
  l2 sdk-stream         stream=True
  l3 user-override      bob's key with x-litellm-end-user-id: mallory@example.com
  l4 service-end-user   service account key with x-litellm-end-user-id and x-litellm-tags
  l5 service-default    service account key, no headers
  l6 sdk-traceparent    Langfuse SDK span → traceparent on the LiteLLM call
  l7 claude-code        claude -p with ANTHROPIC_BASE_URL = LiteLLM
Controls:
  A model restriction · B expiry · C revocation (key delete) · D user delete · E spend cap ·
  F rate limit · G fallback (and the gateway with a failing model) · H latency against a direct call
FAULT=1 drops the end-user header in l4 and traceparent in l6, and skips the controls (their last results stay).
"""

from __future__ import annotations

import os
import shutil
import statistics
import subprocess
import tempfile
import time
import uuid

import anthropic
import httpx

import lablib as L

e = L.env()
st = L.state()
lk = st["litellm"]["keys"]
FAULT = os.environ.get("FAULT") == "1"
RUN = uuid.uuid4().hex[:8]
PROMPT = [{"role": "user", "content": "Reply with exactly one word: pong"}]
calls: dict[str, dict] = {}
ctl: dict[str, dict] = {}


def client(key: str, **headers) -> anthropic.Anthropic:
    # As with the gateway: only base_url and the key differ from a direct Anthropic call.
    return anthropic.Anthropic(base_url=L.LITELLM, api_key=key, default_headers=headers or None, max_retries=0)


def record(name: str, raw, model, usage, text, **expect) -> None:
    h = raw.headers
    calls[name] = {"http_status": raw.status_code, "call_id": h.get("x-litellm-call-id"),
                   "response_cost": h.get("x-litellm-response-cost"), "key_spend": h.get("x-litellm-key-spend"),
                   "provider_request_id": h.get("request-id"), "response_model": model,
                   "usage": {"input": usage.input_tokens, "output": usage.output_tokens}, "text": text.strip(), **expect}
    c = calls[name]
    print(f"✓ {name:20} HTTP {c['http_status']} {model} {c['usage']} call {c['call_id']} cost {c['response_cost']} '{c['text']}'")


def done(name, raw, **expect):
    m = raw.parse()
    record(name, raw, m.model, m.usage, "".join(b.text for b in m.content if b.type == "text"), **expect)


def post(base: str, key: str, model: str = L.MODEL, auth: str = "x-api-key", **headers) -> tuple[int, str, dict]:
    h = {"anthropic-version": "2023-06-01", **headers}
    h["x-api-key" if auth == "x-api-key" else "Authorization"] = key if auth == "x-api-key" else f"Bearer {key}"
    path = "/v1/messages" if base == L.LITELLM else ("/anthropic/v1/messages" if base == L.GATEWAY else "/v1/messages")
    r = httpx.post(base + path, headers=h, timeout=60,
                   json={"model": model, "max_tokens": 1, "messages": [{"role": "user", "content": "Hi"}]})
    try:
        body = r.json()
    except ValueError:
        body = {}
    err = body.get("error", {}) if r.status_code != 200 else {}
    msg = (err.get("type", "") + " " + str(err.get("message", ""))).strip()[:200] if isinstance(err, dict) else str(err)[:200]
    return r.status_code, msg, dict(r.headers)


def poll(key: str, until: int, since: float, limit_s: float, every: float = 1.0) -> dict:
    seen = []
    while True:
        status, msg, _ = post(L.LITELLM, key)
        t = round(time.monotonic() - since, 1)
        seen.append(status)
        if status == until:
            return {"reached": True, "after_s": t, "calls": len(seen), "last": msg}
        if t > limit_s:
            return {"reached": False, "after_s": t, "calls": len(seen), "statuses": sorted(set(seen)), "last": msg}
        time.sleep(every)


def gen_key(body: dict) -> dict:
    r = L.litellm_admin("POST", "/key/generate", json=body)
    assert r.status_code == 200, r.text[:300]
    return r.json()


# l1–l5 ------------------------------------------------------------------------------------------
raw = client(lk["alice-laptop"]["secret"]).messages.with_raw_response.create(model=L.MODEL, max_tokens=10, messages=PROMPT)
done("l1-sdk-basic", raw, key="alice-laptop", user="alice")

with client(lk["alice-laptop"]["secret"]).messages.with_streaming_response.create(
        model=L.MODEL, max_tokens=10, messages=PROMPT, stream=True) as resp:
    text, model, usage = "", None, None
    for ev in resp.parse():
        if ev.type == "message_start":
            model, usage = ev.message.model, ev.message.usage
        elif ev.type == "content_block_delta" and ev.delta.type == "text_delta":
            text += ev.delta.text
        elif ev.type == "message_delta":
            usage.output_tokens = ev.usage.output_tokens
    record("l2-sdk-stream", resp, model, usage, text, key="alice-laptop", user="alice")

raw = client(lk["bob-laptop"]["secret"], **{"x-litellm-end-user-id": "mallory@example.com"}).messages.with_raw_response.create(
    model=L.MODEL, max_tokens=10, messages=PROMPT)
done("l3-user-override", raw, key="bob-laptop", user="bob", end_user="mallory@example.com")

hdr = {"x-litellm-end-user-id": "end-user-42", "x-litellm-tags": "checkout,beta"}
if FAULT:
    hdr.pop("x-litellm-end-user-id")
raw = client(lk["checkout-service"]["secret"], **hdr).messages.with_raw_response.create(model=L.MODEL, max_tokens=10, messages=PROMPT)
done("l4-service-end-user", raw, key="checkout-service", end_user="end-user-42", tags=["beta", "checkout"])

raw = client(lk["checkout-service"]["secret"]).messages.with_raw_response.create(model=L.MODEL, max_tokens=10, messages=PROMPT)
done("l5-service-default", raw, key="checkout-service")

# l6 — traceparent -------------------------------------------------------------------------------
os.environ.setdefault("OTEL_SERVICE_NAME", "checkout-app")
from langfuse import Langfuse  # noqa: E402
from opentelemetry import propagate  # noqa: E402

lf = Langfuse(public_key=e["LANGFUSE_INIT_PROJECT_PUBLIC_KEY"], secret_key=e["LANGFUSE_INIT_PROJECT_SECRET_KEY"], host=L.WEB)
with lf.start_as_current_observation(name="checkout-request-litellm", as_type="span", input={"order": "A-2002"}) as span:
    carrier: dict[str, str] = {}
    propagate.inject(carrier)
    if FAULT:
        carrier.pop("traceparent", None)
    raw = client(lk["checkout-service"]["secret"], **carrier).messages.with_raw_response.create(model=L.MODEL, max_tokens=10, messages=PROMPT)
    span.update(output={"reply": raw.parse().content[0].text})
    app_trace, app_span = span.trace_id, span.id
lf.flush()
done("l6-sdk-traceparent", raw, key="checkout-service", app_trace_id=app_trace, app_span_id=app_span)

# l7 — Claude Code -------------------------------------------------------------------------------
if os.environ.get("SKIP_CLAUDE_CODE") != "1" and shutil.which("claude"):
    cfg = tempfile.mkdtemp(prefix="cc-litellm-")
    env = {k: v for k, v in os.environ.items() if not k.startswith(("ANTHROPIC_", "CLAUDE_"))}
    env.update({"CLAUDE_CONFIG_DIR": cfg, "ANTHROPIC_BASE_URL": L.LITELLM, "ANTHROPIC_AUTH_TOKEN": lk["alice-laptop"]["secret"],
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"})
    t0 = L.now()
    p = subprocess.run(["claude", "-p", "Reply with exactly: hello gateway", "--model", L.MODEL, "--max-turns", "1"],
                       env=env, cwd=cfg, capture_output=True, text=True, timeout=180)
    shutil.rmtree(cfg, ignore_errors=True)
    calls["l7-claude-code"] = {"exit": p.returncode, "stdout": p.stdout.strip()[-200:], "stderr": p.stderr.strip()[-300:],
                               "since": t0.isoformat(), "key": "alice-laptop", "user": "alice"}
    print(f"{'✓' if p.returncode == 0 else '✗'} l7-claude-code       exit {p.returncode} '{p.stdout.strip()[:60]}' {p.stderr.strip()[:120]}")
calls_at = L.now().isoformat()

if FAULT:  # the fault touches only l4 and l6; keep the controls of the last normal run
    ctl = st["litellm"].get("controls", {})
else:
    # A — model restriction --------------------------------------------------------------------------
    k = gen_key({"key_alias": "alice-dated-only", "user_id": "alice", "models": ["claude-haiku-4-5-20251001"]})
    ctl["model_restriction"] = {lbl: dict(zip(("status", "error"), post(L.LITELLM, k["key"], m)[:2])) for lbl, m in
                                [("dated", "claude-haiku-4-5-20251001"), ("alias", "claude-haiku-4-5")]}
    print(f"A models      dated {ctl['model_restriction']['dated']['status']} · alias {ctl['model_restriction']['alias']['status']} {ctl['model_restriction']['alias']['error'][:90]}")

    # B — expiry ---------------------------------------------------------------------------------------
    k = gen_key({"key_alias": "alice-short", "user_id": "alice", "duration": "40s"})
    first = post(L.LITELLM, k["key"])[0]
    t_created = time.monotonic()
    time.sleep(max(0.0, 40 - (time.monotonic() - t_created) + 0.5))
    ctl["expiry"] = {"expires": k.get("expires"), "before_expiry": first, **poll(k["key"], 401, time.monotonic(), 90, every=2.0)}
    print(f"B expiry      before {first} · 401 reached {ctl['expiry']['reached']} {ctl['expiry']['after_s']} s after expiry ({ctl['expiry']['calls']} calls)")

    # C — revocation (delete) ------------------------------------------------------------------------------
    k = gen_key({"key_alias": "bob-temp", "user_id": "bob"})
    warm = [post(L.LITELLM, k["key"])[0] for _ in range(2)]
    r = L.litellm_admin("POST", "/key/delete", json={"keys": [k["key"]]})
    ctl["revocation"] = {"before": warm, "delete_http": r.status_code, **poll(k["key"], 401, time.monotonic(), 90)}
    print(f"C revocation  before {warm} · 401 reached {ctl['revocation']['reached']} {ctl['revocation']['after_s']} s after delete ({ctl['revocation']['calls']} calls)")

    # D — user deleted -------------------------------------------------------------------------------------
    L.litellm_admin("POST", "/user/new", json={"user_id": "carol", "user_email": "carol@example.com", "user_role": "internal_user", "auto_create_key": False})
    k = gen_key({"key_alias": "carol-laptop", "user_id": "carol"})
    before = post(L.LITELLM, k["key"])[0]
    r = L.litellm_admin("POST", "/user/delete", json={"user_ids": ["carol"]})
    d = {"before": before, "delete_http": r.status_code, **poll(k["key"], 401, time.monotonic(), 90)}
    info = L.litellm_admin("GET", "/key/info", params={"key": k["key"]})
    d["key_info_after"] = info.status_code
    ctl["user_delete"] = d
    print(f"D user delete before {before} · 401 reached {d['reached']} {d['after_s']} s after user delete ({d['calls']} calls) · key/info {info.status_code}")

    # E — spend cap --------------------------------------------------------------------------------------
    k = gen_key({"key_alias": "alice-budget", "user_id": "alice", "max_budget": 0.00006})
    seq = []
    for i in range(8):
        s, m, h = post(L.LITELLM, k["key"])
        seq.append({"n": i + 1, "status": s, "key_spend": h.get("x-litellm-key-spend"), "error": m[:140]})
        if s != 200:
            break
        time.sleep(3)
    ctl["spend_cap"] = {"max_budget": 0.00006, "sequence": seq}
    print(f"E spend cap   {[(x['n'], x['status'], x['key_spend']) for x in seq]} · {seq[-1]['error'][:100]}")

    # F — rate limit -------------------------------------------------------------------------------------
    k = gen_key({"key_alias": "alice-rpm2", "user_id": "alice", "rpm_limit": 2})
    ctl["rate_limit"] = {"rpm_limit": 2, "statuses": [post(L.LITELLM, k["key"])[0] for _ in range(3)]}
    print(f"F rate limit  rpm 2 → {ctl['rate_limit']['statuses']}")

    # G — fallback (LiteLLM) and the gateway with a failing model ------------------------------------------
    s, m, h = post(L.LITELLM, lk["alice-laptop"]["secret"], "haiku-broken")
    ctl["fallback"] = {"status": s, "error": m, "attempted_fallbacks": h.get("x-litellm-attempted-fallbacks"),
                       "model_group": h.get("x-litellm-model-group"), "call_id": h.get("x-litellm-call-id")}
    s2, m2, h2 = post(L.GATEWAY, st["keys"]["alice-laptop"]["secret"], "claude-haiku-4-5-does-not-exist")
    ctl["gateway_failing_model"] = {"status": s2, "error": m2, "trace_id": h2.get("langfuse-trace-id")}
    print(f"G fallback    LiteLLM haiku-broken → {s} (attempted fallbacks {h.get('x-litellm-attempted-fallbacks')}) · gateway unknown model → {s2} {m2[:80]}")

    # H — latency: same tiny request, direct and through each gateway (one warm-up each, then 5) -----------------
    lat = {}
    for label, base, key in [("direct", "https://api.anthropic.com", e["ANTHROPIC_API_KEY"]),
                             ("langfuse_gateway", L.GATEWAY, st["keys"]["alice-laptop"]["secret"]),
                             ("litellm", L.LITELLM, lk["alice-laptop"]["secret"])]:
        post(base, key)
        ms = []
        for _ in range(5):
            t = time.perf_counter()
            s, _, _ = post(base, key)
            ms.append(round((time.perf_counter() - t) * 1000))
            assert s == 200, (label, s)
        lat[label] = {"ms": ms, "median": statistics.median(ms)}
    ctl["latency"] = lat
    print("H latency     " + " · ".join(f"{k} median {v['median']} ms {v['ms']}" for k, v in lat.items()))

L.update_state(litellm={**st["litellm"], "calls": calls, "controls": ctl, "run_id": RUN, "fault": FAULT, "calls_at": calls_at})
print(f"→ run {RUN}{' (FAULT)' if FAULT else ''} recorded in .run/state.json — next: 10-compare-check.py")
