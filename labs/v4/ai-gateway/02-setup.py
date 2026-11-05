"""Step 02 — the admin setup, scripted through the same tRPC calls the UI makes.

  .venv-v4/bin/python labs/v4/ai-gateway/02-setup.py

1. Two developers sign up (alice, bob) and the owner (the headless-init user) adds them with the
   AI Gateway organization role: they can call the gateway and manage their own keys, nothing else.
2. Organization settings → AI Gateway → Setup: ingestion project = the init project, mode FULL.
3. One Anthropic provider credential, named anthropic-lab, from ANTHROPIC_API_KEY in the secrets
   file. Web validates it against api.anthropic.com before saving (a real provider call).
4. Gateway keys: a user key each for alice and bob, and a service account key for a backend
   service, each with key metadata (team, cost_center).

Secrets stay in .run/state.json (mode 600); nothing is printed but key prefixes.
"""

from __future__ import annotations

import secrets

import httpx

import lablib as L
from lablib import Session, TrpcError

e = L.env()
assert e.get("ANTHROPIC_API_KEY"), "ANTHROPIC_API_KEY missing in the secrets file"
ORG, PROJECT_ID = e["LANGFUSE_INIT_ORG_ID"], e["LANGFUSE_INIT_PROJECT_ID"]
st = L.state()

# 1. People ----------------------------------------------------------------------------------
owner = Session(e["LANGFUSE_INIT_USER_EMAIL"], e["LANGFUSE_INIT_USER_PASSWORD"])
people = st.get("people", {})
for name in ("alice", "bob"):
    if name not in people:
        people[name] = {"email": f"{name}@example.com", "password": secrets.token_hex(12) + "-Lf!"}  # the sign-up policy wants a non-alphanumeric character
        r = httpx.post(f"{L.WEB}/api/auth/signup", verify=L.VERIFY, json={
            "name": name.title(), "email": people[name]["email"], "password": people[name]["password"]})
        assert r.status_code == 200, f"signup {name}: HTTP {r.status_code} {r.text[:200]}"
    try:
        owner.mutate("members.create", {"orgId": ORG, "email": people[name]["email"], "orgRole": "AI_GATEWAY"})
        print(f"✓ {people[name]['email']} added with org role AI_GATEWAY")
    except TrpcError as err:
        print(f"· {people[name]['email']}: {err.message[:80]} (already a member)")
L.update_state(people=people, org_id=ORG, project_id=PROJECT_ID)

# 2. Ingestion project and mode ------------------------------------------------------------
owner.mutate("aiGateway.updateConfig", {"orgId": ORG, "defaultIngestionProjectId": PROJECT_ID, "ingestionMode": "FULL"})
cfg = owner.query("aiGateway.getConfig", {"orgId": ORG})["config"]
print(f"✓ gateway config: project {cfg['defaultIngestionProjectId']} · mode {cfg['ingestionMode']}")

# 3. Provider credential -------------------------------------------------------------------
conns = owner.query("aiGateway.listConnections", {"orgId": ORG, "limit": 50})["data"]
conn = next((c for c in conns if c["name"] == L.CONNECTION), None)
if conn is None:
    conn = owner.mutate("aiGateway.createConnection", {
        "orgId": ORG, "name": L.CONNECTION, "provider": "ANTHROPIC", "credential": e["ANTHROPIC_API_KEY"]})
    shown = conn.get("displaySecret", "").split("...")[0] + "...<last 4>"  # Langfuse shows prefix + last 4; not printed here
    print(f"✓ provider credential {conn['name']} created: status {conn.get('status')}, shown in the UI as {shown}")
else:
    print(f"· provider credential {conn['name']} exists: status {conn.get('status')}")
L.update_state(connection_id=conn["id"])

# 4. Gateway keys --------------------------------------------------------------------------
keys = st.get("keys", {})
plan = [
    ("alice", "alice-laptop", "user", {"team": "platform", "cost_center": "1001"}),
    ("bob", "bob-laptop", "user", {"team": "data", "cost_center": "2002"}),
    ("owner", "checkout-service", "serviceAccount", {"team": "payments", "cost_center": "3003"}),
]
for who, key_name, issued_as, meta in plan:
    if key_name in keys:
        print(f"· key {key_name} exists ({keys[key_name]['secret'][:10]}…)")
        continue
    s = owner if who == "owner" else Session(people[who]["email"], people[who]["password"])
    k = s.mutate("aiGateway.createApiKey", {"orgId": ORG, "name": key_name, "metadata": meta, "issuedAs": issued_as})
    secret = k.get("secretKey")
    assert secret, f"no secretKey in createApiKey result; fields: {sorted(k)}"
    keys[key_name] = {"id": k["id"], "secret": secret, "issued_as": issued_as, "owner": who, "metadata": meta}
    print(f"✓ key {key_name} ({issued_as}, by {who}) {secret[:10]}… metadata {meta}")
L.update_state(keys=keys)

# 5. Models the keys can call --------------------------------------------------------------
r = httpx.get(f"{L.GATEWAY}/anthropic/v1/models", params={"limit": 1000}, verify=L.VERIFY,
              headers={"x-api-key": keys["alice-laptop"]["secret"], "anthropic-version": "2023-06-01"})
ids = [m["id"] for m in r.json().get("data", [])]
print(f"✓ GET /anthropic/v1/models with alice's key: HTTP {r.status_code}, {len(ids)} models, e.g. {ids[:4]}")
L.update_state(model_ids=ids)
