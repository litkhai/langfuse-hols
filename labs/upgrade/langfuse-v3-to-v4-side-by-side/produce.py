#!/usr/bin/env python3
"""
produce.py — the producers of this lab. Every trace is tagged with its phase and recorded in
.work/sent.jsonl ({phase, producer, trace_id}), so a later step can count where it landed.

    produce.py setup                               # prompts, a dataset, one experiment run
    produce.py traces --phase v3-start --n 40      # SDK traces (whichever SDK runs this file)
    produce.py legacy-http --phase v3-start --n 10 # POST /api/public/ingestion, no SDK
    produce.py llm-connection                      # an LLM connection (encrypted key) to mock-llm

Run with .work/venv-v3 (SDK 3.x) or .work/venv-v4 (SDK 4.x).
Environment: LANGFUSE_HOST, LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY.
"""
import argparse
import base64
import json
import os
import random
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from importlib.metadata import version

HERE = os.path.dirname(os.path.abspath(__file__))
SENT = os.path.join(HERE, ".work", "sent.jsonl")
HOST = os.environ.get("LANGFUSE_HOST", "http://localhost:3000")
PK = os.environ.get("LANGFUSE_PUBLIC_KEY", "pk-lf-sbs-lab")
SK = os.environ.get("LANGFUSE_SECRET_KEY", "sk-lf-sbs-lab")
SDK = version("langfuse")
rng = random.Random()  # not seeded: OpenTelemetry ids must differ between runs
AUTH = "Basic " + base64.b64encode(f"{PK}:{SK}".encode()).decode()
MOCK_KEY = "sk-mock-sbs-lab-0001"  # the LLM key stored encrypted by v3 and decrypted by v4 (06)

QUESTIONS = ["How do I reset my password?", "Why was my invoice higher this month?",
             "Can I export my data to S3?", "How do I rotate my API keys?"]


def record(phase, producer, trace_id):
    with open(SENT, "a") as fh:
        fh.write(json.dumps({"phase": phase, "producer": producer, "trace_id": trace_id}) + "\n")


def http(method, path, body=None):
    req = urllib.request.Request(f"{HOST}{path}", method=method,
                                 data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": AUTH, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status, json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:400].decode(errors="replace")


def client():
    from langfuse import Langfuse, get_client
    Langfuse(base_url=HOST, public_key=PK, secret_key=SK) if SDK.startswith("4") else \
        Langfuse(host=HOST, public_key=PK, secret_key=SK)
    lf = get_client()
    if not lf.auth_check():
        sys.exit(f"auth check failed against {HOST}")
    return lf


def traces(args):
    from langfuse import propagate_attributes
    lf = client()
    producer = f"python-sdk-{SDK}"
    for i in range(args.n):
        q = rng.choice(QUESTIONS)
        user = f"user_{rng.randrange(1, 9):02d}"
        with lf.start_as_current_observation(as_type="span", name="support-request",
                                             input={"question": q}) as root:
            with propagate_attributes(user_id=user, session_id=f"sess_{args.phase}_{i // 4}",
                                      tags=[f"phase:{args.phase}", producer],
                                      metadata={"phase": args.phase, "producer": producer}):
                with lf.start_as_current_observation(as_type="span", name="retrieve-context") as r:
                    r.update(output={"docs": rng.randrange(1, 6)})
                with lf.start_as_current_observation(as_type="generation", name="answer",
                                                     model="gpt-4o-mini", input=q) as g:
                    g.update(output="(simulated answer)",
                             usage_details={"input": rng.randrange(200, 900),
                                            "output": rng.randrange(40, 300)})
            root.update(output={"answer": "(simulated answer)"})
            root.score_trace(name="user-thumbs", value=rng.choice([0, 1]))
            record(args.phase, producer, root.trace_id)
    lf.flush()
    print(f"{producer}: {args.n} traces, phase {args.phase} -> {HOST}")


def setup(_args):
    lf = client()
    lf.create_prompt(name="support-system", type="text", labels=["production"],
                     prompt="You are a helpful support assistant. Answer {{question}}.")
    lf.create_prompt(name="support-chat", type="chat", labels=["production"],
                     prompt=[{"role": "system", "content": "You are a helpful support assistant."}])
    lf.create_dataset(name="support-golden")
    for q in QUESTIONS:
        lf.create_dataset_item(dataset_name="support-golden", input={"question": q},
                               expected_output="(expected)")
    ds = lf.get_dataset("support-golden")
    res = ds.run_experiment(name=f"baseline-{SDK}", task=lambda *, item, **_: "(simulated answer)")
    print(f"prompts 2, dataset items {len(ds.items)}, experiment run {res.run_name}")
    lf.flush()


def legacy_http(args):
    """Old ingestion API (what SDK v2 and hand-written integrations call)."""
    ok = 0
    for i in range(args.n):
        tid = uuid.uuid4().hex
        now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        batch = {"batch": [
            {"id": uuid.uuid4().hex, "type": "trace-create", "timestamp": now,
             "body": {"id": tid, "name": "legacy-ingestion", "userId": "user_legacy",
                      "sessionId": f"sess_{args.phase}_legacy", "tags": [f"phase:{args.phase}", "legacy-http"],
                      "metadata": {"phase": args.phase, "producer": "legacy-http"},
                      "input": {"question": QUESTIONS[i % len(QUESTIONS)]}}},
            {"id": uuid.uuid4().hex, "type": "generation-create", "timestamp": now,
             "body": {"id": uuid.uuid4().hex, "traceId": tid, "name": "answer", "model": "gpt-4o-mini",
                      "startTime": now, "endTime": now, "output": "(simulated answer)",
                      "usageDetails": {"input": 300, "output": 80}}},
        ]}
        code, body = http("POST", "/api/public/ingestion", batch)
        errors = body.get("errors", []) if isinstance(body, dict) else [body]
        if code >= 300 or errors:
            print(f"HTTP {code}: {json.dumps(errors)[:300]}")
            continue
        ok += 1
        record(args.phase, "legacy-http", tid)
    print(f"legacy-http: {ok}/{args.n} accepted, phase {args.phase} -> {HOST}")


def llm_connection(_args):
    body = {"provider": "mock-openai", "adapter": "openai", "secretKey": MOCK_KEY,
            "baseURL": "http://mock-llm:8080/v1", "customModels": ["mock-model"],
            "withDefaultModels": False}
    code, resp = http("PUT", "/api/public/llm-connections", body)
    print(f"PUT /api/public/llm-connections -> {code} {json.dumps(resp)[:200]}")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("traces", "legacy-http"):
        s = sub.add_parser(name)
        s.add_argument("--phase", required=True)
        s.add_argument("--n", type=int, default=20)
    sub.add_parser("setup")
    sub.add_parser("llm-connection")
    a = p.parse_args()
    {"traces": traces, "setup": setup, "legacy-http": legacy_http,
     "llm-connection": llm_connection}[a.cmd](a)
    time.sleep(0.1)
