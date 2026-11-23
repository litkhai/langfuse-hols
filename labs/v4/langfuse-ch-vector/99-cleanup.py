#!/usr/bin/env python3
"""99-cleanup.py — remove what this lab created, nothing else.

  - database lab_langfuse_ch_vector on the shared ClickHouse (DROP DATABASE);
  - the bench container lf-ch-vector-bench (docker rm -f);
  - with --traces: this lab's traces in Langfuse (tag lab:langfuse-ch-vector), through the
    public API DELETE /api/public/traces — Langfuse marks them deleted; its tables are not touched here.
  - with --cache: .run/ (bench vectors, failing trace id). The model stays in the Hugging Face cache.

Usage:  .venv-vector/bin/python labs/v4/langfuse-ch-vector/99-cleanup.py [--traces] [--cache]
"""
import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lablib as L

ap = argparse.ArgumentParser()
ap.add_argument("--traces", action="store_true")
ap.add_argument("--cache", action="store_true")
args = ap.parse_args()

if args.traces:
    ids = [r["trace_id"] for r in L.ch_rows(
        "SELECT DISTINCT trace_id FROM default.events_full WHERE project_id = {p:String} "
        "AND has(tags, {tag:String}) AND is_deleted = 0", params={"p": L.PROJECT_ID, "tag": L.LAB_TAG})]
    auth = base64.b64encode(f"{os.environ['LANGFUSE_PUBLIC_KEY']}:{os.environ['LANGFUSE_SECRET_KEY']}".encode()).decode()
    host = os.environ.get("LANGFUSE_HOST", "http://localhost:3000")
    for i in range(0, len(ids), 500):
        req = urllib.request.Request(f"{host}/api/public/traces", method="DELETE",
                                     data=json.dumps({"traceIds": ids[i:i + 500]}).encode(),
                                     headers={"Authorization": f"Basic {auth}", "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            print(f"DELETE /api/public/traces ({len(ids[i:i + 500])} ids): HTTP {r.status} {r.read().decode()[:200]}")
    print(f"requested deletion of {len(ids)} traces tagged {L.LAB_TAG} (the worker applies it asynchronously)")

L.ch(f"DROP DATABASE IF EXISTS {L.DB}")
print(f"dropped database {L.DB}")
subprocess.run(["docker", "rm", "-f", "lf-ch-vector-bench"], capture_output=True)
print("removed container lf-ch-vector-bench (if it existed)")
if args.cache:
    shutil.rmtree(os.path.join(L.LAB_DIR, ".run"), ignore_errors=True)
    print("removed .run/")
