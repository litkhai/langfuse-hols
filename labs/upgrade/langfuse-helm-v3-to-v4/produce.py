#!/usr/bin/env python3
"""
produce.py — the producers of this lab. Every trace it sends is tagged with its phase, so a
later step can count what each phase wrote and where it landed.

    produce.py traces --phase v3-start --n 40        # SDK traces (whichever SDK runs this file)
    produce.py setup                                 # prompts, a dataset, one experiment run
    produce.py legacy-http --phase v3-start --n 10   # POST /api/public/ingestion, no SDK

Run with the v3 SDK (.work/venv-v3) for the "old producer" and with the v4 SDK
(.work/venv-v4, langfuse >= 4.7.0) for the producer that writes the v4 tables directly.
Each run appends the trace ids it sent to .work/sent.jsonl: {phase, producer, trace_id}.

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
PK = os.environ.get("LANGFUSE_PUBLIC_KEY", "pk-lf-upgrade-lab")
SK = os.environ.get("LANGFUSE_SECRET_KEY", "sk-lf-upgrade-lab")
SDK = version("langfuse")
rng = random.Random()  # not seeded: OpenTelemetry ids must differ between runs

QUESTIONS = ["How do I reset my password?", "Why was my invoice higher this month?",
             "Can I export my data to S3?", "How do I rotate my API keys?"]


def record(phase, producer, trace_id):
    with open(SENT, "a") as fh:
        fh.write(json.dumps({"phase": phase, "producer": producer, "trace_id": trace_id}) + "\n")


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
            # Trace attributes on every child (client-side propagation).
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
    auth = base64.b64encode(f"{PK}:{SK}".encode()).decode()
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
        req = urllib.request.Request(f"{HOST}/api/public/ingestion", data=json.dumps(batch).encode(),
                                     headers={"Authorization": f"Basic {auth}",
                                              "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                body = json.loads(resp.read())
        except urllib.error.HTTPError as e:
            print(f"HTTP {e.code}: {e.read()[:300]!r}")
            continue
        errors = body.get("errors", [])
        if errors:
            print(f"207 with errors: {json.dumps(errors)[:300]}")
            continue
        ok += 1
        record(args.phase, "legacy-http", tid)
    print(f"legacy-http: {ok}/{args.n} accepted, phase {args.phase} -> {HOST}")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("traces", "legacy-http"):
        s = sub.add_parser(name)
        s.add_argument("--phase", required=True)
        s.add_argument("--n", type=int, default=20)
    sub.add_parser("setup")
    a = p.parse_args()
    {"traces": traces, "setup": setup, "legacy-http": legacy_http}[a.cmd](a)
    time.sleep(0.1)
