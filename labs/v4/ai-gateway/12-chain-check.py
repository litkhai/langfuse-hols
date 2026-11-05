"""Step 12 — checks for 11-chain.py: LiteLLM Proxy in front of the Langfuse AI Gateway (#91).

  .venv-v4/bin/python labs/v4/ai-gateway/12-chain-check.py

Pairs each LiteLLM generation of the model haiku-via-gateway with the gateway generation that
follows it within 2 s (same Langfuse project), then checks what each side recorded. Exit 1 on FAIL.
"""

from __future__ import annotations

import sys
import time
from datetime import datetime, timedelta

import lablib as L

st = L.state()
ch = st["chain"]
rows: list[tuple[bool | None, str, str]] = []


def check(ok, what, detail=""):
    ok = None if ok is None else bool(ok)
    rows.append((ok, what, detail))
    print(f"{ {True: 'PASS', False: 'FAIL', None: 'INFO'}[ok] }  {what}{'  — ' + detail if detail else ''}")


def m(k: str) -> str:
    return f"metadata_values[indexOf(metadata_names, '{k}')]"


since = datetime.fromisoformat(ch["since"]).strftime("%Y-%m-%d %H:%M:%S")
until = (datetime.fromisoformat(ch["until"]) + timedelta(seconds=2)).strftime("%Y-%m-%d %H:%M:%S")  # start_time has ms
time.sleep(5)
gens = L.ch(f"""SELECT start_time, service_name, trace_id, user_id, tags, total_cost, provided_model_name AS model,
                       {m('langfuse.gateway.api_key.name')} AS gw_key, {m('langfuse.gateway.user_id_source')} AS gw_src,
                       {m('attributes.litellm.call_id')} AS call_id, {m('attributes.litellm.metadata.user_api_key_alias')} AS ll_alias
                FROM events_full FINAL
                WHERE project_id = '{st['project_id']}' AND type = 'GENERATION' AND start_time BETWEEN '{since}' AND '{until}'
                ORDER BY start_time FORMAT JSONEachRow""")
ll = [g for g in gens if g["service_name"] == "litellm" and g["model"] == "haiku-via-gateway"]
gw = [g for g in gens if g["service_name"] == "langfuse-ai-gateway"]


def ts(g):
    return datetime.fromisoformat(g["start_time"])


pairs = []
for a in ll:
    b = next((g for g in gw if 0 <= (ts(g) - ts(a)).total_seconds() <= 2), None)
    pairs.append((a, b))

print(f"── chain run · {len(ll)} LiteLLM generations of haiku-via-gateway · {len(gw)} gateway generations")
check(ch["k1"]["status"] == 200, "k1 LiteLLM → gateway → Anthropic answers", f"HTTP {ch['k1']['status']} · response model '{ch['k1']['model']}'")
check(all(b for _, b in pairs) and len(gw) == len(ll), "every call that reached the gateway is recorded by the gateway", f"{sum(1 for _, b in pairs if b)} of {len(ll)} paired")
check(None, "each chained call is recorded twice in the project (LiteLLM and gateway)",
      f"{len(ll)} + {len(gw)} generations · cost {round(sum(a['total_cost'] for a in ll), 6)} + {round(sum(g['total_cost'] for g in gw), 6)} USD")
check(all(b and b["gw_key"] == "litellm-upstream" and b["user_id"] == "litellm-upstream" and b["gw_src"] == "api_key_name" for _, b in pairs),
      "the gateway sees one identity: LiteLLM's service account key", f"users {sorted({b['user_id'] for _, b in pairs if b})} · LiteLLM keys {sorted({a['ll_alias'] for a, _ in pairs})}")
k2 = next((b for a, b in pairs if a["call_id"] == ch["k2"]["call_id"]), None)
check(None, "k2 client headers on the gateway's record (langfuse-user-id, x-pass-langfuse-user-id, x-pass-langfuse-tags)",
      f"user {k2['user_id'] if k2 else '-'} · tags {k2['tags'] if k2 else '-'}")
check(all(b and a["trace_id"] != b["trace_id"] for a, b in pairs), "the two records of a call are in separate traces (LiteLLM sends no traceparent upstream)",
      f"{sum(1 for a, b in pairs if b and a['trace_id'] != b['trace_id'])} of {len(pairs)} separate")
seq = ch["k3"]["sequence"]
budget_calls = [x["call_id"] for x in seq if x["status"] == 200]
check(seq[-1]["status"] in (400, 403, 422, 429) and len([a for a, _ in pairs if a["call_id"] in budget_calls]) == len(budget_calls),
      "k3 LiteLLM's spend cap stops the call before it reaches the gateway", f"{[(x['n'], x['status']) for x in seq]} · gateway records {len(budget_calls)} of them")
k4 = next((b for a, b in pairs if a["call_id"] == ch["k4"]["call_id"]), None)
check(ch["k4"]["status"] == 200 and str(ch["k4"]["attempted_fallbacks"]) == "1" and k4 is not None,
      "k4 fallback haiku-broken-chain → haiku-via-gateway, recorded by the gateway", f"HTTP {ch['k4']['status']} · attempted {ch['k4']['attempted_fallbacks']}")
fails = [w for ok, w, _ in rows if ok is False]
print(f"── {sum(1 for ok, *_ in rows if ok)} PASS · {len(fails)} FAIL · {sum(1 for ok, *_ in rows if ok is None)} INFO")
sys.exit(1 if fails else 0)
