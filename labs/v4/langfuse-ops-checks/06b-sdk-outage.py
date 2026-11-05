#!/usr/bin/env python3
"""06b-sdk-outage.py — the Langfuse Python SDK itself (4.17.0) as the client of test 06b, in ONE process.

Same shape as loadgen.py (trace i due at t0 + i·60/rpm; root span + (obs − 1) children, generations and tools,
10 KB input / 1 KB output each; trace tag = run id) but sent through the SDK's own LangfuseSpanProcessor
(OpenTelemetry BatchSpanProcessor: one exporter thread, a queue of OTEL_BSP_MAX_QUEUE_SIZE spans, default
2,048, that drops when full; batches of flush_at spans, default 512) and its OTLP/HTTP exporter with
timeout = --retry-deadline (LANGFUSE_TIMEOUT). 06-mitigations.sh runs it with LOADGEN=06b-sdk-outage.py.

    06b-sdk-outage.py --run-id R --rpm 1200 --seconds 150 [--obs 4] [--prompt-bytes 10000]
                      [--output-bytes 1000] [--retry-deadline 30]

Env: LANGFUSE_HOST, LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY; OTEL_BSP_MAX_QUEUE_SIZE is honoured.
Prints one JSON line: sent traces / observations, spans the SDK dropped because its queue was full, spans of
exports it gave up on (both counted by wrapping BatchProcessor.emit and OTLPSpanExporter.export), and its log
lines (de-duplicated by OpenTelemetry). The SDK does not report what the server accepted: accepted_obs is null.
"""
import argparse
import collections
import json
import logging
import os
import random
import time
from importlib.metadata import version

p = argparse.ArgumentParser()
p.add_argument("--run-id", required=True)
p.add_argument("--rpm", type=float, required=True)
p.add_argument("--seconds", type=float, required=True)
p.add_argument("--obs", type=int, default=4)
p.add_argument("--prompt-bytes", type=int, default=10_000)
p.add_argument("--output-bytes", type=int, default=1_000)
p.add_argument("--traces-per-post", type=int, default=1, help="ignored: the SDK batches by flush_at")
p.add_argument("--retry-deadline", type=float, default=5.0, help="LANGFUSE_TIMEOUT in seconds")
p.add_argument("--threads", type=int, default=0, help="ignored")
a = p.parse_args()

logs: "collections.Counter" = collections.Counter()


class Count(logging.Handler):
    def emit(self, record):
        logs[record.getMessage()[:70]] += 1


for name in ("opentelemetry", "langfuse"):
    lg = logging.getLogger(name)
    lg.addHandler(Count())
    lg.setLevel(logging.WARNING)
    lg.propagate = False

# Count what the SDK loses, by cause (its own warnings are de-duplicated by OpenTelemetry's DuplicateFilter):
#   queue_dropped   a span arrived while the queue held max_queue_size spans (BatchProcessor.emit drops the oldest)
#   export_failed   spans of batches the exporter gave up on (non-retryable status, deadline, max retries)
import opentelemetry.sdk._shared_internal as _bp  # noqa: E402
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter  # noqa: E402
from opentelemetry.sdk.trace.export import SpanExportResult  # noqa: E402

lost: "collections.Counter" = collections.Counter()
_emit, _export = _bp.BatchProcessor.emit, OTLPSpanExporter.export


def emit(self, data):
    if len(self._queue) == self._max_queue_size:
        lost["queue_dropped"] += 1
    return _emit(self, data)


def export(self, spans):
    r = _export(self, spans)
    lost["export_batches"] += 1
    if r != SpanExportResult.SUCCESS:
        lost["export_failed_batches"] += 1
        lost["export_failed"] += len(spans)
    return r


_bp.BatchProcessor.emit, OTLPSpanExporter.export = emit, export

from langfuse import Langfuse, propagate_attributes  # noqa: E402

rng = random.Random(a.run_id)
WORDS = ("account balance policy transfer limit refund card branch loan rate statement customer "
         "고객 잔액 이체 한도 환불 카드 지점 대출 금리 명세서 확인 요청 답변 근거 조항").split()


def text(n):
    out, size = [], 0
    while size < n:
        w = rng.choice(WORDS)
        out.append(w)
        size += len(w.encode()) + 1
    return " ".join(out)[:n]


POOL = [(text(a.prompt_bytes), text(a.output_bytes)) for _ in range(32)]
lf = Langfuse(base_url=os.environ.get("LANGFUSE_HOST", "http://localhost:3000"), timeout=int(a.retry_deadline))
tps = a.rpm / 60.0
n = int(tps * a.seconds)
t0 = time.perf_counter()
wall0 = time.time()
for i in range(n):
    due = t0 + i / tps
    now = time.perf_counter()
    if due > now:
        time.sleep(due - now)
    inp, out = POOL[rng.randrange(len(POOL))]
    with propagate_attributes(tags=[a.run_id], trace_name="ops-load", metadata={"run_id": a.run_id}):
        with lf.start_as_current_observation(as_type="span", name="span-0", input=inp, output=out):
            for j in range(1, a.obs):
                inp, out = POOL[rng.randrange(len(POOL))]
                if j % 2 == 1:
                    lf.start_observation(as_type="generation", name=f"generation-{j}", input=inp, output=out,
                                         model="model-a").end()
                else:
                    lf.start_observation(as_type="tool", name=f"tool-{j}", input=inp, output=out).end()
behind = time.perf_counter() - (t0 + (n - 1) / tps)
t_flush = time.perf_counter()
lf.flush()
lf.shutdown()
res = {"run_id": a.run_id, "client": f"langfuse-python {version('langfuse')}", "rpm": a.rpm, "seconds": a.seconds,
       "obs": a.obs, "prompt_bytes": a.prompt_bytes, "output_bytes": a.output_bytes, "traces_per_post": None,
       "retry_deadline": a.retry_deadline, "max_queue_size": int(os.environ.get("OTEL_BSP_MAX_QUEUE_SIZE", 2048)),
       "started_unix": round(wall0, 3), "wall_s": round(time.perf_counter() - t0, 1),
       "flush_s": round(time.perf_counter() - t_flush, 1), "sender_behind_s": round(behind, 2), "sent_traces": n,
       "sent_obs": n * a.obs, "accepted_obs": None,
       "sdk_queue_dropped_spans": lost["queue_dropped"], "sdk_export_failed_spans": lost["export_failed"],
       "sdk_export_batches": lost["export_batches"], "sdk_export_failed_batches": lost["export_failed_batches"],
       "sdk_logs": dict(logs.most_common(8))}
print(json.dumps(res, ensure_ascii=False))
