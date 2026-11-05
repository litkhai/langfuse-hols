"""Helper of 06-ee-audit.sh: create and revoke one gateway key, then count its audit records.

  06-audit-probe.py oss | ee     # probe in the current mode, record the counts
  06-audit-probe.py judge        # PASS/FAIL over both probes (exit 1 on FAIL)
"""

from __future__ import annotations

import sys
import time

import lablib as L
from lablib import Session

mode = sys.argv[1]
e = L.env()
st = L.state()


psql = L.psql


def counts(key_id: str) -> dict:
    pg = psql(f"SELECT coalesce(string_agg(action, ',' ORDER BY created_at), '') FROM audit_logs WHERE resource_id = '{key_id}'")
    has_ch = L.ch("SELECT count() AS n FROM system.tables WHERE database = currentDatabase() AND name = 'audit_logs' FORMAT JSONEachRow")[0]["n"]
    chs = ""
    if has_ch:
        chs = ",".join(r["action"] for r in L.ch(f"SELECT action FROM audit_logs WHERE resource_id = '{key_id}' ORDER BY timestamp FORMAT JSONEachRow"))
    return {"postgres": pg, "clickhouse": chs if has_ch else "no table"}


if mode in ("oss", "ee"):
    alice = Session(st["people"]["alice"]["email"], st["people"]["alice"]["password"])
    k = alice.mutate("aiGateway.createApiKey", {"orgId": st["org_id"], "name": f"audit-probe-{mode}",
                                                "metadata": {"team": "platform"}, "issuedAs": "user"})
    alice.mutate("aiGateway.revokeApiKey", {"orgId": st["org_id"], "id": k["id"]})
    time.sleep(15)  # the staging relay moves audit events to ClickHouse asynchronously
    c = counts(k["id"])
    audit = st.get("audit", {})
    audit[mode] = {"key_id": k["id"], **c}
    L.update_state(audit=audit)
    print(f"  {mode}: key {k['id']} · audit records Postgres [{c['postgres']}] · ClickHouse [{c['clickhouse']}]")
else:
    a = st["audit"]
    ok_oss = not a["oss"]["postgres"] and a["oss"]["clickhouse"] in ("", "no table")
    ee_actions = a["ee"]["postgres"] or a["ee"]["clickhouse"]
    ok_ee = "create" in ee_actions and "delete" in ee_actions
    print(f"{'PASS' if ok_oss else 'FAIL'}  OSS (no licence): no audit records for a created and revoked gateway key")
    print(f"{'PASS' if ok_ee else 'FAIL'}  EE licence: create and delete are recorded — Postgres [{a['ee']['postgres']}] · ClickHouse [{a['ee']['clickhouse']}]")
    sys.exit(0 if ok_oss and ok_ee else 1)
