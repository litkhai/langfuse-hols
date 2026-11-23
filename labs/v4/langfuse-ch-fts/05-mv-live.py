#!/usr/bin/env python3
"""05-mv-live.py — the copy follows new traces, and what it does not follow (deletes).

On the stack's server:
  1. seed LIVE more traces (batch "live") through Langfuse; wait until they are in events_full and
     check the materialized view put each of them into lab_langfuse_ch_fts.events_text,
     with the decoded text searchable through the ngrams(2) index;
  2. delete one of them through Langfuse's public API (DELETE /api/public/traces), wait until
     events_full no longer has it — Langfuse runs a lightweight DELETE — and check the copy still does;
  3. reconcile: a lightweight DELETE on the copy for traces that are gone from events_full.

Writes .run/mv-live.json. Uses the v4 venv for the seed step.
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lablib  # noqa: E402

DB = lablib.LAB_DB
LIVE = int(os.environ.get("LIVE", "20"))
TAG = lablib.LAB_TAG


def wait(pred, what, timeout=180):
    t0 = time.time()
    while time.time() - t0 < timeout:
        v = pred()
        if v:
            return round(time.time() - t0, 1)
        time.sleep(2)
    raise SystemExit(f"✗ timed out waiting for {what}")


def count(sql):
    return int(lablib.ch("LF", sql).strip())


def main():
    os.makedirs(lablib.RUN_DIR, exist_ok=True)
    out = {}
    before_src = count(f"SELECT count() FROM default.events_full WHERE has(tags, '{TAG}') AND has(tags, 'batch:live')")
    before_copy = count(f"SELECT count() FROM {DB}.events_text WHERE has(tags, 'batch:live')")
    py = os.environ.get("LAB_PYTHON") or sys.executable
    print(f"── 1. seed {LIVE} traces (batch live) — events_full has {before_src} live rows, the copy {before_copy}")
    subprocess.run([py, os.path.join(lablib.LAB_DIR, "02-seed.py"), str(LIVE), "live"], check=True)
    want = before_src + 3 * LIVE
    secs = wait(lambda: count(f"SELECT count() FROM default.events_full WHERE has(tags, '{TAG}') AND has(tags, 'batch:live')") >= want,
                "the live traces in events_full")
    src_live = count(f"SELECT count() FROM default.events_full WHERE has(tags, 'batch:live')")
    copy_live = count(f"SELECT count() FROM {DB}.events_text FINAL WHERE has(tags, 'batch:live')")
    missing = count(f"""SELECT count() FROM default.events_full WHERE has(tags, 'batch:live')
                        AND span_id NOT IN (SELECT span_id FROM {DB}.events_text)""")
    hit = count(f"""SELECT count() FROM {DB}.events_text WHERE has(tags, 'batch:live')
                    AND hasAllTokens(lower(input_text), '대출')""")
    truth = count(f"""SELECT count() FROM {DB}.events_text WHERE has(tags, 'batch:live')
                      AND positionUTF8(lower(input_text), '대출') > 0""")
    out["insert"] = {"events_full_rows": src_live, "copy_rows": copy_live, "missing_in_copy": missing,
                     "seconds_until_in_events_full": secs, "daechul_index": hit, "daechul_truth": truth}
    print(f"   events_full {src_live} rows, copy {copy_live} rows, missing in copy {missing}; "
          f"'대출' through the ngrams(2) index {hit} (truth {truth}); {secs} s until visible")

    victim = lablib.ch("LF", f"SELECT any(trace_id) FROM default.events_full WHERE has(tags, 'batch:live')").strip()
    print(f"── 2. delete trace {victim} through the public API")
    auth = base64.b64encode(f"{os.environ['LANGFUSE_PUBLIC_KEY']}:{os.environ['LANGFUSE_SECRET_KEY']}".encode()).decode()
    host = os.environ.get("LANGFUSE_HOST", "http://localhost:3000").rstrip("/")
    req = urllib.request.Request(f"{host}/api/public/traces", method="DELETE",
                                 data=json.dumps({"traceIds": [victim]}).encode(),
                                 headers={"Authorization": "Basic " + auth, "Content-Type": "application/json"})
    print("   " + urllib.request.urlopen(req).read().decode())
    secs = wait(lambda: count(f"SELECT count() FROM default.events_full WHERE trace_id = '{victim}'") == 0,
                "the delete in events_full")
    lablib.ch("LF", "SYSTEM FLUSH LOGS")
    how = lablib.ch("LF", f"""SELECT query_kind FROM system.query_log WHERE type = 'QueryFinish'
        AND query_kind = 'Delete' AND query LIKE '%events_full%' AND query LIKE '%{victim}%' LIMIT 1""").strip()
    in_copy = count(f"SELECT count() FROM {DB}.events_text WHERE trace_id = '{victim}'")
    out["delete"] = {"trace_id": victim, "seconds_until_gone": secs, "statement_kind": how or "not found",
                     "copy_rows_after_delete": in_copy}
    print(f"   gone from events_full after {secs} s (statement kind: {how or 'not found'}); still in the copy: {in_copy} rows")

    print("── 3. reconcile the copy")
    lablib.ch("LF", f"""DELETE FROM {DB}.events_text WHERE has(tags, 'batch:live') AND trace_id NOT IN
        (SELECT trace_id FROM default.events_full WHERE has(tags, '{TAG}') AND has(tags, 'batch:live'))""")
    after = count(f"SELECT count() FROM {DB}.events_text WHERE trace_id = '{victim}'")
    out["reconcile"] = {"copy_rows_after": after}
    print(f"   copy rows for the deleted trace after the reconcile DELETE: {after}")
    json.dump(out, open(os.path.join(lablib.RUN_DIR, "mv-live.json"), "w"), ensure_ascii=False, indent=1)
    print("✓ .run/mv-live.json")


if __name__ == "__main__":
    main()
