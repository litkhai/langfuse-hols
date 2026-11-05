"""Step 14 — the gateway on Helm: TLS, two replicas, a stream across a rolling restart, a replica
deleted under traffic (#91). Real Anthropic calls; the long stream is the expensive one (~0.03 USD).

  .venv-v4/bin/python labs/v4/ai-gateway/14-helm-check.py            # after 13-helm-up.sh, ~4 minutes
  FAULT=1 .venv-v4/bin/python labs/v4/ai-gateway/14-helm-check.py    # one gateway replica: must fail

Runs 02-setup.py against the Helm instance first (same people and keys; state in .run/state-helm.json).
FAULT=1 scales the gateway Deployment to 1 replica before the checks and back to 2 at the end, and skips
Claude Code and the long stream.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
os.environ.setdefault("LAB_WEB", "https://langfuse.127.0.0.1.nip.io:18443")
os.environ.setdefault("LAB_GATEWAY", "https://gateway.127.0.0.1.nip.io:18443")
os.environ.setdefault("LAB_STATE", "state-helm.json")
os.environ.setdefault("LAB_CA", str(HERE / ".run" / "helm-tls" / "ca.pem"))

import anthropic  # noqa: E402
import httpx  # noqa: E402

import lablib as L  # noqa: E402

FAULT = os.environ.get("FAULT") == "1"
K = ["kubectl", "--context", "kind-lf-gateway-helm", "-n", "langfuse"]
rows: list[tuple[bool | None, str, str]] = []
results: dict = {}


def check(ok, what, detail=""):
    ok = None if ok is None else bool(ok)
    rows.append((ok, what, detail))
    print(f"{ {True: 'PASS', False: 'FAIL', None: 'INFO'}[ok] }  {what}{'  — ' + detail if detail else ''}", flush=True)


def kj(*args) -> dict:
    return json.loads(subprocess.run([*K, *args, "-o", "json"], capture_output=True, text=True, check=True).stdout)


def gateway_pods() -> list[dict]:
    return kj("get", "pods", "-l", "app.kubernetes.io/component=gateway")["items"]


e = L.env()
if FAULT:
    subprocess.run([*K, "scale", "deploy/langfuse-gateway", "--replicas=1"], check=True, capture_output=True)
    subprocess.run([*K, "rollout", "status", "deploy/langfuse-gateway", "--timeout=120s"], check=True, capture_output=True)

# 0. Same setup as the compose run, against this instance -------------------------------------------
if not (L.RUN_DIR / os.environ["LAB_STATE"]).exists() or "keys" not in L.state():
    subprocess.run([sys.executable, str(HERE / "02-setup.py")], check=True)
st = L.state()
alice = st["keys"]["alice-laptop"]["secret"]
print(f"── Helm run{' (FAULT: 1 replica)' if FAULT else ''} · web {L.WEB} · gateway {L.GATEWAY}")

# 1. What the chart deployed -------------------------------------------------------------------------
dep = kj("get", "deploy/langfuse-gateway")
web = kj("get", "deploy/langfuse-web")
web_env = {x["name"]: x.get("value") for x in web["spec"]["template"]["spec"]["containers"][0]["env"]}
pdb = kj("get", "pdb/langfuse-gateway-pdb")
check(dep["status"].get("readyReplicas") == 2, "chart: gateway Deployment with 2 ready replicas", f"ready {dep['status'].get('readyReplicas')} of {dep['spec']['replicas']} · image {dep['spec']['template']['spec']['containers'][0]['image']}")
check(web_env.get("LANGFUSE_AI_GATEWAY_DEPLOYED") == "true" and web_env.get("LANGFUSE_AI_GATEWAY_PUBLIC_URL") == L.GATEWAY,
      "chart: web knows the gateway is deployed and its public URL", f"{web_env.get('LANGFUSE_AI_GATEWAY_PUBLIC_URL')}")
check(pdb["spec"].get("maxUnavailable") == 1, "chart: PodDisruptionBudget keeps all but one gateway pod", f"maxUnavailable {pdb['spec'].get('maxUnavailable')}")
spec = dep["spec"]["template"]["spec"]
check(spec.get("terminationGracePeriodSeconds") == 350, "chart: graceful shutdown settings", f"terminationGracePeriodSeconds {spec.get('terminationGracePeriodSeconds')}")

# 2. TLS ------------------------------------------------------------------------------------------------
ok = httpx.get(f"{L.GATEWAY}/health", verify=L.VERIFY, timeout=20)
check(ok.status_code == 200 and ok.json().get("status") == "ok", "TLS: /health through Traefik with the lab CA", f"{ok.status_code} {ok.text}")
try:
    httpx.get(f"{L.GATEWAY}/health", timeout=20)  # system trust store only
    check(False, "TLS: without the lab CA the certificate is refused", "connected")
except httpx.ConnectError as err:
    check("CERTIFICATE_VERIFY_FAILED" in str(err) or "certificate" in str(err).lower(), "TLS: without the lab CA the certificate is refused", str(err)[:90])

# 3. SDK over HTTPS, and the generation in Langfuse ---------------------------------------------------------
# anthropic 1.12.1 runs on httpx2 and rejects an httpx.Client; its DefaultHttpxClient takes the CA.
cl = anthropic.Anthropic(base_url=f"{L.GATEWAY}/anthropic", api_key=alice, max_retries=0,
                         http_client=anthropic.DefaultHttpxClient(verify=L.VERIFY, timeout=120))
raw = cl.messages.with_raw_response.create(model=L.MODEL, max_tokens=5, messages=[{"role": "user", "content": "Reply with exactly one word: pong"}])
trace = raw.headers.get("langfuse-trace-id")
auth = (e["LANGFUSE_INIT_PROJECT_PUBLIC_KEY"], e["LANGFUSE_INIT_PROJECT_SECRET_KEY"])


def observations(trace_id: str, wait_s: int = 120) -> list[dict]:
    deadline = time.monotonic() + wait_s
    while True:
        r = httpx.get(f"{L.WEB}/api/public/v2/observations", params={"traceId": trace_id}, auth=auth, verify=L.VERIFY, timeout=30)
        data = r.json().get("data", []) if r.status_code == 200 else []
        if data or time.monotonic() > deadline:
            return data
        time.sleep(4)


obs = observations(trace)
check(raw.status_code == 200 and bool(obs), "SDK over HTTPS: 200 and the generation is stored", f"trace {trace} · {[(o.get('type'), o.get('name')) for o in obs]}")
cost = None
for _ in range(20):  # cost is filled when the worker writes the generation with a matched model
    r = httpx.get(f"{L.WEB}/api/public/v2/observations", params={"traceId": trace, "fields": "core,basic,usage,model"}, auth=auth, verify=L.VERIFY, timeout=30)
    o = (r.json().get("data") or [{}])[0] if r.status_code == 200 else {}
    cost = o.get("totalCost") or o.get("calculatedTotalCost")
    if cost:
        break
    time.sleep(3)
check(bool(cost) and float(cost) > 0, "the generation is priced (default model prices loaded)", f"cost {cost} USD · model id {o.get('modelId')}")

# 4. Claude Code over HTTPS --------------------------------------------------------------------------------
if shutil.which("claude") and not FAULT:
    for label, extra in [("without the CA", {}), ("with NODE_EXTRA_CA_CERTS", {"NODE_EXTRA_CA_CERTS": os.environ["LAB_CA"]})]:
        cfg = tempfile.mkdtemp(prefix="cc-helm-")
        env = {k: v for k, v in os.environ.items() if not k.startswith(("ANTHROPIC_", "CLAUDE_", "NODE_EXTRA"))}
        env.update({"CLAUDE_CONFIG_DIR": cfg, "ANTHROPIC_BASE_URL": f"{L.GATEWAY}/anthropic", "ANTHROPIC_AUTH_TOKEN": alice,
                    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", **extra})
        p = subprocess.run(["claude", "-p", "Reply with exactly: hello gateway", "--model", L.MODEL, "--max-turns", "1"],
                           env=env, cwd=cfg, capture_output=True, text=True, timeout=120)
        shutil.rmtree(cfg, ignore_errors=True)
        results[f"claude_{label}"] = {"exit": p.returncode, "out": (p.stdout + p.stderr).strip()[-160:]}
        want = p.returncode != 0 if label == "without the CA" else (p.returncode == 0 and "hello gateway" in p.stdout.lower())
        check(want, f"Claude Code over HTTPS {label}", f"exit {p.returncode} · {(p.stdout + p.stderr).strip()[:90]}")

# 5. A stream whose gateway pod is deleted mid-stream, then a rolling restart --------------------------------
if not FAULT:  # the fault run skips the long stream (cost); it is about replicas
    stream = {"chunks": 0, "error": None}


    def run_stream():
        t0 = time.monotonic()
        try:
            with cl.messages.with_streaming_response.create(model=L.MODEL, max_tokens=8000, stream=True,
                                                            messages=[{"role": "user", "content": "Count from 1 to 3000, one number per line, nothing else."}]) as r:
                stream["trace"] = r.headers.get("langfuse-trace-id")
                stream["request_id"] = r.headers.get("langfuse-request-id")
                for ev in r.parse():
                    if ev.type == "content_block_delta":
                        stream["chunks"] += 1
                        stream.setdefault("first_chunk_s", round(time.monotonic() - t0, 1))
                    elif ev.type == "message_delta":
                        stream["stop_reason"] = ev.delta.stop_reason
                        stream["output_tokens"] = ev.usage.output_tokens
        except Exception as err:  # noqa: BLE001
            stream["error"] = f"{type(err).__name__}: {str(err)[:160]}"
        stream["end_s"] = round(time.monotonic() - t0, 1)
        stream["ended_at"] = time.monotonic()


    def pod_logs(name: str) -> str:
        return subprocess.run([*K, "logs", name], capture_output=True, text=True).stdout


    th = threading.Thread(target=run_stream)
    th.start()
    while "first_chunk_s" not in stream and th.is_alive():
        time.sleep(0.2)
    # The gateway logs each request with its langfuse-request-id: that names the pod serving the stream.
    serving = next((p["metadata"]["name"] for p in gateway_pods() if stream.get("request_id") and stream["request_id"] in pod_logs(p["metadata"]["name"])), None)
    t_delete = time.monotonic()
    if serving:
        subprocess.run([*K, "delete", "pod", serving, "--wait=false"], check=True, capture_output=True)
    deleted_at, drain_log = None, ""
    while th.is_alive():
        pods = {p["metadata"]["name"]: p for p in gateway_pods()}
        if serving in pods and pods[serving]["metadata"].get("deletionTimestamp") and deleted_at is None:
            deleted_at = round(time.monotonic() - t_delete, 1)
        if serving in pods:
            drain_log = pod_logs(serving) or drain_log  # the log goes with the pod; keep the last copy
        time.sleep(1)
    th.join()
    stream.update({"serving_pod": serving, "pod_terminating_after_s": deleted_at,
                   "stream_left_after_delete_s": round(stream["ended_at"] - t_delete, 1) if serving else None,
                   "drain_logged": "gateway draining" in drain_log})
    stream.pop("ended_at", None)
    results["stream"] = stream
    sobs = observations(stream.get("trace") or "", 150) if stream.get("trace") else []
    check(serving is not None and deleted_at is not None and stream["error"] is None and stream.get("stop_reason") in ("end_turn", "max_tokens"),
          "the pod serving a stream is deleted: the stream finishes (graceful drain)",
          f"pod {serving} terminating {deleted_at} s after delete · stream ran {stream['stream_left_after_delete_s']} s more · "
          f"{stream['chunks']} chunks, {stream.get('output_tokens')} tokens, stop {stream.get('stop_reason')} · error {stream['error']}")
    check(bool(sobs), "that stream's generation is recorded", f"{[(o.get('type'), o.get('name')) for o in sobs]}")
    check(stream["stream_left_after_delete_s"] is not None and stream["stream_left_after_delete_s"] > 10 and stream["drain_logged"],
          "the stream outlived the 10 s preStop sleep and the pod logged its drain (SIGTERM → drain)", f"'gateway draining' in its log: {stream['drain_logged']}")

    subprocess.run([*K, "rollout", "status", "deploy/langfuse-gateway", "--timeout=600s"], check=True, capture_output=True)
    old = {p["metadata"]["name"] for p in gateway_pods() if not p["metadata"].get("deletionTimestamp")}
    t_restart = time.monotonic()
    subprocess.run([*K, "rollout", "restart", "deploy/langfuse-gateway"], check=True, capture_output=True)
    subprocess.run([*K, "rollout", "status", "deploy/langfuse-gateway", "--timeout=600s"], check=True, capture_output=True)
    rolled = round(time.monotonic() - t_restart, 1)
    while old & {p["metadata"]["name"] for p in gateway_pods()} and time.monotonic() - t_restart < 420:
        time.sleep(2)
    gone = round(time.monotonic() - t_restart, 1)
    results["rollout"] = {"rollout_status_s": rolled, "old_pods_gone_s": gone}
    check(not (old & {p["metadata"]["name"] for p in gateway_pods()}), "rolling restart: new pods ready, old pods gone within the grace period",
          f"rollout status after {rolled} s · old pods gone after {gone} s (grace period 350 s)")

# 6. A replica deleted under traffic -------------------------------------------------------------------------
statuses = []
victim = None
for i in range(20):
    if i == 3:
        victim = sorted(p["metadata"]["name"] for p in gateway_pods())[0]
        subprocess.run([*K, "delete", "pod", victim, "--wait=false"], check=True, capture_output=True)
    try:
        r = httpx.post(f"{L.GATEWAY}/anthropic/v1/messages", verify=L.VERIFY, timeout=60,
                       headers={"x-api-key": alice, "anthropic-version": "2023-06-01"},
                       json={"model": L.MODEL, "max_tokens": 1, "messages": [{"role": "user", "content": "Hi"}]})
        statuses.append(r.status_code)
    except httpx.HTTPError as err:
        statuses.append(type(err).__name__)
    time.sleep(0.5)
results["pod_delete"] = {"victim": victim, "statuses": statuses}
check(all(s == 200 for s in statuses), "a gateway pod deleted under traffic: no failed request", f"deleted {victim} before call 4 · {statuses}")

if FAULT:
    subprocess.run([*K, "scale", "deploy/langfuse-gateway", "--replicas=2"], check=True, capture_output=True)
L.update_state(helm=results, helm_fault=FAULT, helm_at=L.now().isoformat())
fails = [w for ok, w, _ in rows if ok is False]
print(f"── {sum(1 for ok, *_ in rows if ok)} PASS · {len(fails)} FAIL · {sum(1 for ok, *_ in rows if ok is None)} INFO")
sys.exit(1 if fails else 0)
