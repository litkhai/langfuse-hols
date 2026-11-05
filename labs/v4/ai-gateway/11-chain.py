"""Step 11 — LiteLLM Proxy in front of the Langfuse AI Gateway (#91).

  .venv-v4/bin/python labs/v4/ai-gateway/11-chain.py      # after 01, 02, 07, 08; restarts LiteLLM once

LiteLLM's model `haiku-via-gateway` sends its Anthropic calls to the gateway (api_base
http://ai-gateway:8080/anthropic) with a gateway service account key `litellm-upstream`, instead of
to api.anthropic.com. The question: do LiteLLM's controls and the gateway's record both hold?

  k1 plain call through both              what each records, and how the two records relate
  k2 client headers                       langfuse-user-id, x-pass-langfuse-user-id, x-litellm-end-user-id
  k3 spend cap on the LiteLLM key         blocked by LiteLLM before the gateway sees it?
  k4 fallback haiku-broken-chain → haiku-via-gateway
Results go to .run/state.json under "chain"; 12-chain-check.py judges them.
"""

from __future__ import annotations

import os
import subprocess
import time
import uuid

import httpx

import lablib as L
from lablib import Session

e = L.env()
st = L.state()
ORG = st["org_id"]
lk = st["litellm"]["keys"]
out: dict = st.get("chain", {})

# 1. The gateway key LiteLLM uses upstream ---------------------------------------------------------
key_file = L.RUN_DIR / "litellm-upstream-gateway-key"
if not key_file.exists():
    owner = Session(e["LANGFUSE_INIT_USER_EMAIL"], e["LANGFUSE_INIT_USER_PASSWORD"])
    k = owner.mutate("aiGateway.createApiKey", {"orgId": ORG, "name": "litellm-upstream",
                                                "metadata": {"team": "platform-gateway", "cost_center": "9009"}, "issuedAs": "serviceAccount"})
    key_file.write_text(k["secretKey"])
    key_file.chmod(0o600)
    out["upstream_key_id"] = k["id"]
    print(f"✓ gateway service account key litellm-upstream {k['secretKey'][:10]}…")

# 2. Restart LiteLLM so it reads the key (07-litellm-up.sh exports it when the file exists) ------------
subprocess.run([str(L.LAB_DIR / "07-litellm-up.sh")], check=True, stdout=subprocess.DEVNULL)
print("✓ LiteLLM restarted with LITELLM_UPSTREAM_GATEWAY_KEY")


def call(key: str, model: str, **headers) -> tuple[int, dict, dict]:
    r = httpx.post(f"{L.LITELLM}/v1/messages", timeout=90,
                   headers={"x-api-key": key, "anthropic-version": "2023-06-01", **headers},
                   json={"model": model, "max_tokens": 5, "messages": [{"role": "user", "content": "Reply with exactly one word: pong"}]})
    try:
        body = r.json()
    except ValueError:
        body = {}
    return r.status_code, body, dict(r.headers)


t0 = L.now().isoformat()
s, b, h = call(lk["alice-laptop"]["secret"], "haiku-via-gateway")
out["k1"] = {"status": s, "model": b.get("model"), "call_id": h.get("x-litellm-call-id"), "error": str(b.get("error", ""))[:200]}
print(f"k1 plain      HTTP {s} model {b.get('model')} call {h.get('x-litellm-call-id')}")

s, b, h = call(lk["checkout-service"]["secret"], "haiku-via-gateway", **{
    "langfuse-user-id": "plain-header-user", "x-pass-langfuse-user-id": "pass-prefix-user",
    "x-litellm-end-user-id": "end-user-77", "x-pass-langfuse-tags": "chain,pass"})
out["k2"] = {"status": s, "call_id": h.get("x-litellm-call-id")}
print(f"k2 headers    HTTP {s} call {h.get('x-litellm-call-id')}")

r = L.litellm_admin("POST", "/key/generate", json={"key_alias": f"alice-budget-chain-{uuid.uuid4().hex[:6]}", "user_id": "alice", "max_budget": 0.00004})
assert r.status_code == 200, f"key/generate: HTTP {r.status_code} {r.text[:200]}"  # aliases are unique per proxy
k = r.json()
seq = []
for i in range(6):
    s, b, h = call(k["key"], "haiku-via-gateway")
    seq.append({"n": i + 1, "status": s, "call_id": h.get("x-litellm-call-id"), "error": str(b.get("error", {}).get("message", "") if isinstance(b.get("error"), dict) else b.get("error", ""))[:120]})
    if s != 200:
        break
    time.sleep(3)
out["k3"] = {"max_budget": 0.00004, "sequence": seq}
print(f"k3 spend cap  {[(x['n'], x['status']) for x in seq]} · {seq[-1]['error'][:80]}")

s, b, h = call(lk["alice-laptop"]["secret"], "haiku-broken-chain")
out["k4"] = {"status": s, "attempted_fallbacks": h.get("x-litellm-attempted-fallbacks"), "call_id": h.get("x-litellm-call-id")}
print(f"k4 fallback   HTTP {s} attempted fallbacks {h.get('x-litellm-attempted-fallbacks')}")

out["since"] = t0
out["until"] = L.now().isoformat()
L.update_state(chain=out)
print("→ recorded in .run/state.json — next: 12-chain-check.py")
