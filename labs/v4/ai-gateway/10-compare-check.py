"""Step 10 — checks on LiteLLM Proxy's side, and the side-by-side table with the gateway (#89).

  .venv-v4/bin/python labs/v4/ai-gateway/10-compare-check.py

Reads what 09-litellm-calls.py recorded, the generations LiteLLM exported to the same Langfuse project
(service_name = litellm, through langfuse_otel), LiteLLM's Postgres and container, and the gateway's
results from 03–05. Exit 1 when a check fails. INFO rows are measurements, not pass/fail.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from datetime import datetime

import lablib as L

e = L.env()
st = L.state()
lt = st["litellm"]
calls, ctl, keys = lt["calls"], lt["controls"], lt["keys"]
rows: list[tuple[bool | None, str, str]] = []


def check(ok, what, detail=""):
    ok = None if ok is None else bool(ok)
    rows.append((ok, what, detail))
    print(f"{ {True: 'PASS', False: 'FAIL', None: 'INFO'}[ok] }  {what}{'  — ' + detail if detail else ''}")


def md(k: str) -> str:
    return f"metadata_values[indexOf(metadata_names, 'attributes.litellm.metadata.{k}')]"


def gen(call_id: str | None, wait_s: int = 90) -> dict | None:
    """LiteLLM's generation for one call (langfuse.observation.id carries litellm.call_id in metadata)."""
    if not call_id:
        return None
    deadline = time.monotonic() + wait_s
    while True:
        r = L.ch(f"""SELECT *, {md('user_api_key_alias')} AS alias, {md('user_api_key_user_id')} AS key_user,
                            {md('user_api_key_end_user_id')} AS end_user,
                            metadata_values[indexOf(metadata_names, 'attributes.litellm.team.id')] AS team,
                            metadata_values[indexOf(metadata_names, 'attributes.gen_ai.response.model')] AS response_model
                     FROM events_full FINAL
                     WHERE project_id = '{st['project_id']}' AND service_name = 'litellm' AND has(metadata_values, '{call_id}')
                     FORMAT JSONEachRow""")
        if r or time.monotonic() > deadline:
            return r[0] if r else None
        time.sleep(3)


def psql_litellm(sql: str) -> str:
    return subprocess.run(["docker", "exec", f"{L.PROJECT}-litellm-db-1", "psql", "-U", "litellm", "-d", "litellm", "-At", "-c", sql],
                          capture_output=True, text=True, check=True).stdout.strip()


print(f"── LiteLLM run {lt.get('run_id')}{' (FAULT)' if lt.get('fault') else ''} · LiteLLM {subprocess.run(['docker', 'inspect', '-f', '{{.Config.Image}}', f'{L.PROJECT}-litellm-1'], capture_output=True, text=True).stdout.strip()}")

# 1. Client change, attribution, what lands in Langfuse ------------------------------------------------
c = calls["l1-sdk-basic"]; g = gen(c["call_id"])
check(c["http_status"] == 200 and bool(g), "l1 Anthropic SDK through LiteLLM; generation exported to Langfuse",
      f"HTTP {c['http_status']} '{c['text']}' · {g['name'] if g else 'no generation'}")
if g:
    check(g["alias"] == "alice-laptop" and g["key_user"] == "alice" and float(g["cost_details"].get("total", 0)) > 0 and g["input"] and g["output"],
          "l1 key alias, key owner, cost, input and output on the generation",
          f"alias {g['alias']} · owner {g['key_user']} · cost {g['cost_details'].get('total')} · input {g['input'][:50]}")
    check(None, "l1 model in the response LiteLLM returns vs Anthropic's", f"client got '{c['response_model']}' · Anthropic answered '{g['response_model']}'")
c = calls["l2-sdk-stream"]; g = gen(c["call_id"])
check(bool(g) and bool(g["output"]), "l2 streamed call exported with output", f"{g['output'][:60] if g else '-'}")
c = calls["l3-user-override"]; g = gen(c["call_id"])
check(bool(g) and g["key_user"] == "bob" and g["end_user"] == "mallory@example.com",
      "l3 key owner stays bob; x-litellm-end-user-id is recorded as a separate end user", f"owner {g['key_user'] if g else '-'} · end user {g['end_user'] if g else '-'}")
c = calls["l4-service-end-user"]; g = gen(c["call_id"])
check(bool(g) and g["end_user"] == "end-user-42" and g["team"] == "payments" and sorted(g["tags"]) == c["tags"],
      "l4 service account key: end user, team and tags", f"end user {g['end_user'] if g else '-'} · team {g['team'] if g else '-'} · tags {g['tags'] if g else '-'}")
c = calls["l5-service-default"]; g = gen(c["call_id"])
check(bool(g) and g["alias"] == "checkout-service" and not g["key_user"] and not g["end_user"],
      "l5 service account key without headers: key alias only", f"alias {g['alias'] if g else '-'}")
users = L.ch("SELECT countIf(user_id != '') AS with_user, count() AS n FROM events_full FINAL WHERE service_name = 'litellm' AND type = 'GENERATION' FORMAT JSONEachRow")[0]
check(None, "Langfuse user field on LiteLLM generations (identity is in metadata)", f"{users['with_user']} of {users['n']} generations have user_id")

# 2. traceparent ------------------------------------------------------------------------------------
c = calls["l6-sdk-traceparent"]; g = gen(c["call_id"])
check(bool(g) and g["trace_id"] == c["app_trace_id"], "l6 LiteLLM generation lands in the app's trace (traceparent)",
      f"generation trace {g['trace_id'] if g else '-'} · app {c['app_trace_id']}")
