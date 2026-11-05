"""Step 04 — the controls the announcement lists, measured: model allowlist, key expiry, revocation,
losing gateway access, and the ingestion mode. Real calls use max_tokens=1.

  .venv-v4/bin/python labs/v4/ai-gateway/04-controls.py     # ~1 minute (waits for the 40 s expiry)

A  allowlist    the credential allows only claude-haiku-4-5-20251001 (the dated ID from the provider's
                model list); the alias claude-haiku-4-5 and another model are tried
B  expiry       a user key that expires 40 s after creation, polled until it stops working
C  revocation   a fresh key is used once (so its lookup is cached), revoked, and polled
D  role change  bob's organization role goes AI_GATEWAY → VIEWER → AI_GATEWAY while his key is polled;
                Langfuse deletes the user keys of someone who loses gateway access, so bob then issues a new one
E  USAGE mode   one call with the organization in USAGE mode, then back to FULL
Results go to .run/state.json under "controls"; 05-check.py judges them.
"""

from __future__ import annotations

import time
from datetime import datetime, timedelta

import httpx

import lablib as L
from lablib import Session, TrpcError

e = L.env()
st = L.state()
ORG, CID = st["org_id"], st["connection_id"]
keys, people = st["keys"], st["people"]
owner = Session(e["LANGFUSE_INIT_USER_EMAIL"], e["LANGFUSE_INIT_USER_PASSWORD"])
alice = Session(people["alice"]["email"], people["alice"]["password"])
bob = Session(people["bob"]["email"], people["bob"]["password"])
out: dict[str, dict] = {}


def call(key: str, model: str = L.MODEL) -> tuple[int, str, str | None]:
    r = httpx.post(f"{L.GATEWAY}/anthropic/v1/messages", timeout=60,
                   headers={"x-api-key": key, "anthropic-version": "2023-06-01"},
                   json={"model": model, "max_tokens": 1, "messages": [{"role": "user", "content": "Hi"}]})
    try:
        err = r.json().get("error", {}) if r.status_code != 200 else {}
    except ValueError:
        err = {"message": r.text[:120]}
    return r.status_code, (err.get("type", "") + " " + err.get("message", "")).strip()[:160], r.headers.get("langfuse-trace-id")


def poll(key: str, until: int, since: float, limit_s: float, every: float = 2.0) -> dict:
    """Call every `every` seconds until the status is `until`; return when, relative to `since`."""
    seen = []
    while True:
        status, msg, _ = call(key)
        t = round(time.monotonic() - since, 1)
        seen.append(status)
        if status == until:
            return {"reached": True, "after_s": t, "calls": len(seen), "last": msg}
        if t > limit_s:
            return {"reached": False, "after_s": t, "calls": len(seen), "statuses": sorted(set(seen))}
        time.sleep(every)


def conn_updated_at() -> datetime:
    c = owner.query("aiGateway.getConnection", {"orgId": ORG, "id": CID})
    return datetime.fromisoformat(c["updatedAt"].replace("Z", "+00:00"))


# A — model allowlist -------------------------------------------------------------------------
owner.mutate("aiGateway.updateConnectionModels", {"orgId": ORG, "id": CID,
             "allowedModels": ["claude-haiku-4-5-20251001"], "expectedUpdatedAt": conn_updated_at()})
listed = httpx.get(f"{L.GATEWAY}/anthropic/v1/models", params={"limit": 1000},
                   headers={"x-api-key": keys["alice-laptop"]["secret"], "anthropic-version": "2023-06-01"}).json()
a = {"listed": [m["id"] for m in listed.get("data", [])]}
for label, model in [("dated", "claude-haiku-4-5-20251001"), ("alias", "claude-haiku-4-5"),
                     ("prefixed_dated", f"{L.CONNECTION}:claude-haiku-4-5-20251001"),
                     ("other_model", "claude-sonnet-4-5-20250929")]:
    status, msg, _ = call(keys["alice-laptop"]["secret"], model)
    a[label] = {"model": model, "status": status, "error": msg}
owner.mutate("aiGateway.updateConnectionModels", {"orgId": ORG, "id": CID,
             "allowedModels": None, "expectedUpdatedAt": conn_updated_at()})
a["after_reset_alias"] = call(keys["alice-laptop"]["secret"], "claude-haiku-4-5")[0]
out["allowlist"] = a
print(f"A allowlist   listed {a['listed']} · dated {a['dated']['status']} · alias {a['alias']['status']} "
      f"· prefixed {a['prefixed_dated']['status']} · other {a['other_model']['status']} · after reset {a['after_reset_alias']}")

