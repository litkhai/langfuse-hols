#!/usr/bin/env python3
"""99-cleanup.py — remove what THIS lab created (best-effort).

Deletes only the lab's own artifacts, and only where the Public API can: the prompts.
The annotation queue, dataset and score configs have no DELETE endpoint (checked
against the OpenAPI spec and Langfuse 4.48.0), so the script prints the manual UI
step for them instead of crashing. It does NOT touch the Docker stack — that is
shared with the other labs and lives in `_base/` (stop it with `_base/bin/down.sh`).
Nothing here is destructive to the stack.
"""
import os

from _common import api

PROMPT_NAME = os.environ.get("PROMPT_NAME", "support-system")
DATASET_NAME = os.environ.get("DATASET_NAME", "support-golden-qa")
QUEUE_NAME = "human-review"


def try_delete(label, method, path):
    try:
        api(method, path)
        print(f"  ✓ deleted {label}")
    except SystemExit as e:
        print(f"  • could not delete {label} via API ({str(e).splitlines()[0]})")
        print(f"    → remove it in the UI instead.")


def main() -> None:
    print("Cleaning up langfuse-eval artifacts (best-effort)…")

    # Prompts (v2 API). Deleting the prompt removes all its versions.
    for name in (PROMPT_NAME, f"{PROMPT_NAME}-chat"):
        try_delete(f"prompt '{name}'", "DELETE", f"/api/public/v2/prompts/{name}")

    # Annotation queue: the Public API can list queues and delete their ITEMS, but has no
    # DELETE for the queue itself (not in the OpenAPI spec; v4.48.0 answers HTTP 405).
    queues = {q.get("name"): q.get("id")
              for q in api("GET", "/api/public/annotation-queues?limit=100").get("data", [])}
    if QUEUE_NAME in queues:
        print(f"  • queue '{QUEUE_NAME}' has no DELETE endpoint (see below)")
    else:
        print(f"  • queue '{QUEUE_NAME}' not found (already gone)")

    # Queues / datasets / score configs have no delete endpoint — guide the user.
    print(f"\n  Manual (no stable DELETE API):")
    print(f"    • queue '{QUEUE_NAME}'  → UI → Annotations → … → Delete")
    print(f"    • dataset '{DATASET_NAME}'  → UI → Datasets → … → Delete")
    print(f"    • score configs (answer-quality, factually-correct) → UI → Settings → Scores")
    print("\n  The Docker stack is untouched — stop it via _base/bin/down.sh")


if __name__ == "__main__":
    main()
