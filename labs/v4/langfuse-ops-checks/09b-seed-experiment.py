"""09b-seed-experiment.py — a dataset with three items and one experiment run over it, for test 09.

No model calls: the task echoes the input, the evaluator scores exact match. Reads LANGFUSE_HOST,
LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY from the environment (lib.sh exports them).
    Usage: .venv-v4/bin/python 09b-seed-experiment.py [run-name]
"""
import sys

from langfuse import Evaluation, Langfuse

RUN = sys.argv[1] if len(sys.argv) > 1 else "audit-run"
DS = "audit-ds"

lf = Langfuse()
lf.create_dataset(name=DS, description="test 09 read-access audit")
for i, q in enumerate(["alpha", "beta", "gamma"]):
    lf.create_dataset_item(dataset_name=DS, id=f"audit-item-{i}", input={"q": q}, expected_output={"a": q})


def task(*, item, **_):
    return {"a": item.input["q"]}


def exact(*, output, expected_output, **_):
    return Evaluation(name="exact", value=1.0 if output == expected_output else 0.0)


result = lf.get_dataset(DS).run_experiment(name=RUN, task=task, evaluators=[exact])
lf.flush()
print(f"dataset {DS}: run {RUN}, {len(result.item_results)} items")
