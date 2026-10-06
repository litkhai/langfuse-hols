#!/usr/bin/env python3
"""
02-generate-traces.py — push realistic LLM traces into self-hosted Langfuse.

The generator moved to ../../../_base/v4/seed_traces.py so every lab can share it
(langfuse-eval seeds its traces with the same script). This wrapper keeps the
lab-02 command line working: same argv, same exit code.

Usage (Python 3.10+):
    pip install -r ../../../_base/v4/requirements.txt
    python 02-generate-traces.py            # 40 traces
    python 02-generate-traces.py 200        # 200 traces

Runs FULLY OFFLINE by default (no LLM API needed). Set ANTHROPIC_API_KEY in
_base/.env to make real Anthropic calls (claude-haiku-4-5) instead.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = os.path.normpath(os.path.join(HERE, "..", "..", "..", "_base", "v4", "seed_traces.py"))

if __name__ == "__main__":
    sys.exit(subprocess.call([sys.executable, TARGET, *sys.argv[1:]]))
