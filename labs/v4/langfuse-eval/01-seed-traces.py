#!/usr/bin/env python3
"""01-seed-traces.py — put some traces in Langfuse to evaluate.

This lab is about EVALUATING LLM output, so we first need some output to look at.
Rather than duplicate the trace generator, we reuse the shared one
(`../../../_base/v4/seed_traces.py`) — every lab talks to the SAME running stack
(`_base/`) with the SAME keys.

    python 01-seed-traces.py            # 40 traces (default)
    python 01-seed-traces.py 100        # 100 traces

If you already seeded traces (e.g. via the langfuse-ee lab), you can skip this step.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SEEDER = os.path.normpath(os.path.join(HERE, "..", "..", "..", "_base", "v4", "seed_traces.py"))


def main() -> None:
    n = sys.argv[1] if len(sys.argv) > 1 else "40"
    if not os.path.exists(SEEDER):
        sys.exit(
            f"✗ Shared trace generator not found: {SEEDER}\n"
            "  It ships with the repository in _base/v4/ — check that your checkout is complete."
        )
    print(f"→ Seeding {n} traces with the shared trace generator:\n  {SEEDER}\n")
    # The generator loads _base/.env (same LANGFUSE_* creds as ours) and flushes.
    raise SystemExit(subprocess.call([sys.executable, SEEDER, str(n)]))


if __name__ == "__main__":
    main()
