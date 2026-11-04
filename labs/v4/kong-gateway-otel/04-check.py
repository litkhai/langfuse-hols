"""Check what arrived, in ClickHouse (events_full) and through the Langfuse v2 observations API.

Reads the trace IDs that 02 and 03 wrote to .run/traces.env. Read-only: ClickHouse is queried
with `docker exec langfuse-hols-v4-clickhouse-1 clickhouse-client` (retried, since the shared
stack may restart it), Langfuse with the project keys.
Run with the v4 venv:  .venv-v4/bin/python labs/v4/kong-gateway-otel/04-check.py
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import httpx

HERE = Path(__file__).resolve().parent
env_file = Path(os.environ.get("LF_ENV_FILE", HERE.parents[2] / "_base" / ".env"))
for line in env_file.read_text().splitlines():
    if "=" in line and not line.lstrip().startswith("#"):
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.split(" #", 1)[0].strip().strip('"').strip("'"))
run = dict(l.split("=", 1) for l in (HERE / ".run" / "traces.env").read_text().split())
AUTH = (os.environ["LANGFUSE_INIT_PROJECT_PUBLIC_KEY"], os.environ["LANGFUSE_INIT_PROJECT_SECRET_KEY"])
HOST = os.environ.get("LANGFUSE_HOST", "http://localhost:3000")
failed = 0


def ch(sql: str) -> list[dict]:
    for attempt in range(10):
        p = subprocess.run(["docker", "exec", "langfuse-hols-v4-clickhouse-1", "clickhouse-client", "-q", sql + " FORMAT JSONEachRow"],
                           capture_output=True, text=True)
        if p.returncode == 0:
            return [json.loads(l) for l in p.stdout.splitlines()]
        time.sleep(3)
    sys.exit(f"ClickHouse not answering: {p.stderr.strip()}")


def rows(trace_id: str) -> list[dict]:
    """events_full rows of one trace, once the count has stopped growing (batches land seconds apart)."""
    last, r = -1, []
    for _ in range(30):
        r = ch(f"""SELECT name, type, span_id, parent_span_id, service_name, scope_name, user_id, session_id,
                   provided_model_name AS model, usage_details, input, output,
                   arrayZip(metadata_names, metadata_values) AS md
                   FROM events_full WHERE trace_id = '{trace_id}' ORDER BY start_time""")
        if r and len(r) == last:
            return r
        last = len(r)
        time.sleep(3)
    return r


def check(label: str, ok: bool, detail: str = "") -> None:
    global failed
    failed += not ok
    print(f"{'PASS' if ok else 'FAIL'}  {label}" + (f"  ({detail})" if detail else ""))


def md(row: dict) -> dict:
    return dict(row["md"])


# Scenario A, /raw — Kong OSS on its own: spans, no generation, no user (negative control)
raw = rows(run["RAW_TRACE"])
check("raw: Kong OSS spans arrive", any(r["name"] == "kong" for r in raw), f"{len(raw)} spans, root '{raw[0]['name'] if raw else '-'}'")
check("raw: no generation without the bridge", not any(r["type"] == "GENERATION" for r in raw))
check("raw: no user/session without the bridge", all(r["user_id"] == "" and r["session_id"] == "" for r in raw))
check("raw: no model, usage or prompt on any span", all(not r["model"] and not r["usage_details"] and not r["input"] for r in raw))

# Scenario A, /chat — with the bridge
chat = rows(run["CHAT_TRACE"])
gens = [r for r in chat if r["type"] == "GENERATION"]
check("chat: exactly one generation", len(gens) == 1, ", ".join(g["name"] for g in gens))
if gens:
    g = gens[0]
    check("chat: model from ai-proxy", g["model"] == "mock-gpt", g["model"])
    check("chat: usage input/output/total", g["usage_details"].get("input", 0) > 0 and g["usage_details"].get("output", 0) > 0
          and g["usage_details"].get("total") == g["usage_details"]["input"] + g["usage_details"]["output"], str(g["usage_details"]))
    check("chat: prompt and response bodies", "hello through /chat" in g["input"] and "mock reply to" in g["output"])
    check("chat: header metadata on the generation", md(g).get("agent_id") == "none" and md(g).get("project_id") == "demo-project",
          str({k: md(g).get(k) for k in ("agent_id", "project_id", "gateway")}))
check("chat: user and session on every span", all(r["user_id"] == "user-1001" and r["session_id"].endswith("-direct") for r in chat),
      f"{len(chat)} spans")

# Scenario B — agent gateway -> SDK agent -> model gateway, one trace
agent = rows(run["AGENT_TRACE"])
by_id = {r["span_id"]: r for r in agent}
services = {r["service_name"] for r in agent}
check("agent: both gateways and the SDK in one trace", {"kong-agent-gateway", "kong-model-gateway", "support-agent"} <= services
      and any(r["scope_name"].startswith("langfuse") for r in agent), ", ".join(sorted(services)))
roots = [r for r in agent if r["parent_span_id"] == ""]
check("agent: one root, the agent gateway's span", len(roots) == 1 and roots[0]["service_name"] == "kong-agent-gateway",
      f"{len(roots)} root(s)")
sdk_agent = next((r for r in agent if r["type"] == "AGENT"), None)
check("agent: SDK agent span is a child of the agent gateway",
      bool(sdk_agent) and by_id.get(sdk_agent["parent_span_id"], {}).get("service_name") == "kong-agent-gateway",
      sdk_agent and by_id.get(sdk_agent["parent_span_id"], {}).get("name"))
mg_root = next((r for r in agent if r["service_name"] == "kong-model-gateway" and r["name"] == "kong"), None)
check("agent: model gateway's span is a child of the SDK agent span",
      bool(mg_root) and bool(sdk_agent) and mg_root["parent_span_id"] == sdk_agent["span_id"])
agen = [r for r in agent if r["type"] == "GENERATION"]
check("agent: generation under the model gateway", len(agen) == 1 and agen[0]["service_name"] == "kong-model-gateway"
      and agen[0]["model"] == "mock-gpt" and "Can I get a refund?" in agen[0]["input"])
check("agent: user and session on all spans of all three producers",
      all(r["user_id"] == "user-1001" and r["session_id"] == run["AGENT_SESSION"] for r in agent), f"{len(agent)} spans")

# The same trace through the Langfuse API (v4: the v2 observations API; /api/public/traces is off in events_only mode)
api = httpx.get(f"{HOST}/api/public/v2/observations", auth=AUTH, timeout=10,
                params={"traceId": run["AGENT_TRACE"], "limit": 100, "fields": "core,basic,usage,model"}).json()["data"]
check("api: same observation count as events_full", len(api) == len(agent), f"api {len(api)}, events_full {len(agent)}")
ag = [o for o in api if o["type"] == "GENERATION"]
check("api: generation with model and usage", len(ag) == 1 and ag[0].get("model") == "mock-gpt" and (ag[0].get("usageDetails") or {}).get("total", 0) > 0,
      ag and f"{ag[0].get('model')} {ag[0].get('usageDetails')}")

print(f"\ntrace tree (agent scenario, {len(agent)} observations; kong.* internal spans not shown):")
def walk(parent: str, level: int) -> None:
    """Depth-first, children in start order; kong.* internal spans are skipped but walked through."""
    for r in [r for r in agent if r["parent_span_id"] == parent]:
        shown = not r["name"].startswith("kong.")
        if shown:
            print(f"  {'  ' * level}{r['name']}  [{r['type']}, {r['service_name']}]")
        walk(r["span_id"], level + shown)


walk("", 0)
print(f"\n{'all checks passed' if not failed else f'{failed} check(s) failed'}")
sys.exit(1 if failed else 0)
