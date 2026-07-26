#!/usr/bin/env python3
"""99-cleanup.py — remove what THIS lab created (best-effort).

Deletes only the lab's own artifacts (prompts, dataset, annotation queue, score
configs). It does NOT touch the Docker stack — that belongs to the sibling lab
(`../langfuse-ee/99-cleanup.sh`).

Some Langfuse resources have no stable DELETE endpoint across versions, so this
is best-effort: it attempts each delete and, on failure, prints the manual UI
step instead of crashing. Nothing here is destructive to the stack.
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

    # Annotation queue.
    queues = {q.get("name"): q.get("id")
              for q in api("GET", "/api/public/annotation-queues?limit=100").get("data", [])}
    if QUEUE_NAME in queues:
        try_delete(f"queue '{QUEUE_NAME}'", "DELETE",
                   f"/api/public/annotation-queues/{queues[QUEUE_NAME]}")
    else:
        print(f"  • queue '{QUEUE_NAME}' not found (already gone)")

    # Datasets / score configs generally have no delete endpoint — guide the user.
    print(f"\n  Manual (no stable DELETE API):")
    print(f"    • dataset '{DATASET_NAME}'  → UI → Datasets → … → Delete")
    print(f"    • score configs (answer-quality, factually-correct) → UI → Settings → Scores")
    print("\n  The Docker stack is untouched — stop it via ../langfuse-ee/99-cleanup.sh")


if __name__ == "__main__":
    main()
