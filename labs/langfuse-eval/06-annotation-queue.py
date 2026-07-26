#!/usr/bin/env python3
"""06-annotation-queue.py — human-in-the-loop scoring.

Annotation Queues let domain experts add scores + comments to traces in a focused,
keyboard-driven UI. You define SCORE CONFIGS (the scoring dimensions), create a
queue bound to them, and enqueue traces to review.

This script (all via the Public REST API — no SDK helper for these):
  1. Ensures two score configs: `answer-quality` (categorical), `factually-correct` (boolean).
  2. Ensures a queue `human-review` bound to those configs.
  3. Enqueues recent seed traces (from lab 01) for review.
  4. Injects a few DEMO review scores so lab 07 has data to analyze.

     ⚠️ The demo scores are written via the SDK, so their `source` is `API`. Real
     human scores submitted in the UI queue arrive with `source = 'ANNOTATION'`.
     Do the real thing in the UI → Annotations to see ANNOTATION-source scores.

Queues + configs live in Postgres; the resulting scores live in ClickHouse.
"""
import os

from _common import api, client

QUEUE_NAME = "human-review"


def ensure_score_config(name, data_type, categories=None):
    for c in api("GET", "/api/public/score-configs?limit=100").get("data", []):
        if c.get("name") == name:
            return c["id"]
    body = {"name": name, "dataType": data_type}
    if categories:
        body["categories"] = categories
    return api("POST", "/api/public/score-configs", body)["id"]


def ensure_queue(name, score_config_ids):
    for q in api("GET", "/api/public/annotation-queues?limit=100").get("data", []):
        if q.get("name") == name:
            return q["id"]
    return api("POST", "/api/public/annotation-queues",
               {"name": name, "description": "Human review of support answers",
                "scoreConfigIds": score_config_ids})["id"]


def main() -> None:
    lf = client()  # also validates auth

    # 1) Score configs (the review dimensions).
    quality_id = ensure_score_config(
        "answer-quality", "CATEGORICAL",
        categories=[{"label": "good", "value": 1}, {"label": "ok", "value": 0.5},
                    {"label": "bad", "value": 0}])
    correct_id = ensure_score_config("factually-correct", "BOOLEAN")  # categories auto
    print(f"✓ score configs: answer-quality={quality_id[:8]}… factually-correct={correct_id[:8]}…")

    # 2) Queue bound to those configs.
    queue_id = ensure_queue(QUEUE_NAME, [quality_id, correct_id])
    print(f"✓ queue '{QUEUE_NAME}' = {queue_id}")

    # 3) Enqueue recent SEED traces (name=support-request), not experiment traces —
    #    so the human scores co-occur with the seed user-feedback scores (lab 07 §5).
    traces = api("GET", "/api/public/traces?name=support-request&limit=8").get("data", [])
    if not traces:
        raise SystemExit("✗ No support-request traces found — run `python 01-seed-traces.py` first.")
    trace_ids = [t["id"] for t in traces]
    for tid in trace_ids:
        api("POST", f"/api/public/annotation-queues/{queue_id}/items",
            {"objectId": tid, "objectType": "TRACE"})
    print(f"✓ enqueued {len(trace_ids)} traces for human review")

    # 4) Demo review scores (source=API; a real reviewer in the UI → source=ANNOTATION).
    #    We DON'T pass config_id here: a score bound to a config must match that
    #    config's exact data_type, and these stand-in scores just need to populate
    #    lab 07. Real annotations submitted in the UI are bound to the configs above.
    for i, tid in enumerate(trace_ids):
        lf.create_score(name="human-answer-quality", trace_id=tid,
                        value=1.0 if i % 4 else 0.5, data_type="NUMERIC",
                        comment="demo review")
        lf.create_score(name="human-factually-correct", trace_id=tid,
                        value=0 if i % 5 == 0 else 1, data_type="BOOLEAN",
                        comment="demo review")
    lf.flush()
    print(f"✓ wrote demo review scores on {len(trace_ids)} traces")
    print(f"\n  UI → Annotations → {QUEUE_NAME}: score items with ↑/↓, 1–9, Cmd/Ctrl+Enter.")
    print("  Real UI scores land in ClickHouse `scores` with source='ANNOTATION' (lab 07).")


if __name__ == "__main__":
    main()
