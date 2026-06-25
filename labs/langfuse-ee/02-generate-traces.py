#!/usr/bin/env python3
"""
02-generate-traces.py — push realistic LLM traces into self-hosted Langfuse.

Simulates a customer-support RAG assistant. Each trace is one user turn and
contains a nested observation tree:

    support-request            (root span, carries user_id / session_id / tags)
    ├── retrieve-context       (span    — vector search over a knowledge base)
    ├── answer-generation      (generation — the LLM call, with token usage)
    └── (sometimes) self-check (generation — a cheap guardrail model)

…plus per-trace scores (user-thumbs, response-latency, hallucination-check).

Langfuse stores every trace / observation / score in ClickHouse — labs 03 and 04
then query that backend directly.

Runs FULLY OFFLINE by default (no LLM API needed): responses and token counts
are simulated. Set OPENAI_API_KEY in .env to make real OpenAI calls instead.

Usage:
    pip install "langfuse>=3" openai
    python 02-generate-traces.py            # 40 traces
    python 02-generate-traces.py 200        # 200 traces
"""
import os
import sys
import time
import random

# Load .env from this directory so LANGFUSE_* / OPENAI_API_KEY are available
# (the same file docker-compose reads). No external dependency required.
def _load_dotenv(path: str) -> None:
    if not os.path.exists(path):
        return
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key, val = key.strip(), val.split(" #", 1)[0].strip().strip('"').strip("'")
            os.environ.setdefault(key, val)


_load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))

from langfuse import Langfuse, get_client

# ── Config ───────────────────────────────────────────────────────────────────
N_TRACES = int(sys.argv[1]) if len(sys.argv) > 1 else 40
USE_OPENAI = bool(os.environ.get("OPENAI_API_KEY"))
random.seed(42)

# Models Langfuse already knows the prices of → cost is computed automatically
# from model name + usage_details (no manual cost entry needed).
MODELS = [
    # (model, prompt_tok_range, completion_tok_range, latency_seconds_range)
    ("gpt-4o-mini",            (300, 1200), (60, 350),  (0.15, 0.6)),
    ("gpt-4o",                 (300, 1500), (80, 500),  (0.4, 1.6)),
    ("claude-3-5-sonnet-20241022", (350, 1600), (90, 600), (0.5, 1.8)),
]
ENVIRONMENTS = ["production", "production", "production", "staging"]   # weighted
FEATURES = ["search-assist", "billing-help", "onboarding", "troubleshooting"]
TIERS = ["free", "pro", "enterprise"]

QUESTIONS = [
    "How do I reset my password?",
    "Why was my invoice higher this month?",
    "Can I export my data to S3?",
    "How do I add a teammate to my project?",
    "The dashboard is loading slowly, what can I do?",
    "Does the API support pagination?",
    "How do I rotate my API keys?",
    "What regions are available for hosting?",
    "How do I set a data retention policy?",
    "Can I use SSO with Okta?",
]
ANSWERS = [
    "You can reset your password from Settings → Security → Reset password.",
    "Your invoice rose because usage exceeded the included quota; see the Billing page.",
    "Yes — configure a Blob Storage Export under Project Settings → Exports.",
    "Open Organization Settings → Members and invite them by email with a role.",
    "Try narrowing the date range; large windows scan more data.",
    "Yes, list endpoints accept `limit` and `page` query parameters.",
    "Create new keys in Project Settings → API Keys, then revoke the old ones.",
    "We host in US and EU regions; choose at project creation.",
    "Owners/Admins set it in Project Settings → Data Retention (min 3 days).",
    "Yes, Okta is supported via OIDC/SAML on self-hosted Enterprise.",
]


def simulated_answer(question_idx: int) -> str:
    return ANSWERS[question_idx]


