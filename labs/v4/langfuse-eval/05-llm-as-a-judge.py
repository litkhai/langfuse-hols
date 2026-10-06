#!/usr/bin/env python3
"""05-llm-as-a-judge.py — score outputs with an LLM judge (hybrid).

LLM-as-a-judge uses a model to grade another model's output. This script runs an
experiment whose evaluator IS a judge, so the judge's scores land on the run and
in ClickHouse (visible in lab 07). NOTE: SDK-written scores have source=API; only
Langfuse's MANAGED evaluators write source=EVAL (see 05-llm-as-a-judge.md).

HYBRID by design:
  • OFFLINE (default, no key): a deterministic rubric approximates a judge, so the
    lab always runs and always produces judge scores.
  • REAL (ANTHROPIC_API_KEY set): a genuine Claude call grades correctness 0.0–1.0.

For Langfuse's fully MANAGED LLM-as-a-judge (observation-level evaluators that run
automatically on production observations or dataset runs), see the companion guide
→ 05-llm-as-a-judge.md (needs an Anthropic LLM connection in the UI's "LLM Connections").
"""
import os
import re

from langfuse import Evaluation, propagate_attributes

from _common import ask_claude, client, generate_answer, use_anthropic

DATASET_NAME = os.environ.get("DATASET_NAME", "support-golden-qa")
PROMPT_NAME = os.environ.get("PROMPT_NAME", "support-system")
JUDGE_MODEL = os.environ.get("EVAL_JUDGE_MODEL", "claude-haiku-4-5")
MODEL = "claude-haiku-4-5"

lf = client()


def llm_judge(*, input, output, expected_output, **kwargs) -> Evaluation:
    """Grade the candidate answer 0.0–1.0 against the reference."""
    question = (input or {}).get("question", "")

    if use_anthropic():
        # The call is auto-traced (a GENERATION under this evaluator's span).
        text = ask_claude(
            system="You are a strict grader for a customer-support assistant.",
            user=(f"Question: {question}\nReference answer: {expected_output}\n"
                  f"Candidate answer: {output}\n\n"
                  "Score how correct and grounded the candidate is, from 0.0 to 1.0. "
                  "Reply with ONLY the number."),
            model=JUDGE_MODEL, max_tokens=256)
        try:
            val = float(re.findall(r"[01](?:\.\d+)?", text)[0])
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


def run(dataset, name: str, description: str, prompt_obj, variant: str):
    """Run one judged experiment; tag every observation with its variant (see 04).

    SDK v4: propagate_attributes() replaces update_current_trace(), and wraps
    run_experiment() so the tags reach the root `experiment-item-run` row as well.
    """
    with propagate_attributes(tags=[f"variant:{variant}", "eval-experiment"],
                              metadata={"variant": variant}):
        return dataset.run_experiment(name=name, description=description,
                                      task=make_task(prompt_obj, variant), evaluators=[llm_judge])


def main() -> None:
    dataset = lf.get_dataset(DATASET_NAME)
    v1 = lf.get_prompt(PROMPT_NAME, version=1)
    v2 = lf.get_prompt(PROMPT_NAME, label="production")

    mode = "REAL LLM judge (" + JUDGE_MODEL + ")" if use_anthropic() else "offline rubric judge"
    print(f"Judging both prompt versions with the {mode}…\n")

    r1 = run(dataset, "judge-prompt-v1", "LLM judge on v1", v1, "v1")
    r2 = run(dataset, "judge-prompt-v2", "LLM judge on v2", v2, "v2")
    lf.flush()

    print("──────── judge-prompt-v1 ────────"); print(r1.format())
    print("\n──────── judge-prompt-v2 ────────"); print(r2.format())
    print("\n✓ LLM-judge scores written (name: llm-judge-correctness, source=API via SDK).")
    print("  Managed evaluators (observation-level, source=EVAL): 05-llm-as-a-judge.md")


if __name__ == "__main__":
    main()
