#!/usr/bin/env python3
"""05-llm-as-a-judge.py — score outputs with an LLM judge (hybrid).

LLM-as-a-judge uses a model to grade another model's output. This script runs an
experiment whose evaluator IS a judge, so the judge's scores land on the run and
in ClickHouse (visible in lab 07). NOTE: SDK-written scores have source=API; only
Langfuse's MANAGED evaluators write source=EVAL (see 05-llm-as-a-judge.md).

HYBRID by design:
  • OFFLINE (default, no key): a deterministic rubric approximates a judge, so the
    lab always runs and always produces judge scores.
  • REAL (OPENAI_API_KEY set): a genuine LLM call grades correctness 0.0–1.0.

For Langfuse's fully MANAGED LLM-as-a-judge (pre-built Hallucination / Toxicity /
Context-Relevance evaluators that auto-run on production traces or dataset runs),
see the companion guide → 05-llm-as-a-judge.md (needs an LLM key in the UI's
"LLM Connections").
"""
import os
import re

from langfuse import Evaluation

from _common import client, generate_answer

DATASET_NAME = os.environ.get("DATASET_NAME", "support-golden-qa")
PROMPT_NAME = os.environ.get("PROMPT_NAME", "support-system")
JUDGE_MODEL = os.environ.get("EVAL_JUDGE_MODEL", "gpt-4o-mini")
MODEL = "gpt-4o-mini"

lf = client()


def llm_judge(*, input, output, expected_output, **kwargs) -> Evaluation:
    """Grade the candidate answer 0.0–1.0 against the reference."""
    question = (input or {}).get("question", "")

    if os.environ.get("OPENAI_API_KEY"):
        from langfuse.openai import openai  # auto-traced judge call

        rubric = (
            "You are a strict grader for a customer-support assistant.\n"
            f"Question: {question}\nReference answer: {expected_output}\n"
            f"Candidate answer: {output}\n\n"
            "Score how correct and grounded the candidate is, from 0.0 to 1.0. "
            "Reply with ONLY the number."
        )
        resp = openai.chat.completions.create(
            model=JUDGE_MODEL, messages=[{"role": "user", "content": rubric}])
        try:
            val = float(re.findall(r"[01](?:\.\d+)?", resp.choices[0].message.content)[0])
        except (IndexError, ValueError):
            val = 0.0
        return Evaluation(name="llm-judge-correctness", value=round(min(1.0, val), 3),
                          comment=f"graded by {JUDGE_MODEL}")

    # Offline rubric: token overlap with the reference, zeroed on deflections.
    out, exp = (output or "").lower(), (expected_output or "").lower()
    exp_words = {w for w in re.findall(r"[a-z]+", exp) if len(w) > 3}
    overlap = sum(1 for w in exp_words if w in out) / len(exp_words) if exp_words else 0.0
    deflecting = "documentation" in out and "contact support" in out
    return Evaluation(name="llm-judge-correctness",
                      value=0.0 if deflecting else round(overlap, 3),
                      comment="offline rubric (token overlap)")


def make_task(prompt_obj, variant: str):
    system_prompt = prompt_obj.compile(tone="friendly")

    def task(*, item, **kwargs):
        return generate_answer(system_prompt=system_prompt, question=item.input["question"],
                               expected=item.expected_output, variant=variant, model=MODEL)

    return task


def main() -> None:
    dataset = lf.get_dataset(DATASET_NAME)
    v1 = lf.get_prompt(PROMPT_NAME, version=1)
    v2 = lf.get_prompt(PROMPT_NAME, label="production")

    mode = "REAL LLM judge (" + JUDGE_MODEL + ")" if os.environ.get("OPENAI_API_KEY") \
        else "offline rubric judge"
    print(f"Judging both prompt versions with the {mode}…\n")

    r1 = dataset.run_experiment(name="judge-prompt-v1", description="LLM judge on v1",
                                task=make_task(v1, "v1"), evaluators=[llm_judge])
    r2 = dataset.run_experiment(name="judge-prompt-v2", description="LLM judge on v2",
                                task=make_task(v2, "v2"), evaluators=[llm_judge])
    lf.flush()

    print("──────── judge-prompt-v1 ────────"); print(r1.format())
    print("\n──────── judge-prompt-v2 ────────"); print(r2.format())
    print("\n✓ LLM-judge scores written (name: llm-judge-correctness, source=API via SDK).")
    print("  Managed evaluators (Hallucination/Toxicity/…, source=EVAL): 05-llm-as-a-judge.md")


if __name__ == "__main__":
    main()