def main():
    # Init reads LANGFUSE_HOST / LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY from env.
    Langfuse(
        host=os.environ.get("LANGFUSE_HOST", "http://localhost:3000"),
        public_key=os.environ["LANGFUSE_PUBLIC_KEY"],
        secret_key=os.environ["LANGFUSE_SECRET_KEY"],
    )
    lf = get_client()

    if not lf.auth_check():
        print("✗ Auth check failed — verify LANGFUSE_HOST / keys in .env and that the stack is up.")
        sys.exit(1)
    print(f"✓ Connected. Generating {N_TRACES} traces "
          f"({'REAL OpenAI calls' if USE_OPENAI else 'offline / simulated'})…")

    users = [f"user_{i:03d}" for i in range(1, 13)]

    for t in range(N_TRACES):
        q_idx = random.randrange(len(QUESTIONS))
        question = QUESTIONS[q_idx]
        model, ptok_r, ctok_r, lat_r = random.choice(MODELS)
        env = random.choice(ENVIRONMENTS)
        feature = random.choice(FEATURES)
        tier = random.choice(TIERS)
        user_id = random.choice(users)
        session_id = f"sess_{user_id}_{t // 5}"   # ~5 turns per session
        # ~8% of traces hit an error in the generation step
        will_error = random.random() < 0.08

        with lf.start_as_current_observation(as_type="span", name="support-request") as root:
            # Trace-level attributes: searchable/filterable in the UI and in ClickHouse.
            lf.update_current_trace(
                name="support-request",
                user_id=user_id,
                session_id=session_id,
                input={"question": question},
                tags=[f"env:{env}", f"feature:{feature}", f"tier:{tier}"],
                metadata={"channel": "web", "tier": tier, "environment": env},
            )
            trace_id = lf.get_current_trace_id()

            # 1) Retrieval step (a non-LLM span)
            with lf.start_as_current_observation(as_type="span", name="retrieve-context") as ret:
                time.sleep(random.uniform(0.02, 0.12))
                n_docs = random.randint(2, 6)
                ret.update(
                    input={"query": question, "top_k": n_docs},
                    output={"doc_ids": [f"kb-{random.randint(100, 999)}" for _ in range(n_docs)]},
                    metadata={"retriever": "vector", "index": "support-kb"},
                )

            # 2) Answer generation (the LLM call)
            ptok = random.randint(*ptok_r)
            ctok = random.randint(*ctok_r)
            with lf.start_as_current_observation(
                as_type="generation",
                name="answer-generation",
                model=model,
                input=[
                    {"role": "system", "content": "You are a helpful support assistant."},
                    {"role": "user", "content": question},
                ],
            ) as gen:
                time.sleep(random.uniform(*lat_r))
                if will_error:
                    gen.update(level="ERROR", status_message="upstream model timeout",
                               metadata={"retryable": True})
                    answer = None
                else:
                    answer = real_openai_answer(question, model) if USE_OPENAI else simulated_answer(q_idx)
                    gen.update(
                        output=answer,
                        usage_details={"input_tokens": ptok, "output_tokens": ctok,
                                       "total_tokens": ptok + ctok},
                        metadata={"temperature": 0.2},
                    )

            # 3) Occasional cheap guardrail / self-check generation
            if not will_error and random.random() < 0.4:
                with lf.start_as_current_observation(
                    as_type="generation", name="self-check", model="gpt-4o-mini",
                    input={"answer": answer},
                ) as chk:
                    time.sleep(random.uniform(0.05, 0.2))
                    gptok = random.randint(80, 300)
                    chk.update(output={"grounded": True},
                               usage_details={"input_tokens": gptok, "output_tokens": 5,
                                              "total_tokens": gptok + 5})

            root.update(output={"answer": answer, "errored": will_error})

        # ── Scores (stored alongside traces in ClickHouse `scores` table) ──
        if not will_error:
            # Explicit user feedback — boolean thumbs up/down (mostly up)
            lf.create_score(name="user-thumbs", trace_id=trace_id,
                            value=1 if random.random() < 0.82 else 0,
                            data_type="BOOLEAN",
                            comment="thumbs up" if random.random() < 0.82 else "thumbs down")
            # Automated hallucination check — numeric 0..1 (higher = more grounded)
            lf.create_score(name="hallucination-check", trace_id=trace_id,
                            value=round(random.uniform(0.6, 1.0), 2), data_type="NUMERIC")
        else:
            lf.create_score(name="user-thumbs", trace_id=trace_id, value=0,
                            data_type="BOOLEAN", comment="error response")

        if (t + 1) % 10 == 0:
            print(f"  …{t + 1}/{N_TRACES} traces")

    # CRITICAL in short-lived scripts: flush the async buffer before exit.
    lf.flush()
    print(f"✓ Done. Open {os.environ.get('LANGFUSE_HOST', 'http://localhost:3000')} → Tracing → Traces.")
    print("  Then run the ClickHouse labs:  03-clickhouse-explore.sql, 04-clickhouse-analytics.sql")


def real_openai_answer(question: str, model: str) -> str:
    """Optional: real OpenAI call via Langfuse's drop-in OpenAI wrapper.

    `from langfuse.openai import openai` auto-creates the generation observation
    with model, usage and cost — so we do NOT wrap it in start_as_current_observation
    above when USE_OPENAI is on. For workshop simplicity we keep the simulated
    structure and only swap the text; for production use the drop-in directly.
    """
    from langfuse.openai import openai  # noqa: WPS433 (lazy import)
    oai_model = model if model.startswith("gpt") else "gpt-4o-mini"
    resp = openai.chat.completions.create(
        model=oai_model,
        messages=[
            {"role": "system", "content": "You are a helpful support assistant. Answer in one sentence."},
            {"role": "user", "content": question},
        ],
    )
    return resp.choices[0].message.content


if __name__ == "__main__":
    main()
