#!/usr/bin/env python3
"""03-datasets.py — build a reusable golden test set.

A Dataset is a named collection of test cases (items), each with an `input` and
an `expected_output`. It is the fixture you run experiments (lab 04) against, so
you can measure whether a prompt/model change actually improved quality.

We promote the canonical support Q&A (in _common.py) into dataset items.
Passing a stable `id` makes this idempotent — re-running UPDATES items instead of
creating duplicates.

Datasets live in Postgres (OLTP), like prompts.
Docs: https://langfuse.com/docs/evaluation/experiments/datasets
"""
import os

from _common import SUPPORT_QA, client

DATASET_NAME = os.environ.get("DATASET_NAME", "support-golden-qa")


def main() -> None:
    lf = client()

    lf.create_dataset(
        name=DATASET_NAME,
        description="Canonical support Q&A pairs used to evaluate the support assistant.",
        metadata={"domain": "customer-support", "source": "langfuse-eval lab"},
    )
    print(f"✓ dataset '{DATASET_NAME}' ready")

    for i, (question, answer) in enumerate(SUPPORT_QA):
        lf.create_dataset_item(
            dataset_name=DATASET_NAME,
            id=f"golden-{i:02d}",          # stable id → idempotent upsert
            input={"question": question},
            expected_output=answer,
            metadata={"topic_index": i},
        )
    lf.flush()

    print(f"✓ upserted {len(SUPPORT_QA)} items (ids golden-00 … golden-{len(SUPPORT_QA)-1:02d})")
    print(f"  UI → Datasets → {DATASET_NAME}. Next: run experiments with 04-experiments.py")


if __name__ == "__main__":
    main()
