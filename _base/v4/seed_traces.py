#!/usr/bin/env python3
"""
seed_traces.py — push realistic LLM traces into self-hosted Langfuse.

Simulates a customer-support RAG assistant. Each trace is one user turn and
contains a nested observation tree:

    support-request            (root span, carries user_id / session_id / tags)
    ├── retrieve-context       (span    — vector search over a knowledge base)
    ├── answer-generation      (generation — the LLM call, with token usage)
    └── (sometimes) self-check (generation — a cheap guardrail model)

…plus per-trace scores (user-thumbs, response-latency, hallucination-check).

Langfuse v4 stores every observation in ClickHouse (events_full / events_core; a
trace is its root observation, with user / session / tags / metadata on every
row) and every score in `scores` — labs 03 and 04 then query that backend directly.

Runs FULLY OFFLINE by default (no LLM API needed): responses and token counts
are simulated. Set ANTHROPIC_API_KEY in _base/.env to make real Anthropic calls
(model claude-haiku-4-5) instead; they are traced by
opentelemetry-instrumentation-anthropic.

Shared by the labs: langfuse-ee calls it as `02-generate-traces.py`, langfuse-eval
as `01-seed-traces.py`; both just forward their argv here.

Usage (from the repository root, Python 3.10+):
    python3.12 -m venv .venv-v4 && .venv-v4/bin/pip install -r _base/v4/requirements.txt
    .venv-v4/bin/python _base/v4/seed_traces.py            # 40 traces
    .venv-v4/bin/python _base/v4/seed_traces.py 200        # 200 traces
"""
import os
import sys
import time
import random

# Load _base/.env (this file lives in _base/v4/) so LANGFUSE_* / ANTHROPIC_API_KEY
# are available (the same file docker-compose reads). No external dependency.
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


_BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_load_dotenv(os.path.join(_BASE_DIR, ".env"))

from langfuse import Langfuse, get_client, propagate_attributes

# ── Config ───────────────────────────────────────────────────────────────────
N_TRACES = int(sys.argv[1]) if len(sys.argv) > 1 else 40
USE_ANTHROPIC = bool(os.environ.get("ANTHROPIC_API_KEY"))
ANTHROPIC_MODEL = "claude-haiku-4-5"   # the model used for real calls
# A private RNG keeps the simulation reproducible without seeding the global `random`
# module — OpenTelemetry draws trace/span ids from it, so a global seed would make every
# run re-send the same ids (duplicate rows in events_full that FINAL cannot merge).
rng = random.Random(42)

# Models Langfuse already knows the prices of → cost is computed automatically
# from model name + usage_details (no manual cost entry needed). Cost is only
# computed when the usage keys match the model's price keys: send `input` and
# `output` (Langfuse derives the total). Keep only models that have a price
# definition on the server (GET /api/public/models) — an unknown model costs 0.
MODELS = [
    # (model, prompt_tok_range, completion_tok_range, latency_seconds_range)
    ("gpt-4o-mini",      (300, 1200), (60, 350), (0.15, 0.6)),
    ("gpt-4o",           (300, 1500), (80, 500), (0.4, 1.6)),
    ("claude-haiku-4-5", (300, 1300), (70, 400), (0.2, 0.9)),
]
ENVIRONMENTS = ["production", "production", "production", "staging"]   # weighted
FEATURES = ["search-assist", "billing-help", "onboarding", "troubleshooting"]
TIERS = ["free", "pro", "enterprise"]

