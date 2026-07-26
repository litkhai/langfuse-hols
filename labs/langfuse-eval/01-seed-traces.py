#!/usr/bin/env python3
"""01-seed-traces.py — put some traces in Langfuse to evaluate.

This lab is about EVALUATING LLM output, so we first need some output to look at.
Rather than duplicate the trace generator, we reuse the sibling lab's proven one
(`../langfuse-ee/02-generate-traces.py`) — both labs talk to the SAME running
stack with the SAME keys.

    python 01-seed-traces.py            # 40 traces (default)
    python 01-seed-traces.py 100        # 100 traces

If you already ran the sibling lab's generator, you can skip this step.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SIBLING = os.path.normpath(os.path.join(HERE, "..", "langfuse-ee", "02-generate-traces.py"))


def main() -> None:
    n = sys.argv[1] if len(sys.argv) > 1 else "40"
    if not os.path.exists(SIBLING):
        sys.exit(
            f"✗ Sibling generator not found: {SIBLING}\n"
            "  This lab reuses the langfuse-ee trace generator — keep both labs "
            "under usecase/, or copy that script here."
        )
    print(f"→ Reusing sibling trace generator to seed {n} traces:\n  {SIBLING}\n")
    # The sibling loads its OWN .env (same LANGFUSE_* creds as ours) and flushes.
    raise SystemExit(subprocess.call([sys.executable, SIBLING, str(n)]))


if __name__ == "__main__":
    main()
