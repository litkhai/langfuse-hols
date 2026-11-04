#!/usr/bin/env python3
"""loadgen.py — open-loop OTLP/HTTP (JSON) load into Langfuse v4, with an optional public-API read mix.

    loadgen.py --run-id R --rpm 4000 --seconds 60 [--obs 4] [--prompt-bytes 10000] [--output-bytes 1000]
               [--traces-per-post 1] [--read-ratio 0.0] [--threads 64] [--retry-deadline 0] [--out FILE]

Adapted from the bench generator of clickhouse-hols `usecase/langfuse-prompt-encryption-perf` (not imported).
Payloads are synthetic, so the lab needs no data file.

* One trace = one root span plus (obs − 1) children; the 2nd, 4th, … child is a generation with a model and
  usage, the others are tools. Every observation carries an input of --prompt-bytes and an output of
  --output-bytes (random words, so ClickHouse cannot compress them away).
* --rpm is traces per minute (one "request" of the application = one trace). The sender is open loop: trace i
  is due at t0 + i·60/rpm whatever the server does, so a slow server shows up as lag, not as a lower rate.
* --traces-per-post N packs N traces into one OTLP POST, as an SDK's batch span processor or an OTel Collector
  would (Langfuse writes one blob per POST).
* Every span gets start time = the moment its trace was due, the trace tag R and the observation metadata
  run_id = R, so ClickHouse can count what arrived and the lag (events_full.created_at − start_time).
* --read-ratio X issues X reads per trace sent, alternating a trace detail (GET /api/public/v2/observations?traceId=…
  of a trace sent ≥ 5 s earlier: all its observations with input/output) and an observations list (GET
  /api/public/v2/observations?limit=50, newest first). GET /api/public/traces/{id} is not used: Langfuse 4.56.0
  answers 404 "not available on deployments running in Langfuse v4 events_only mode".
* --retry-deadline S (0 = no retries) retries a POST the way the OTLP/HTTP exporter of opentelemetry-python
  1.45.0 does: 429/502/503/504 and connection errors, backoff 2^n s ±20 % (Retry-After wins), at most 6
  attempts, never past S seconds after the first attempt. The Langfuse Python SDK 4.17.0 sets S = 5
  (LANGFUSE_TIMEOUT). Any other status (500 included) is not retried.

Env: LANGFUSE_HOST (default http://localhost:3000), LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY.
Prints one JSON line (also to --out): sent/accepted/failed traces and observations, HTTP status counts,
accept latency, read latency.
"""
import argparse
import base64
import collections
import json
import os
import queue
import random
import secrets
import sys
import threading
import time
import urllib.error
import urllib.request

p = argparse.ArgumentParser()
p.add_argument("--run-id", required=True)
p.add_argument("--rpm", type=float, required=True, help="traces per minute")
p.add_argument("--seconds", type=float, required=True)
p.add_argument("--obs", type=int, default=4, help="observations per trace")
p.add_argument("--prompt-bytes", type=int, default=10_000)
p.add_argument("--output-bytes", type=int, default=1_000)
p.add_argument("--traces-per-post", type=int, default=1)
p.add_argument("--read-ratio", type=float, default=0.0)
p.add_argument("--threads", type=int, default=64)
p.add_argument("--retry-deadline", type=float, default=0.0)
p.add_argument("--out")
a = p.parse_args()

host = os.environ.get("LANGFUSE_HOST", "http://localhost:3000")
auth = "Basic " + base64.b64encode(
    f"{os.environ['LANGFUSE_PUBLIC_KEY']}:{os.environ['LANGFUSE_SECRET_KEY']}".encode()).decode()
OTLP = f"{host}/api/public/otel/v1/traces"

rng = random.Random(a.run_id)
WORDS = ("account balance policy transfer limit refund card branch loan rate statement customer "
         "고객 잔액 이체 한도 환불 카드 지점 대출 금리 명세서 확인 요청 답변 근거 조항").split()


def text(n: int) -> str:
    out, size = [], 0
    while size < n:
        w = rng.choice(WORDS)
        out.append(w)
        size += len(w.encode()) + 1
    return " ".join(out)[:n]


POOL = [(text(a.prompt_bytes), text(a.output_bytes)) for _ in range(32)]


def attr(k, v):
    if isinstance(v, int):
        return {"key": k, "value": {"intValue": str(v)}}
    if isinstance(v, list):
        return {"key": k, "value": {"arrayValue": {"values": [{"stringValue": x} for x in v]}}}
    return {"key": k, "value": {"stringValue": str(v)}}


