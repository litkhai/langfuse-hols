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

from langfuse import Evaluation

from _common import client, generate_answer

DATASET_NAME = os.environ.get("DATASET_NAME", "support-golden-qa")
PROMPT_NAME = os.environ.get("PROMPT_NAME", "support-system")
MODEL = "gpt-4o-mini"

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
        # Tag the auto-created experiment trace with its variant so ClickHouse can
        # reconstruct the v1-vs-v2 A/B by joining scores → traces (lab 07 §4).
        lf.update_current_trace(tags=[f"variant:{variant}", "eval-experiment"],
                                metadata={"variant": variant})
        # Offline: wrap in a generation so the trace carries model + usage + the
        # prompt LINK. With OPENAI_API_KEY the drop-in wrapper self-traces, so we
        # avoid double-instrumenting.
        if os.environ.get("OPENAI_API_KEY"):
            return generate_answer(system_prompt=system_prompt, question=question,
                                   expected=item.expected_output, variant=variant, model=MODEL)
        with lf.start_as_current_observation(
            as_type="generation", name="answer-generation", model=MODEL,
            prompt=prompt_obj,
            input=[{"role": "system", "content": system_prompt},
                   {"role": "user", "content": question}],
        ) as gen:
            answer = generate_answer(system_prompt=system_prompt, question=question,
                                     expected=item.expected_output, variant=variant, model=MODEL)
            gen.update(output=answer, usage_details={
                "input_tokens": (len(system_prompt) + len(question)) // 4,
                "output_tokens": max(1, len(answer) // 4),
            })
        return answer

    return task


def main() -> None:
    dataset = lf.get_dataset(DATASET_NAME)
    prompt_v1 = lf.get_prompt(PROMPT_NAME, version=1)          # terse
    prompt_v2 = lf.get_prompt(PROMPT_NAME, label="production")  # guard-railed (v2)

    print(f"Running experiments over '{DATASET_NAME}' "
          f"({'REAL OpenAI' if os.environ.get('OPENAI_API_KEY') else 'offline / simulated'})…\n")

    res_v1 = dataset.run_experiment(
        name="prompt-v1", description="Terse v1 system prompt",
        task=make_task(prompt_v1, "v1"), evaluators=EVALUATORS)
    res_v2 = dataset.run_experiment(
        name="prompt-v2", description="Guard-railed v2 system prompt",
        task=make_task(prompt_v2, "v2"), evaluators=EVALUATORS)

    lf.flush()

    print("──────── prompt-v1 ────────")
    print(res_v1.format())
    print("\n──────── prompt-v2 ────────")
    print(res_v2.format())
    print("\n✓ Two runs created. UI → Datasets →", DATASET_NAME,
          "→ Runs: compare prompt-v1 vs prompt-v2 side by side.")
    print("  Tip: swap MODEL in make_task to also compare models on the same dataset.")


if __name__ == "__main__":
    main()