SYSTEM_PROMPT = "You are a helpful support assistant."

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
    # `base_url` replaces the deprecated `host=` argument in SDK v4.
    Langfuse(
        base_url=os.environ.get("LANGFUSE_HOST", "http://localhost:3000"),
        public_key=os.environ["LANGFUSE_PUBLIC_KEY"],
        secret_key=os.environ["LANGFUSE_SECRET_KEY"],
    )
    lf = get_client()

    if not lf.auth_check():
        print("✗ Auth check failed — verify LANGFUSE_HOST / keys in _base/.env and that the stack is up.")
        sys.exit(1)
    mode = f"REAL Anthropic calls ({ANTHROPIC_MODEL})" if USE_ANTHROPIC else "offline / simulated"
    print(f"✓ Connected. Generating {N_TRACES} traces ({mode})…")

    claude = start_claude() if USE_ANTHROPIC else None

    users = [f"user_{i:03d}" for i in range(1, 13)]

    for t in range(N_TRACES):
        q_idx = rng.randrange(len(QUESTIONS))
        question = QUESTIONS[q_idx]
        model, ptok_r, ctok_r, lat_r = rng.choice(MODELS)
        env = rng.choice(ENVIRONMENTS)
        feature = rng.choice(FEATURES)
        tier = rng.choice(TIERS)
        user_id = rng.choice(users)
        session_id = f"sess_{user_id}_{t // 5}"   # ~5 turns per session
        # ~8% of traces hit an error in the generation step
        will_error = rng.random() < 0.08

        # The root observation IS the trace in v4, so its input/output go on it directly.
        with lf.start_as_current_observation(as_type="span", name="support-request",
                                             input={"question": question}) as root:
            # Trace-level attributes: searchable/filterable in the UI and in ClickHouse.
            # SDK v4 replaces update_current_trace() with propagate_attributes(): every
            # observation created inside the block carries these attributes as columns
            # (trace_name, user_id, session_id, tags, metadata_*), so analytics need no
            # join back to a trace row. metadata is dict[str, str], values <= 200 chars.
            with propagate_attributes(
                trace_name="support-request",
                user_id=user_id,
                session_id=session_id,
                tags=[f"env:{env}", f"feature:{feature}", f"tier:{tier}"],
                metadata={"channel": "web", "tier": tier, "environment": env},
            ):
                trace_id = lf.get_current_trace_id()

                # 1) Retrieval step (a non-LLM span)
                with lf.start_as_current_observation(as_type="span", name="retrieve-context") as ret:
                    time.sleep(rng.uniform(0.02, 0.12))
                    n_docs = rng.randint(2, 6)
                    ret.update(
                        input={"query": question, "top_k": n_docs},
                        output={"doc_ids": [f"kb-{rng.randint(100, 999)}" for _ in range(n_docs)]},
                        metadata={"retriever": "vector", "index": "support-kb"},
                    )

                # 2) Answer generation (the LLM call)
                ptok = rng.randint(*ptok_r)
                ctok = rng.randint(*ctok_r)
                messages = [
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": question},
                ]
                if USE_ANTHROPIC:
                    # Real call: the instrumented Anthropic client emits the GENERATION
                    # (model, tokens, cost) itself, so this wrapper is a plain span — a
                    # second generation carrying made-up tokens would double-count cost.
                    gen_cm = lf.start_as_current_observation(
                        as_type="span", name="answer-generation", input=messages)
                else:
                    gen_cm = lf.start_as_current_observation(
                        as_type="generation", name="answer-generation", model=model, input=messages)
                with gen_cm as gen:
                    if will_error:
                        time.sleep(rng.uniform(*lat_r))
                        gen.update(level="ERROR", status_message="upstream model timeout",
                                   metadata={"retryable": True})
                        answer = None
                    elif USE_ANTHROPIC:
                        answer = real_claude_answer(claude, question)
                        gen.update(output=answer)
                    else:
                        time.sleep(rng.uniform(*lat_r))
                        answer = simulated_answer(q_idx)
                        gen.update(
                            output=answer,
                            usage_details={"input": ptok, "output": ctok},
                            metadata={"temperature": 0.2},
                        )

                # 3) Occasional cheap guardrail / self-check generation
                if not will_error and rng.random() < 0.4:
                    with lf.start_as_current_observation(
                        as_type="generation", name="self-check", model="gpt-4o-mini",
                        input={"answer": answer},
                    ) as chk:
                        time.sleep(rng.uniform(0.05, 0.2))
                        gptok = rng.randint(80, 300)
                        chk.update(output={"grounded": True},
                                   usage_details={"input": gptok, "output": 5})

            root.update(output={"answer": answer, "errored": will_error})

        # ── Scores (stored alongside the events in ClickHouse `scores` table) ──
        if not will_error:
            # Explicit user feedback — boolean thumbs up/down (mostly up)
            lf.create_score(name="user-thumbs", trace_id=trace_id,
                            value=1 if rng.random() < 0.82 else 0,
                            data_type="BOOLEAN",
                            comment="thumbs up" if rng.random() < 0.82 else "thumbs down")
            # Automated hallucination check — numeric 0..1 (higher = more grounded)
            lf.create_score(name="hallucination-check", trace_id=trace_id,
                            value=round(rng.uniform(0.6, 1.0), 2), data_type="NUMERIC")
        else:
            lf.create_score(name="user-thumbs", trace_id=trace_id, value=0,
                            data_type="BOOLEAN", comment="error response")

        if (t + 1) % 10 == 0:
            print(f"  …{t + 1}/{N_TRACES} traces")

    # CRITICAL in short-lived scripts: flush the async buffer before exit.
    lf.flush()
    print(f"✓ Done. Open {os.environ.get('LANGFUSE_HOST', 'http://localhost:3000')} → Tracing → Observations.")
    print("  Then run the ClickHouse labs:  03-clickhouse-explore.sql, 04-clickhouse-analytics.sql")