def build_trace(start_ns: int):
    trace_id = secrets.token_hex(16)
    ids = [secrets.token_hex(8) for _ in range(a.obs)]
    spans = []
    for i in range(a.obs):
        inp, out = POOL[rng.randrange(len(POOL))]
        kind = "span" if i == 0 else ("generation" if i % 2 == 1 else "tool")
        at = [attr("langfuse.observation.type", kind),
              attr("langfuse.observation.input", inp),
              attr("langfuse.observation.output", out),
              attr("langfuse.observation.metadata.run_id", a.run_id),
              attr("langfuse.trace.name", "ops-load"),
              attr("langfuse.trace.tags", [a.run_id]),
              attr("user.id", f"user-{rng.randrange(1000)}"),
              attr("session.id", f"session-{rng.randrange(10000)}")]
        if kind == "generation":
            at += [attr("langfuse.observation.model.name", "model-a"),
                   attr("gen_ai.usage.input_tokens", a.prompt_bytes // 4),
                   attr("gen_ai.usage.output_tokens", a.output_bytes // 4)]
        s = start_ns + i * 1_000_000
        spans.append({"traceId": trace_id, "spanId": ids[i], "parentSpanId": "" if i == 0 else ids[0],
                      "name": f"{kind}-{i}", "kind": 1, "startTimeUnixNano": str(s),
                      "endTimeUnixNano": str(s + 500_000), "attributes": at, "status": {}})
    return trace_id, spans


def body(spans) -> bytes:
    return json.dumps({"resourceSpans": [{"resource": {"attributes": [attr("service.name", "ops-loadgen")]},
                                          "scopeSpans": [{"scope": {"name": "ops-loadgen", "version": "1"},
                                                          "spans": spans}]}]},
                      ensure_ascii=False).encode()


RETRYABLE = {429, 502, 503, 504}
lock = threading.Lock()
stats = collections.Counter()
codes = collections.Counter()
accept_ms, read_ms = [], []
sent_ids: "collections.deque" = collections.deque(maxlen=20_000)


def post(data: bytes):
    """One export, with the OTLP exporter's retry rule when --retry-deadline > 0. Returns (ok, last status)."""
    deadline = time.time() + a.retry_deadline
    for attempt in range(6 if a.retry_deadline > 0 else 1):
        status, retry_after = None, None
        try:
            req = urllib.request.Request(OTLP, data=data, method="POST",
                                         headers={"Authorization": auth, "Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=30) as r:
                r.read()
                status = r.status
        except urllib.error.HTTPError as e:
            status = e.code
            retry_after = e.headers.get("retry-after")
        except Exception:  # noqa: BLE001 — connection refused/reset/timeout
            status = None
        with lock:
            codes[str(status)] += 1
        if status is not None and 200 <= status < 400:
            return True, status
        if a.retry_deadline <= 0 or (status is not None and status not in RETRYABLE):
            return False, status
        backoff = 2 ** attempt * rng.uniform(0.8, 1.2)
        if retry_after and retry_after.isdigit():
            backoff = float(retry_after)
        if attempt == 5 or backoff > deadline - time.time():
            return False, status
        with lock:
            stats["retries"] += 1
        time.sleep(backoff)
    return False, None


def read_one(i: int):
    with lock:
        cands = [t for (t, ts) in list(sent_ids)[-2000:] if time.time() - ts > 5]
    if not cands:
        return
    tid = rng.choice(cands)
    url = (f"{host}/api/public/v2/observations?traceId={tid}&limit=100" if i % 2 == 0 else
           f"{host}/api/public/v2/observations?limit=50")
    t = time.perf_counter()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"Authorization": auth}), timeout=30) as r:
            r.read()
            ok = r.status == 200
    except Exception:  # noqa: BLE001
        ok = False
    with lock:
        stats["reads_ok" if ok else "reads_failed"] += 1
        if ok:
            read_ms.append((time.perf_counter() - t) * 1000)


tasks: "queue.Queue" = queue.Queue()


def worker():
    while True:
        item = tasks.get()
        if item is None:
            return
        if item[0] == "read":
            read_one(item[1])
            continue
        _, traces = item
        spans = [s for (_, ss) in traces for s in ss]
        t = time.perf_counter()
        ok, _ = post(body(spans))
        with lock:
            k = "accepted" if ok else "failed"
            stats[f"{k}_traces"] += len(traces)
            stats[f"{k}_obs"] += len(spans)
            stats[f"{k}_posts"] += 1
            if ok:
                accept_ms.append((time.perf_counter() - t) * 1000)
                now = time.time()
                for tid, _ in traces:
                    sent_ids.append((tid, now))


threads = [threading.Thread(target=worker, daemon=True) for _ in range(a.threads)]
for th in threads:
    th.start()
tps = a.rpm / 60.0
n = int(tps * a.seconds)
t0 = time.perf_counter()
wall0 = time.time()
buf, reads_due, reads_done = [], 0.0, 0
for i in range(n):
    due = t0 + i / tps
    now = time.perf_counter()
    if due > now:
        time.sleep(due - now)
    start_ns = int((wall0 + (due - t0)) * 1e9)
    buf.append(build_trace(start_ns))
    if len(buf) >= a.traces_per_post or i == n - 1:
        tasks.put(("post", buf))
        buf = []
    reads_due += a.read_ratio
    while reads_done < int(reads_due):
        tasks.put(("read", reads_done))
        reads_done += 1
behind = time.perf_counter() - (t0 + (n - 1) / tps) if n else 0.0
for _ in threads:
    tasks.put(None)
for th in threads:
    th.join()
wall = time.perf_counter() - t0


def pct(xs, q):
    xs = sorted(xs)
    return round(xs[min(len(xs) - 1, int(q / 100 * len(xs)))], 1) if xs else None


res = {"run_id": a.run_id, "rpm": a.rpm, "seconds": a.seconds, "obs": a.obs, "prompt_bytes": a.prompt_bytes,
       "output_bytes": a.output_bytes, "traces_per_post": a.traces_per_post, "read_ratio": a.read_ratio,
       "retry_deadline": a.retry_deadline, "started_unix": round(wall0, 3), "wall_s": round(wall, 1),
       "sender_behind_s": round(behind, 2), "sent_traces": n, "sent_obs": n * a.obs, **dict(stats),
       "http": dict(codes), "accept_p50_ms": pct(accept_ms, 50), "accept_p95_ms": pct(accept_ms, 95),
       "accept_p99_ms": pct(accept_ms, 99), "read_p50_ms": pct(read_ms, 50), "read_p95_ms": pct(read_ms, 95)}
line = json.dumps(res)
print(line)
if a.out:
    with open(a.out, "a") as f:
        f.write(line + "\n")
sys.exit(0)
