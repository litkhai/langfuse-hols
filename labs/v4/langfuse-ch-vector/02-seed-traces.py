#!/usr/bin/env python3
"""02-seed-traces.py — send Korean-language banking-support traces to the shared Langfuse v4.

Offline: answers, tokens and failures are simulated (no model API). Every trace carries the
tag `lab:langfuse-ch-vector`, so the pipeline and the cleanup touch only this lab's data.

    banking-support          root span  input {"question"}, output {"answer"} or level ERROR
    ├── retrieve-faq         span
    └── answer-generation    generation (gpt-4o-mini, simulated usage)

The intent a wording came from is written to metadata `seed_intent` — only so 05-topics.py
can score its clusters against the truth. The pipeline never reads it.

Usage:
    .venv-vector/bin/python labs/v4/langfuse-ch-vector/02-seed-traces.py            # 12 intents × 10 wordings × 2 rounds = 240
    .venv-vector/bin/python labs/v4/langfuse-ch-vector/02-seed-traces.py --failing  # one new failing trace (04-similar.py calls this)
"""
import argparse
import os
import random
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lablib as L
from corpus import FAILING_QUESTION, FAILING_STATUS, INTENTS
from langfuse import Langfuse, propagate_attributes

ap = argparse.ArgumentParser()
ap.add_argument("--rounds", type=int, default=2)
ap.add_argument("--failing", action="store_true", help="send only the one failing trace of 04-similar.py")
args = ap.parse_args()

lf = Langfuse(base_url=os.environ.get("LANGFUSE_HOST", "http://localhost:3000"),
              public_key=os.environ["LANGFUSE_PUBLIC_KEY"], secret_key=os.environ["LANGFUSE_SECRET_KEY"])
if not lf.auth_check():
    sys.exit("auth check failed: is the v4 stack up and _base/.env present?")

rng = random.Random(42)  # private RNG: same failures every run; OpenTelemetry ids come from the global one


def one_trace(question, intent, answers, fail_p, status, user, session, force_fail=False):
    failed = force_fail or rng.random() < fail_p
    with propagate_attributes(trace_name="banking-support", user_id=user, session_id=session,
                              tags=[L.LAB_TAG, "app:banking-support"],
                              metadata={"channel": rng.choice(["ios", "android", "web"]),
                                        "seed_intent": intent}):
        with lf.start_as_current_observation(as_type="span", name="banking-support",
                                             input={"question": question}) as root:
            with lf.start_as_current_observation(as_type="span", name="retrieve-faq",
                                                 input={"query": question}) as ret:
                ret.update(output={"doc_ids": [f"faq-{intent}-{rng.randint(1, 9)}" for _ in range(3)]})
            with lf.start_as_current_observation(
                    as_type="generation", name="answer-generation", model="gpt-4o-mini",
                    input=[{"role": "system", "content": "은행 앱 상담 도우미입니다."},
                           {"role": "user", "content": question}]) as gen:
                time.sleep(rng.uniform(0.01, 0.04))
                if failed:
                    gen.update(level="ERROR", status_message=status)
                else:
                    answer = rng.choice(answers)
                    gen.update(output=answer, usage_details={"input": rng.randint(300, 900),
                                                             "output": rng.randint(60, 220)})
            if failed:
                root.update(level="ERROR", status_message=status, output={"error": status})
            else:
                root.update(output={"answer": answer})
        return root.trace_id, failed


sent, failed_n = [], 0
if args.failing:
    tid, _ = one_trace(FAILING_QUESTION, "app_error", [""], 1.0, FAILING_STATUS,
                       "user_901", "sess_failing", force_fail=True)
    sent.append(tid)
else:
    for r in range(args.rounds):
        for key, _label, wordings, answers, (fail_p, status) in INTENTS:
            for w in wordings:
                user = f"user_{rng.randint(1, 60):03d}"
                tid, f = one_trace(w, key, answers, fail_p, status, user, f"sess_{user}_{r}")
                sent.append(tid)
                failed_n += f
lf.flush()
print(f"sent {len(sent)} traces ({failed_n if not args.failing else 1} with level ERROR), tag {L.LAB_TAG}")
if args.failing:
    print("failing trace id", sent[0])
    os.makedirs(os.path.join(L.LAB_DIR, ".run"), exist_ok=True)
    with open(os.path.join(L.LAB_DIR, ".run", "failing_trace_id"), "w") as fh:
        fh.write(sent[0])
