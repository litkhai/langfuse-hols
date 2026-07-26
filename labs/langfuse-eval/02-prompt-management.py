#!/usr/bin/env python3
"""02-prompt-management.py — version, label, compile, and LINK prompts.

Langfuse Prompt Management lets you store prompts OUTSIDE your code, version them,
and control deployment with LABELS (e.g. `production`, `latest`) — so a PM can
ship a new prompt with zero code deploy, and you can roll back by moving a label.

This script:
  1. Creates a TEXT prompt `support-system` v1 (labelled `production`) with config.
  2. Creates v2 (guard-railed) — creating it with the `production` label MOVES the
     label to v2, i.e. an instant deploy. v1 stays available by version number.
  3. Creates a CHAT prompt to show the other prompt type.
  4. Fetches by label / by version and compiles with a variable.
  5. Links a prompt to a generation observation (`prompt=` param) so the UI can
     attribute that generation's cost/latency/quality to this prompt version.

Prompts live in Postgres (OLTP) — you will NOT find them in ClickHouse.
Docs: https://langfuse.com/docs/prompt-management/get-started
"""
import os

from _common import client

PROMPT_NAME = os.environ.get("PROMPT_NAME", "support-system")
CONFIG = {"model": "gpt-4o-mini", "temperature": 0.2}


def main() -> None:
    lf = client()

    # 1) v1 — terse. Labelled `production`.
    lf.create_prompt(
        name=PROMPT_NAME,
        type="text",
        prompt="You are a {{tone}} customer-support assistant. "
               "Answer the user's question in one short sentence.",
        labels=["production"],
        config=CONFIG,
    )
    print(f"✓ created {PROMPT_NAME} v1  (label: production)")

    # 2) v2 — guard-railed. Creating with label `production` MOVES it here (deploy);
    #    `latest` always points at the newest version.
    lf.create_prompt(
        name=PROMPT_NAME,
        type="text",
        prompt="You are a {{tone}} customer-support assistant. Answer in one short "
               "sentence using only verified product facts. If you are unsure, say "
               "you will escalate to a human — never invent policy.",
        labels=["production", "latest"],
        config=CONFIG,
    )
    print(f"✓ created {PROMPT_NAME} v2  (labels: production, latest) — production now → v2")

    # 3) A CHAT prompt (system + user roles) to show the other type.
    lf.create_prompt(
        name=f"{PROMPT_NAME}-chat",
        type="chat",
        prompt=[
            {"role": "system", "content": "You are a {{tone}} customer-support assistant."},
            {"role": "user", "content": "{{question}}"},
        ],
        labels=["production"],
        config=CONFIG,
    )
    print(f"✓ created {PROMPT_NAME}-chat  (type: chat)")

    # 4) Fetch + compile. Default label is `production`.
    prod = lf.get_prompt(PROMPT_NAME)                       # → v2 (production)
    v1 = lf.get_prompt(PROMPT_NAME, version=1)              # → v1 by version
    print("\n— production (v2) compiled —")
    print("  ", prod.compile(tone="friendly"))
    print("— version 1 compiled —")
    print("  ", v1.compile(tone="friendly"))
    assert "escalate" in prod.compile(tone="friendly"), "expected v2 to be production"

    # 5) Link a prompt to a generation so the UI attributes performance to it.
    with lf.start_as_current_observation(
        as_type="generation",
        name="prompt-link-demo",
        model=CONFIG["model"],
        prompt=prod,                                        # ← the link
        input=[{"role": "system", "content": prod.compile(tone="friendly")},
               {"role": "user", "content": "How do I rotate my API keys?"}],
    ) as gen:
        gen.update(
            output="Create new keys in Project Settings then API Keys, then revoke the old ones.",
            usage_details={"input_tokens": 42, "output_tokens": 18, "total_tokens": 60},
        )
    lf.flush()

    print("\n✓ Prompt management demo complete.")
    print("  UI → Prompts: see versions, labels, and the diff between v1 and v2.")
    print("  UI → Prompts →", PROMPT_NAME, "→ Metrics: the linked generation above.")


if __name__ == "__main__":
    main()
