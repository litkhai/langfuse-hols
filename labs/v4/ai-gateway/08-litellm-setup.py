"""Step 08 — the same people and keys on LiteLLM Proxy as 02-setup.py made on the Langfuse gateway (#89).

  .venv-v4/bin/python labs/v4/ai-gateway/08-litellm-setup.py

LiteLLM's admin API with the master key: internal users alice and bob, a team "payments" for the
service, and three virtual keys with the same names and metadata as on the gateway:
alice-laptop (alice), bob-laptop (bob), checkout-service (service account key of team payments).
Keys go to .run/state.json under "litellm".
"""

from __future__ import annotations

import lablib as L

st = L.state()
people = st["people"]  # from 02-setup.py, same emails
out = st.get("litellm", {"keys": {}})


def ok(r, what):
    assert r.status_code == 200, f"{what}: HTTP {r.status_code} {r.text[:300]}"
    return r.json()


for name in ("alice", "bob"):
    r = L.litellm_admin("POST", "/user/new", json={"user_id": name, "user_email": people[name]["email"], "user_role": "internal_user", "auto_create_key": False})
    if r.status_code != 200 and "already exists" not in r.text:
        ok(r, f"user/new {name}")
    print(f"✓ internal user {name} ({people[name]['email']})")

r = L.litellm_admin("POST", "/team/new", json={"team_id": "payments", "team_alias": "payments"})
if r.status_code != 200 and "already exists" not in r.text.lower():
    ok(r, "team/new payments")
print("✓ team payments")

plan = [
    ("alice-laptop", "/key/generate", {"user_id": "alice", "metadata": {"team": "platform", "cost_center": "1001"}}),
    ("bob-laptop", "/key/generate", {"user_id": "bob", "metadata": {"team": "data", "cost_center": "2002"}}),
    ("checkout-service", "/key/service-account/generate", {"team_id": "payments", "metadata": {"team": "payments", "cost_center": "3003"}}),
]
for alias, path, body in plan:
    if alias in out["keys"]:
        print(f"· key {alias} exists")
        continue
    k = ok(L.litellm_admin("POST", path, json={"key_alias": alias, **body}), f"{path} {alias}")
    out["keys"][alias] = {"secret": k["key"], "token": k.get("token") or k.get("token_id"), "user_id": k.get("user_id"), "team_id": k.get("team_id"), "metadata": body["metadata"]}
    print(f"✓ key {alias} via {path}: user_id {k.get('user_id')} · team_id {k.get('team_id')} · {k['key'][:7]}…")
L.update_state(litellm=out)

r = L.litellm_admin("GET", "/v1/models")
print(f"✓ /v1/models: {[m['id'] for m in r.json().get('data', [])]}")
