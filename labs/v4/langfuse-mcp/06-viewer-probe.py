#!/usr/bin/env python3
"""06-viewer-probe.py <trace_id> <observation_id> — the Viewer key against both web containers:
tools/list, a read (getObservation with input) and a write (createScore on a lab trace).
Prints one line per call; the score ids written are saved to .run/probe-scores.txt so
06-viewer-key.sh can delete them."""
import base64, json, os, sys, urllib.request
RUN = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".run")
env = dict(l.strip().split("=", 1) for l in open(os.path.join(RUN, "viewer-key.env")) if "=" in l)
trace = sys.argv[1]; obs = sys.argv[2]
def call(host, key, method, params, i=[0]):
    i[0] += 1
    req = urllib.request.Request(f"{host}/api/public/mcp", method="POST",
        data=json.dumps({"jsonrpc": "2.0", "id": i[0], "method": method, "params": params}).encode(),
        headers={"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                 "Authorization": "Basic " + base64.b64encode(key.encode()).decode()})
    try:
        return json.loads(urllib.request.urlopen(req).read())
    except urllib.error.HTTPError as e:
        return {"http": e.code, "body": e.read().decode()[:200]}
viewer = f"{env['VIEWER_PUBLIC_KEY']}:{env['VIEWER_SECRET_KEY']}"
for host in ("http://localhost:48300", "http://localhost:3000"):
    r = call(host, viewer, "tools/list", {})
    n = len(r["result"]["tools"]) if "result" in r else r
    print(host, "tools/list:", n, "tools")
    r = call(host, viewer, "tools/call", {"name": "getObservation", "arguments": {"observationId": obs, "fields": ["id", "input"]}})
    t = r.get("result", {}).get("content", [{}])[0].get("text", str(r))
    print("  getObservation: input returned, fake phone number visible:", "010-0000-1234" in t)
    r = call(host, viewer, "tools/call", {"name": "createScore", "arguments": {"name": "viewer-write-probe", "traceId": trace, "value": 1, "dataType": "NUMERIC"}})
    res = r.get("result", r)
    if "error" in r:
        print("  createScore: refused |", r["error"]["message"])
    else:
        sid = json.loads(res["content"][0]["text"])["id"]
        open(os.path.join(RUN, "probe-scores.txt"), "a").write(sid + "\n")
        print("  createScore: WRITTEN, score id", sid)