check(None, "l6 parent of the LiteLLM generation", f"parent '{g['parent_span_id'] if g else '-'}' · app span {c['app_span_id']}")

# 3. Claude Code ---------------------------------------------------------------------------------------
c = calls.get("l7-claude-code")
if c:
    since = datetime.fromisoformat(c["since"]).strftime("%Y-%m-%d %H:%M:%S")
    until = datetime.fromisoformat(lt["calls_at"]).strftime("%Y-%m-%d %H:%M:%S")
    cc = L.ch(f"""SELECT trace_id, session_id, provided_model_name, usage_details, total_cost FROM events_full FINAL
                  WHERE service_name = 'litellm' AND start_time BETWEEN '{since}' AND '{until}' AND {md('user_api_key_alias')} = 'alice-laptop'
                  FORMAT JSONEachRow""")
    check(c["exit"] == 0 and "hello gateway" in c["stdout"].lower() and bool(cc) and all(r["session_id"] for r in cc),
          "l7 claude -p through LiteLLM; generations carry Claude Code's session",
          f"{len(cc)} generations · sessions {sorted({r['session_id'][:8] for r in cc})} · cost {[round(r['total_cost'], 6) for r in cc]}")
else:
    check(None, "l7 Claude Code not run")

# 4. Controls ---------------------------------------------------------------------------------------------
a = ctl["model_restriction"]
check(a["dated"]["status"] == 200 and a["alias"]["status"] in (401, 403), "model restriction by exact name: dated ID allowed, alias refused",
      f"dated {a['dated']['status']} · alias {a['alias']['status']} {a['alias']['error'][:70]}")
b = ctl["expiry"]
check(b["before_expiry"] == 200 and b["reached"] and b["after_s"] <= 10, "expiry: 401 within 10 s of the 40 s duration", f"{b['after_s']} s, {b['calls']} calls")
r = ctl["revocation"]
check(r["before"] == [200, 200] and r["reached"] and r["calls"] == 1, "key delete: the first call after it gets 401", f"{r['after_s']} s")
d = ctl["user_delete"]
check(d["before"] == 200 and d["reached"] and d["key_info_after"] == 404, "user delete: the user's key stops and is gone", f"401 after {d['after_s']} s · key/info {d['key_info_after']}")
sc = ctl["spend_cap"]; last = sc["sequence"][-1]
check(last["status"] in (400, 403, 422, 429) and "budget" in last["error"].lower(),
      "spend cap: a call over max_budget is refused", f"max_budget {sc['max_budget']} · call {last['n']} → {last['status']} {last['error'][:90]}")
rl = ctl["rate_limit"]
check(rl["statuses"][:2] == [200, 200] and rl["statuses"][2] == 429, "rate limit: rpm_limit 2, third call in the minute gets 429", f"{rl['statuses']}")
fb = ctl["fallback"]; gw = ctl["gateway_failing_model"]
check(fb["status"] == 200 and str(fb["attempted_fallbacks"]) == "1", "fallback: haiku-broken fails, LiteLLM answers from claude-haiku-4-5",
      f"HTTP {fb['status']} · attempted fallbacks {fb['attempted_fallbacks']}")
check(gw["status"] >= 400, "gateway with a failing model: the error goes to the client (no fallback setting)", f"HTTP {gw['status']} {gw['error'][:70]}")
lat = ctl["latency"]
check(None, "latency, 5 calls each after one warm-up (client-side ms, same host)", " · ".join(f"{k} {v['median']}" for k, v in lat.items()))

# 5. Keys, credentials, audit -------------------------------------------------------------------------------
dump = subprocess.run(["docker", "exec", f"{L.PROJECT}-litellm-db-1", "pg_dump", "-U", "litellm", "-d", "litellm", "--data-only"],
                      capture_output=True, text=True, check=True).stdout
check(all(k["secret"] not in dump for k in keys.values()), "LiteLLM stores virtual keys hashed (pg_dump of its database)", f"{dump.count(chr(10))} lines searched")
env = subprocess.run(["docker", "inspect", "-f", "{{json .Config.Env}}", f"{L.PROJECT}-litellm-1"], capture_output=True, text=True, check=True).stdout
check(None, "provider key in the LiteLLM container's environment (as this lab configures it)", f"present: {e['ANTHROPIC_API_KEY'] in env}")
audit_rows = psql_litellm('SELECT count(*) FROM "LiteLLM_AuditLog"')
check(None, "LiteLLM audit log without a licence", f"LiteLLM_AuditLog rows: {audit_rows}")

# 6. Spend of both runs as Langfuse priced them ---------------------------------------------------------------
spend = L.ch("""SELECT service_name, count() AS n, round(sum(total_cost), 5) AS usd FROM events_full FINAL
                WHERE type = 'GENERATION' AND service_name IN ('litellm', 'langfuse-ai-gateway') GROUP BY service_name FORMAT JSONEachRow""")
check(None, "generations and cost per gateway in this Langfuse project", " · ".join(f"{r['service_name']} {r['n']} calls {r['usd']} USD" for r in spend))

fails = [w for ok, w, _ in rows if ok is False]
print(f"── {sum(1 for ok, *_ in rows if ok)} PASS · {len(fails)} FAIL · {sum(1 for ok, *_ in rows if ok is None)} INFO")
sys.exit(1 if fails else 0)