def start_claude():
    """Return an Anthropic client whose calls are traced into Langfuse.

    Approach 1 of https://langfuse.com/integrations/model-providers/anthropic: the
    official `anthropic` SDK, traced by opentelemetry-instrumentation-anthropic.
    Order matters — the Langfuse client is already initialised (main() did that) and
    the instrumentor must run before the Anthropic client is used. Langfuse v4's
    default span filter exports spans that carry `gen_ai.*` attributes, which is what
    this instrumentation emits, so no `should_export_span` is needed. Measured on
    Langfuse 4.48.0 / SDK 4.16.0: the call lands in events_full as a GENERATION named
    `anthropic.chat` with the dated model id, token usage and a non-zero total_cost.
    """
    try:
        import anthropic
        from opentelemetry.instrumentation.anthropic import AnthropicInstrumentor
    except ImportError as exc:
        sys.exit(f"✗ ANTHROPIC_API_KEY is set but {exc.name} is not installed — "
                 "run: .venv-v4/bin/pip install -r _base/v4/requirements.txt")
    AnthropicInstrumentor().instrument()
    # Reads ANTHROPIC_API_KEY. The SDK's default read timeout is 600 s, so a stalled
    # connection would freeze the script for ten minutes; time out at 60 s instead
    # (the SDK retries a timed-out request twice before raising).
    return anthropic.Anthropic(timeout=60.0)


def real_claude_answer(client, question: str) -> str:
    """One real Anthropic call (claude-haiku-4-5). Exits with a clear message on API errors."""
    import anthropic

    try:
        resp = client.messages.create(
            model=ANTHROPIC_MODEL,
            max_tokens=1024,
            system=SYSTEM_PROMPT + " Answer in one sentence.",
            messages=[{"role": "user", "content": question}],
        )
    except anthropic.AuthenticationError:
        sys.exit("✗ Anthropic rejected ANTHROPIC_API_KEY (HTTP 401) — fix the key in _base/.env, "
                 "or blank it to run offline.")
    except anthropic.APIStatusError as exc:
        sys.exit(f"✗ Anthropic API returned HTTP {exc.status_code}: {exc.message}")
    except anthropic.APIConnectionError as exc:
        sys.exit(f"✗ Could not reach the Anthropic API: {exc}")
    if resp.stop_reason == "refusal":
        category = resp.stop_details.category if resp.stop_details else None
        return f"[model refused to answer: {category or 'no category'}]"
    return "".join(b.text for b in resp.content if b.type == "text")


if __name__ == "__main__":
    main()
