#!/usr/bin/env python3
"""03b-sdk-retry.py — what the Langfuse Python SDK's exporter does when the OTLP endpoint answers 5xx.

No Langfuse needed: a local HTTP server answers the SDK's POST /api/public/otel/v1/traces with a scripted
sequence of status codes, and counts the attempts. Each case starts a fresh Langfuse client, creates one span,
calls flush(), and reports how many POSTs arrived, their spacing, and whether the last one got a 2xx.

    .venv-v4/bin/python labs/v4/langfuse-ops-checks/03b-sdk-retry.py      # needs langfuse==4.17.0 (_base/v4)

Writes results/03b-sdk-retry.jsonl.
"""
import http.server
import json
import os
import threading
import time
from importlib.metadata import version

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "results", "03b-sdk-retry.jsonl")

state = {"codes": [], "hits": []}


class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802
        self.rfile.read(int(self.headers.get("content-length", 0)))
        i = len(state["hits"])
        code = state["codes"][i] if i < len(state["codes"]) else state["codes"][-1]
        state["hits"].append((time.time(), code))
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *args):
        pass


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{srv.server_address[1]}"

from langfuse import Langfuse  # noqa: E402

cases = [
    ("500 once", [500, 200], 5),
    ("502 twice, then 200", [502, 502, 200], 5),
    ("503 twice, then 200", [503, 503, 200], 5),
    ("504 twice, then 200", [504, 504, 200], 5),
    ("503 always, timeout 5 (default)", [503], 5),
    ("503 always, timeout 30", [503], 30),
    ("401", [401, 200], 5),
]
os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as f:
    for n, (name, codes, timeout) in enumerate(cases):
        state["codes"], state["hits"] = codes, []
        # The SDK keeps one client per public key; a fresh key per case avoids reusing a shut-down exporter.
        lf = Langfuse(public_key=f"pk-lf-probe-{n}", secret_key="sk-lf-probe", base_url=base, timeout=timeout,
                      flush_interval=0.2)
        t = time.time()
        with lf.start_as_current_observation(name="retry-probe"):
            pass
        lf.flush()
        lf.shutdown()
        hits = state["hits"]
        res = {"case": name, "timeout_s": timeout, "attempts": len(hits),
               "gaps_s": [round(hits[i][0] - hits[i - 1][0], 2) for i in range(1, len(hits))],
               "codes": [c for _, c in hits], "delivered": bool(hits) and 200 <= hits[-1][1] < 300,
               "flush_s": round(time.time() - t, 2), "sdk": version("langfuse"),
               "otlp_exporter": version("opentelemetry-exporter-otlp-proto-http")}
        print(json.dumps(res))
        f.write(json.dumps(res) + "\n")
srv.shutdown()