# B — key expiry ------------------------------------------------------------------------------
expires = L.now() + timedelta(seconds=40)
k = alice.mutate("aiGateway.createApiKey", {"orgId": ORG, "name": "alice-short", "metadata": {"team": "platform"},
                                            "expiresAt": expires, "issuedAs": "user"})
first = call(k["secretKey"])[0]
time.sleep(max(0.0, (expires - L.now()).total_seconds()))
b = {"expires_at": expires.isoformat(), "before_expiry": first, **poll(k["secretKey"], 401, time.monotonic(), 90)}
out["expiry"] = b
print(f"B expiry      before {first} · 401 reached {b['reached']} {b['after_s']} s after expiresAt ({b['calls']} calls)")

# C — revocation ------------------------------------------------------------------------------
k = bob.mutate("aiGateway.createApiKey", {"orgId": ORG, "name": "bob-temp", "metadata": {"team": "data"}, "issuedAs": "user"})
warm = [call(k["secretKey"])[0] for _ in range(2)]  # second call is served from the resolve cache
bob.mutate("aiGateway.revokeApiKey", {"orgId": ORG, "id": k["id"]})
c = {"before": warm, **poll(k["secretKey"], 401, time.monotonic(), 90, every=1.0)}
out["revocation"] = c
print(f"C revocation  before {warm} · 401 reached {c['reached']} {c['after_s']} s after revoke ({c['calls']} calls)")

# D — losing gateway access (role change) -----------------------------------------------------------
members = owner.query("members.allFromOrg", {"orgId": ORG, "page": 0, "limit": 50})
row = next(m for m in members["memberships"] if m.get("email") == people["bob"]["email"]
           or m.get("user", {}).get("email") == people["bob"]["email"])
mid = row.get("orgMembershipId") or row.get("id")
bob_key, bob_key_id = keys["bob-laptop"]["secret"], keys["bob-laptop"]["id"]
d = {"before": call(bob_key)[0]}
owner.mutate("members.updateOrgMembership", {"orgId": ORG, "orgMembershipId": mid, "role": "VIEWER"})
d["to_viewer"] = poll(bob_key, 401, time.monotonic(), 60, every=1.0)
d["key_rows_after_viewer"] = int(L.psql(f"SELECT count(*) FROM api_keys WHERE id = '{bob_key_id}'"))
owner.mutate("members.updateOrgMembership", {"orgId": ORG, "orgMembershipId": mid, "role": "AI_GATEWAY"})
time.sleep(2)
d["old_key_after_restore"] = call(bob_key)[0]
# bob issues a new key under the same name; later runs of 03-calls.py use it.
k = bob.mutate("aiGateway.createApiKey", {"orgId": ORG, "name": "bob-laptop", "metadata": keys["bob-laptop"]["metadata"], "issuedAs": "user"})
keys["bob-laptop"] = {**keys["bob-laptop"], "id": k["id"], "secret": k["secretKey"]}
L.update_state(keys=keys)
d["new_key"] = call(k["secretKey"])[0]
out["role_change"] = d
print(f"D role change before {d['before']} · VIEWER → 401 after {d['to_viewer']['after_s']} s · key rows left {d['key_rows_after_viewer']} "
      f"· back to AI_GATEWAY: old key {d['old_key_after_restore']} · new key {d['new_key']}")

# E — USAGE ingestion mode -----------------------------------------------------------------------
owner.mutate("aiGateway.updateConfig", {"orgId": ORG, "defaultIngestionProjectId": st["project_id"], "ingestionMode": "USAGE"})
status, _, trace = call(keys["alice-laptop"]["secret"])
owner.mutate("aiGateway.updateConfig", {"orgId": ORG, "defaultIngestionProjectId": st["project_id"], "ingestionMode": "FULL"})
out["usage_mode"] = {"status": status, "trace_id": trace}
print(f"E USAGE mode  HTTP {status} trace {trace} (mode back to FULL)")

# Who may do what (negative): an AI Gateway member cannot add a provider credential.
try:
    bob.mutate("aiGateway.createConnection", {"orgId": ORG, "name": "bob-own", "provider": "ANTHROPIC", "credential": "sk-ant-not-a-key"})
    out["member_create_connection"] = {"allowed": True}
except TrpcError as err:
    out["member_create_connection"] = {"allowed": False, "status": err.status, "code": err.code}
print(f"· AI Gateway role → createConnection: {out['member_create_connection']}")

L.update_state(controls=out, controls_at=L.now().isoformat())
print("→ recorded in .run/state.json — next: 05-check.py")
