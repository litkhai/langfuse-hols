#!/usr/bin/env python3
"""04-experiments.py — compare prompt versions with dataset experiments.

An Experiment runs a task over every item in a Dataset, traces each run, and
scores the output with EVALUATORS. Run it twice (prompt v1 vs v2) and Langfuse
shows the two runs side by side so you can see whether v2 actually improved.

Evaluators here are CODE evaluators — deterministic, offline, no LLM key needed
(lab 05 adds an LLM-as-a-judge). Each returns an `Evaluation(name, value)`.

Docs: https://langfuse.com/docs/evaluation/experiments/experiments-via-sdk
"""
import os
import re

from langfuse import Evaluation, propagate_attributes

from _common import client, generate_answer, use_anthropic

DATASET_NAME = os.environ.get("DATASET_NAME", "support-golden-qa")
PROMPT_NAME = os.environ.get("PROMPT_NAME", "support-system")
MODEL = "claude-haiku-4-5"

lf = client()


# ── Code evaluators (keyword-only signature, per the SDK) ─────────────────────
def keyword_recall(*, input, output, expected_output, **kwargs) -> Evaluation:
    """Fraction of the expected answer's key words that appear in the output."""
    key = {w for w in re.findall(r"[a-z]+", (expected_output or "").lower()) if len(w) > 4}
    hits = sum(1 for w in key if w in (output or "").lower())
    val = hits / len(key) if key else 0.0
    return Evaluation(name="keyword-recall", value=round(val, 3),
                      comment=f"{hits}/{len(key)} key words present")


def length_ok(*, output, **kwargs) -> Evaluation:
    ok = 0 < len(output or "") <= 300
    return Evaluation(name="length-ok", value=1.0 if ok else 0.0)


def answered(*, output, **kwargs) -> Evaluation:
    """Penalize generic deflections ('check our documentation / contact support')."""
    low = (output or "").lower()
    deflecting = "check our documentation" in low or "contact support" in low
    return Evaluation(name="answered", value=0.0 if deflecting else 1.0,
                      comment="deflection" if deflecting else "answered")


EVALUATORS = [keyword_recall, length_ok, answered]


def make_task(prompt_obj, variant: str):
    """Build a task that answers each item using the given prompt version."""
    system_prompt = prompt_obj.compile(tone="friendly")

    def task(*, item, **kwargs):
        question = item.input["question"]
        # With ANTHROPIC_API_KEY the instrumented Anthropic client creates the
        # GENERATION itself (model, real tokens, cost), so we do not wrap it; the
        # prompt LINK is propagated onto it with propagate_attributes(prompt=...).
        if use_anthropic():
            with propagate_attributes(prompt=prompt_obj):
                return generate_answer(system_prompt=system_prompt, question=question,
                                       expected=item.expected_output, variant=variant, model=MODEL)
        # Offline: wrap in a generation so the trace carries model + usage + the
        # prompt LINK. Usage keys are `input`/`output` so Langfuse can price them.
        with lf.start_as_current_observation(
            as_type="generation", name="answer-generation", model=MODEL, prompt=prompt_obj,
            input=[{"role": "system", "content": system_prompt},
                   {"role": "user", "content": question}],
        ) as gen:
            answer = generate_answer(system_prompt=system_prompt, question=question,
                                     expected=item.expected_output, variant=variant, model=MODEL)
            gen.update(output=answer, usage_details={
                "input": (len(system_prompt) + len(question)) // 4,
                "output": max(1, len(answer) // 4),
            })
        return answer

    return task


def run(dataset, name: str, description: str, prompt_obj, variant: str):
    """Run one experiment, tagging every observation of every item with its variant.

    Tag the experiment traces with their variant so ClickHouse can reconstruct the
    v1-vs-v2 A/B by joining scores → events (lab 07 §4). SDK v4: propagate_attributes()
    replaces update_current_trace(). It wraps run_experiment() rather than the task, so
    the attributes also reach the root `experiment-item-run` observation (the row the
    trace is identified by); wrapped inside the task they would start one level lower.
    """
    with propagate_attributes(tags=[f"variant:{variant}", "eval-experiment"],
                              metadata={"variant": variant}):
        return dataset.run_experiment(name=name, description=description,
                                      task=make_task(prompt_obj, variant), evaluators=EVALUATORS)


def main() -> None:
    dataset = lf.get_dataset(DATASET_NAME)
    prompt_v1 = lf.get_prompt(PROMPT_NAME, version=1)          # terse
    prompt_v2 = lf.get_prompt(PROMPT_NAME, label="production")  # guard-railed (v2)

    print(f"Running experiments over '{DATASET_NAME}' "
          f"({'REAL Anthropic ' + MODEL if use_anthropic() else 'offline / simulated'})…\n")

    res_v1 = run(dataset, "prompt-v1", "Terse v1 system prompt", prompt_v1, "v1")
    res_v2 = run(dataset, "prompt-v2", "Guard-railed v2 system prompt", prompt_v2, "v2")

    lf.flush()

    print("──────── prompt-v1 ────────")
    print(res_v1.format())
    print("\n──────── prompt-v2 ────────")
    print(res_v2.format())
    print("\n✓ Two runs created. UI → Datasets →", DATASET_NAME,
          "→ Runs: compare prompt-v1 vs prompt-v2 side by side.")
    print("  Tip: swap MODEL to also compare models on the same dataset.")


if __name__ == "__main__":
    main()
