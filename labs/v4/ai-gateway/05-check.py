"""Step 05 — checks against this lab's ClickHouse (events_full), Postgres, the gateway container and
the Langfuse v2 observations API. Exit 1 when any check fails.

  .venv-v4/bin/python labs/v4/ai-gateway/05-check.py

Reads the IDs that 03-calls.py and 04-controls.py recorded in .run/state.json. The provider key is
compared, never printed.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from datetime import datetime

import httpx

import lablib as L

e = L.env()
st = L.state()
calls, controls, people, keys = st["calls"], st.get("controls", {}), st["people"], st["keys"]
ALICE, BOB = people["alice"]["email"], people["bob"]["email"]
rows: list[tuple[bool | None, str, str]] = []


def check(ok: bool | None, what: str, detail: str = "") -> None:
    rows.append((ok, what, detail))
    mark = {True: "PASS", False: "FAIL", None: "INFO"}[ok]
    print(f"{mark}  {what}{'  — ' + detail if detail else ''}")


def gen(trace_id: str | None, wait_s: int = 90) -> dict | None:
    """The gateway generation of a trace, once the worker has written it."""
    if not trace_id:
        return None
    deadline = time.monotonic() + wait_s
    while True:
        r = L.ch(f"""SELECT * FROM events_full FINAL
                     WHERE project_id = '{st['project_id']}' AND trace_id = '{trace_id}'
                       AND service_name = 'langfuse-ai-gateway' AND type = 'GENERATION'
                     FORMAT JSONEachRow""")
        if r or time.monotonic() > deadline:
            if r:
                r[0]["meta"] = dict(zip(r[0]["metadata_names"], r[0]["metadata_values"]))
            return r[0] if r else None
        time.sleep(3)


psql = L.psql


print(f"── run {st.get('run_id')}{' (FAULT)' if st.get('fault') else ''} · Langfuse {L.state().get('version', '4.75.0')}")

# 1. Only base URL and key change: s1 --------------------------------------------------------------
c = calls["s1-sdk-basic"]
g = gen(c["trace_id"])
check(c["http_status"] == 200 and c["provider"] == "anthropic", "s1 Anthropic SDK through the gateway answers like Anthropic",
      f"HTTP {c['http_status']}, '{c['text']}', provider header {c['provider']}, Anthropic request-id {c['provider_request_id']}")
check(g is not None, "s1 response header langfuse-trace-id points at a stored generation", f"trace {c['trace_id']}")
if g:
    check(g["name"] == "anthropic.messages" and g["provided_model_name"] == "claude-haiku-4-5-20251001",
          "s1 generation: API format as name, the provider's dated model", f"{g['name']} · {g['provided_model_name']} (requested {g['meta'].get('langfuse.gateway.model.requested')})")
    check(g["usage_details"].get("input_tokens", 0) > 0 and float(g["cost_details"].get("total", 0)) > 0,
          "s1 usage and cost recorded", f"usage {g['usage_details']} · cost total {g['cost_details'].get('total')} USD")
    check("pong" in (g["input"] or "") and "pong" in (g["output"] or "").lower(), "s1 FULL mode stores input and output",
          f"input {g['input'][:70]}…")
    check(g["user_id"] == ALICE and g["meta"].get("langfuse.gateway.user_id_source") == "api_key_owner",
          "s1 user key → trace user is the key owner", f"user {g['user_id']} · source {g['meta'].get('langfuse.gateway.user_id_source')}")
    check(g["meta"].get("langfuse.gateway.api_key.name") == "alice-laptop" and g["meta"].get("langfuse.gateway.api_key.metadata.team") == "platform",
          "s1 key name and key metadata on the generation", f"key {g['meta'].get('langfuse.gateway.api_key.name')} · team {g['meta'].get('langfuse.gateway.api_key.metadata.team')} · cost_center {g['meta'].get('langfuse.gateway.api_key.metadata.cost_center')}")

# 2. Streaming ---------------------------------------------------------------------------------
c = calls["s2-sdk-stream"]
g = gen(c["trace_id"])
check(bool(g) and bool(g["output"]) and g["completion_start_time"] is not None,
      "s2 streamed call: output and time to first token recorded",
      f"start {g['start_time'] if g else '-'} · first token {g['completion_start_time'] if g else '-'}")

# 3. A user key cannot claim another user ------------------------------------------------------------
c = calls["s3-user-key-override"]
g = gen(c["trace_id"])
check(bool(g) and g["user_id"] == BOB, "s3 user key ignores langfuse-user-id: mallory@example.com", f"user {g['user_id'] if g else '-'}")

# 4. Service account forwards the end user and context ------------------------------------------------
c = calls["s4-service-end-user"]
g = gen(c["trace_id"])
check(bool(g) and g["user_id"] == "end-user-42" and g["meta"].get("langfuse.gateway.user_id_source") == "client",
      "s4 service account key + langfuse-user-id → end user", f"user {g['user_id'] if g else '-'} · source {g['meta'].get('langfuse.gateway.user_id_source') if g else '-'}")
if g:
    check(g["session_id"] == c["session"] and g["environment"] == "production" and sorted(g["tags"]) == c["tags"]
          and g["trace_name"] == "checkout-summary",
          "s4 session, environment, tags and trace name from headers", f"{g['session_id']} · {g['environment']} · {g['tags']} · {g['trace_name']}")
    check(g["meta"].get("order") == "A-1001" and g["meta"].get("region") == "kr" and g["meta"].get("langfuse.gateway.api_key.metadata.cost_center") == "3003",
          "s4 request metadata next to the key's own metadata", "order A-1001 · region kr · cost_center 3003")

# 5. Service account without headers ------------------------------------------------------------------
c = calls["s5-service-default"]
g = gen(c["trace_id"])
check(bool(g) and g["user_id"] == "checkout-service" and g["meta"].get("langfuse.gateway.user_id_source") == "api_key_name",
      "s5 service account key without headers → key name as user", f"user {g['user_id'] if g else '-'}")

# 6. traceparent ----------------------------------------------------------------------------------------
c = calls["s6-sdk-traceparent"]
g = gen(c["trace_id"])
check(c["trace_id"] == c["app_trace_id"], "s6 gateway reuses the app's trace ID from traceparent",
      f"gateway {c['trace_id']} · app {c['app_trace_id']}")
check(bool(g) and g["parent_span_id"] == c["app_span_id"], "s6 generation is a child of the app's span",
      f"parent {g['parent_span_id'] if g else '-'} · app span {c['app_span_id']}")
app = L.ch(f"SELECT name, service_name FROM events_full FINAL WHERE trace_id = '{c['app_trace_id']}' AND span_id = '{c['app_span_id']}' FORMAT JSONEachRow")
check(bool(app), "s6 the app's own span is in the same trace", f"{app[0] if app else 'missing'}")

# 7. Claude Code ------------------------------------------------------------------------------------
c = calls.get("s7-claude-code")
if c:
    since = datetime.fromisoformat(c["since"]).strftime("%Y-%m-%d %H:%M:%S")
    until = datetime.fromisoformat(st["calls_at"]).strftime("%Y-%m-%d %H:%M:%S")  # end of 03-calls.py
    time.sleep(5)
    cc = L.ch(f"""SELECT trace_id, session_id, provided_model_name, user_id, usage_details,
                         metadata_values[indexOf(metadata_names, 'agent.name')] AS agent,
                         metadata_values[indexOf(metadata_names, 'langfuse.gateway.client.user_agent')] AS ua
                  FROM events_full FINAL
                  WHERE project_id = '{st['project_id']}' AND service_name = 'langfuse-ai-gateway'
                    AND start_time BETWEEN '{since}' AND '{until}'
                    AND metadata_values[indexOf(metadata_names, 'langfuse.gateway.api_key.name')] = 'alice-laptop'
                    AND metadata_values[indexOf(metadata_names, 'langfuse.gateway.client.user_agent')] LIKE 'claude-cli/%'
                  ORDER BY start_time FORMAT JSONEachRow""")
    check(c["exit"] == 0 and "hello gateway" in c["stdout"].lower(), "s7 claude -p through the gateway",
          f"{c['claude_version']} · exit {c['exit']} · '{c['stdout'][:40]}'")
    check(bool(cc) and all(r["session_id"].startswith("claude-code:") and r["agent"] == "claude-code" and r["user_id"] == ALICE for r in cc),
          "s7 Claude Code calls: session claude-code:<id>, agent.name claude-code, user = key owner",
          f"{len(cc)} generations · {len({r['trace_id'] for r in cc})} traces · {len({r['session_id'] for r in cc})} session · "
          f"models {sorted({r['provided_model_name'] for r in cc})} · input tokens {[r['usage_details'].get('input_tokens') for r in cc]} · {cc[0]['ua'] if cc else ''}")
else:
    check(None, "s7 Claude Code not run (SKIP_CLAUDE_CODE=1 or no claude on PATH)")

# 8. Cost per user, key and model — the same question the gateway's Analytics page answers ---------------
agg = L.ch(f"""SELECT user_id,
                      metadata_values[indexOf(metadata_names, 'langfuse.gateway.api_key.name')] AS key_name,
                      metadata_values[indexOf(metadata_names, 'langfuse.gateway.api_key.metadata.team')] AS team,
                      provided_model_name AS model, count() AS calls,
                      sum(usage_details['input']) + sum(usage_details['input_tokens']) AS input_tokens,
                      round(sum(total_cost), 6) AS cost_usd
               FROM events_full FINAL
               WHERE project_id = '{st['project_id']}' AND has(metadata_names, 'langfuse.gateway.api_key.id')
               GROUP BY user_id, key_name, team, model ORDER BY cost_usd DESC FORMAT JSONEachRow""")
check(len({r["user_id"] for r in agg}) >= 4 and all(r["key_name"] for r in agg),
      "cost per user, key and model from events_full (one GROUP BY)", f"{len(agg)} groups")
for r in agg:
    print(f"        {r['user_id']:22} {r['key_name']:16} {r['team']:9} {r['model']:28} {r['calls']:>3} calls  {r['cost_usd']:.6f} USD")

# 9. Keys and credentials at rest -------------------------------------------------------------------------
cred = psql("SELECT encrypted_credentials || '|' || display_secret_key FROM gateway_ai_connections WHERE name = 'anthropic-lab'")
pk = e["ANTHROPIC_API_KEY"]
check(bool(cred) and pk not in cred and pk[-8:] not in cred.split("|")[0],
      "provider key is stored encrypted in Postgres (gateway_ai_connections)",
      f"UI shows {cred.split('|')[-1].split('...')[0]}...<last 4> · stored value {len(cred.split('|')[0])} chars")
dump = subprocess.run(["docker", "exec", f"{L.PROJECT}-postgres-1", "pg_dump", "-U", e.get("POSTGRES_USER", "postgres"),
                       "-d", e.get("POSTGRES_DB", "postgres"), "--data-only", "-t", "api_keys"],
                      capture_output=True, text=True, check=True).stdout
check(all(k["secret"] not in dump for k in keys.values()), "gateway keys are not stored in plain text (pg_dump of api_keys)",
      f"{dump.count(chr(10))} lines searched")
genv = subprocess.run(["docker", "inspect", "-f", "{{json .Config.Env}}", f"{L.PROJECT}-ai-gateway-1"],
                      capture_output=True, text=True, check=True).stdout
check(pk not in genv and "sk-ant" not in genv, "gateway container has no provider key in its environment",
      f"{len(json.loads(genv))} variables")

# 10. Controls ------------------------------------------------------------------------------------------
if controls:
    a = controls["allowlist"]
    check(a["listed"] == [f"{L.CONNECTION}:claude-haiku-4-5-20251001"], "allowlist: the model list shows only the allowed model", f"{a['listed']}")
    check(a["dated"]["status"] == 200 and a["prefixed_dated"]["status"] == 200, "allowlist: allowed dated ID passes, with and without prefix",
          f"{a['dated']['status']} / {a['prefixed_dated']['status']}")
    check(a["other_model"]["status"] in (400, 403, 404), "allowlist: another model is refused before the provider",
          f"HTTP {a['other_model']['status']} {a['other_model']['error']}")
    check(None, "allowlist: the alias of the allowed model (claude-haiku-4-5)",
          f"HTTP {a['alias']['status']} {a['alias']['error']}")
    check(a["after_reset_alias"] == 200, "allowlist reset to all models: alias works again", f"HTTP {a['after_reset_alias']}")
    b = controls["expiry"]
    check(b["before_expiry"] == 200 and b["reached"] and b["after_s"] <= 10, "expiry: key works, then 401 within 10 s of expiresAt",
          f"401 after {b['after_s']} s, {b['calls']} calls")
    r = controls["revocation"]
    check(r["before"] == [200, 200] and r["reached"] and r["calls"] == 1, "revocation: the first call after revoke gets 401",
          f"401 after {r['after_s']} s on call {r['calls']}")
    d = controls["role_change"]
    check(d["before"] == 200 and d["to_viewer"]["reached"] and d["to_viewer"]["calls"] == 1,
          "role change to VIEWER: the user key stops on the next call", f"401 after {d['to_viewer']['after_s']} s")
    check(d["key_rows_after_viewer"] == 0, "role change to VIEWER deletes the user's gateway keys", f"api_keys rows left: {d['key_rows_after_viewer']}")
    check(d["old_key_after_restore"] == 401 and d["new_key"] == 200, "role back to AI_GATEWAY: the old key stays dead, a new key works",
          f"old {d['old_key_after_restore']} · new {d['new_key']}")
    u = controls["usage_mode"]
    g = gen(u["trace_id"])
    check(bool(g) and not g["input"] and not g["output"] and g["usage_details"].get("input_tokens", 0) > 0
          and g["meta"].get("langfuse.gateway.ingestion.mode") == "usage",
          "USAGE mode: usage and cost without input or output", f"input {g['input']!r} · output {g['output']!r} · cost {g['cost_details'].get('total') if g else '-'}")
    m = controls["member_create_connection"]
    check(m["allowed"] is False, "AI Gateway role cannot add a provider credential", f"HTTP {m.get('status')} {m.get('code')}")
else:
    check(None, "controls not run (04-controls.py)")

# 11. Audit log ----------------------------------------------------------------------------------------
pg_rows = psql("SELECT count(*) FROM audit_logs WHERE resource_type = 'apiKey'")
ch_rows = L.ch("SELECT count() AS n FROM system.tables WHERE database = currentDatabase() AND name = 'audit_logs' FORMAT JSONEachRow")[0]["n"]
ch_count = L.ch("SELECT count() AS n FROM audit_logs WHERE resource_type = 'apiKey' FORMAT JSONEachRow")[0]["n"] if ch_rows else "no table"
ee = subprocess.run(["docker", "inspect", "-f", "{{json .Config.Env}}", f"{L.PROJECT}-langfuse-web-1"], capture_output=True, text=True).stdout
licensed = '"LANGFUSE_EE_LICENSE_KEY=' in ee and '"LANGFUSE_EE_LICENSE_KEY="' not in ee
check(None, f"audit log entries for gateway keys ({'EE licence set' if licensed else 'OSS, no licence'})",
      f"Postgres audit_logs {pg_rows} · ClickHouse audit_logs {ch_count}")

# 12. The same generation through the public API ---------------------------------------------------------
auth = (e["LANGFUSE_INIT_PROJECT_PUBLIC_KEY"], e["LANGFUSE_INIT_PROJECT_SECRET_KEY"])
api = httpx.get(f"{L.WEB}/api/public/v2/observations", params={"traceId": calls["s1-sdk-basic"]["trace_id"]}, auth=auth, timeout=30)
obs = api.json().get("data", []) if api.status_code == 200 else []
check(bool(obs) and obs[0].get("type") == "GENERATION", "v2 observations API returns the s1 generation",
      f"HTTP {api.status_code} · {[(o.get('type'), o.get('name'), o.get('id')) for o in obs]}")

fails = [w for ok, w, _ in rows if ok is False]
print(f"── {sum(1 for ok, *_ in rows if ok)} PASS · {len(fails)} FAIL · {sum(1 for ok, *_ in rows if ok is None)} INFO")
sys.exit(1 if fails else 0)
