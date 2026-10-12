#!/usr/bin/env python3
"""12-send-marker.py — send ONE OTLP trace (Python SDK) whose input holds a fabricated secret and a
fabricated account number, for the masking failure-mode scenarios of lab 12.

    12-send-marker.py <secret> <account_no>

From the environment (set by 12-ee-masking-failure-modes.sh, never printed):
    FM_PUBLIC_KEY / FM_SECRET_KEY   the project's API keys
    LANGFUSE_HOST                   default http://localhost:3000
Prints one line `TRACE_ID <id>`. Python 3.10+, the langfuse SDK (see _base/v4/requirements.txt).
"""
import os
import sys

from langfuse import Langfuse

secret, account = sys.argv[1], sys.argv[2]
lf = Langfuse(
    base_url=os.environ.get("LANGFUSE_HOST", "http://localhost:3000"),
    public_key=os.environ["FM_PUBLIC_KEY"],
    secret_key=os.environ["FM_SECRET_KEY"],
)
if not lf.auth_check():
    raise SystemExit("auth check failed")
text = f"Use key {secret} to settle account {account}"
with lf.start_as_current_observation(as_type="span", name="masking-mode", input=text) as root:
    trace_id = lf.get_current_trace_id()
    root.update(output="done")
print(f"TRACE_ID {trace_id}")
lf.flush()
lf.shutdown()
