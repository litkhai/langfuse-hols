#!/usr/bin/env python3
"""08-generate-pii-traces.py — send traces that CONTAIN secrets / PII into Langfuse
so we can prove server-side data masking works (lab 08).

Each trace deliberately embeds four sentinel secrets in the model input/output
and in trace metadata. With the masking sidecar active (docker-compose.masking.yml),
Langfuse's worker redacts them on ingestion BEFORE writing to ClickHouse — so the
raw sentinels must NOT appear in the traces / observations tables.

08-verify-masking.sql then greps ClickHouse for these exact sentinels (expect 0)
and for the [REDACTED_*] placeholders the sidecar leaves behind (expect > 0).

The SDK v3 is OpenTelemetry-native and ships to /api/public/otel — the only
ingestion path server-side masking applies to.

Usage:
    pip install "langfuse>=3"
    python 08-generate-pii-traces.py            # 12 traces
    python 08-generate-pii-traces.py 40         # 40 traces
"""
import os
import sys
import time
import random

# ── Sentinel secrets. 08-verify-masking.sql looks for these EXACT substrings. ──
SECRET_API_KEY = "sk-workshop-LEAKED-0xDEADBEEF01"   # looks like an API key
SECRET_CARD    = "4111 1111 1111 1111"               # test Visa card number
SECRET_EMAIL   = "victim@secret-corp.test"           # PII e-mail
SECRET_RRN     = "900101-1234567"                    # fake KR 주민등록번호


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

N_TRACES = int(sys.argv[1]) if len(sys.argv) > 1 else 12
random.seed(7)

# Realistic-looking support turns where a user pastes sensitive data.
QUESTIONS = [
    f"My card {SECRET_CARD} was charged twice, please refund.",
    f"Reset my login for {SECRET_EMAIL}.",
    f"Verify my identity, my resident number is {SECRET_RRN}.",
    f"Our integration uses api key {SECRET_API_KEY}; is it still valid?",
]
ANSWERS = [
    f"I've opened a refund for the card ending in the number you sent ({SECRET_CARD}).",
    f"A reset link was sent to {SECRET_EMAIL}.",
    f"Thanks, I confirmed the resident number {SECRET_RRN} on file.",
    f"The key {SECRET_API_KEY} is active; rotate it if it was shared.",
]


def main():
    Langfuse(
        host=os.environ.get("LANGFUSE_HOST", "http://localhost:3000"),
        public_key=os.environ["LANGFUSE_PUBLIC_KEY"],
        secret_key=os.environ["LANGFUSE_SECRET_KEY"],
    )
    lf = get_client()

    if not lf.auth_check():
        print("✗ Auth check failed — verify LANGFUSE_HOST / keys in .env and that the stack is up.")
        sys.exit(1)
    print(f"✓ Connected. Sending {N_TRACES} PII-laden traces to the OTLP endpoint…")

    for t in range(N_TRACES):
        idx = t % len(QUESTIONS)
        question, answer = QUESTIONS[idx], ANSWERS[idx]

        with lf.start_as_current_observation(as_type="span", name="support-request") as root:
            lf.update_current_trace(
                name="support-request",
                user_id=f"user_{t % 5:02d}",
                session_id=f"pii_sess_{t // 4}",
                input={"question": question},
                tags=["pii-demo"],
                # Secrets pasted into metadata too — masking must reach here as well.
                metadata={"raw_email": SECRET_EMAIL, "raw_rrn": SECRET_RRN, "channel": "web"},
            )
            trace_id = lf.get_current_trace_id()

            with lf.start_as_current_observation(
                as_type="generation", name="answer-generation", model="gpt-4o-mini",
                input=[
                    {"role": "system", "content": "You are a support assistant. Never echo secrets."},
                    {"role": "user", "content": question},
                ],
            ) as gen:
                time.sleep(random.uniform(0.05, 0.2))
                gen.update(
                    output=answer,
                    usage_details={"input_tokens": 120, "output_tokens": 40, "total_tokens": 160},
                    metadata={"leaked_key": SECRET_API_KEY},
                )
            root.update(output={"answer": answer})

        lf.create_score(name="pii-demo", trace_id=trace_id, value=1, data_type="BOOLEAN")

    # CRITICAL: flush the async buffer before the script exits.
    lf.flush()
    print("✓ Sent. Give the worker a few seconds to ingest + mask, then run:")
    print("    docker compose exec -T clickhouse clickhouse-client -u clickhouse \\")
    print("      --password clickhouse --multiquery < 08-verify-masking.sql")


if __name__ == "__main__":
    main()
