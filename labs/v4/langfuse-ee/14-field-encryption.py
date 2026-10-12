#!/usr/bin/env python3
"""14-field-encryption.py — client-side field encryption in the SDK's `mask_otel_spans` hook (lab 14).

Sends traces whose INPUT and metadata field `account_no` are AES-256-GCM encrypted before they leave
the process; the OUTPUT is left in plaintext on purpose (the search control). Langfuse, ClickHouse and
the UI only ever see  enc:v1:<project_id>:<base64url(nonce||ciphertext)>.

    14-field-encryption.py hook    <project_id> <run_ts> [N_TRACES]   # hook on (default 2 traces)
    14-field-encryption.py control <project_id> <run_ts>              # hook off, markers + "-CTRL"

From the environment (set by 14-field-encryption.sh, never printed):
    FE_PUBLIC_KEY / FE_SECRET_KEY   the project's API keys
    LANGFUSE_HOST                   default http://localhost:3000
The per-project AES key is read from _base/.env.field-keys  (FIELD_KEY_<project_id>=<base64url>).
Prints one line `TRACE_ID <id>` per trace sent. Python 3.10+, `cryptography` (see _base/v4/requirements.txt).
"""
import base64
import json
import os
import secrets
import sys
import warnings

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from langfuse import Langfuse, propagate_attributes
from langfuse.types import MaskOtelSpansParams, MaskOtelSpansResult, OtelSpanPatch

KEY_FILE = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "_base", ".env.field-keys"))

# Attributes the SDK uses for trace / observation input (langfuse/_client/attributes.py, SDK 4.17.0).
INPUT_KEYS = {"langfuse.trace.input", "langfuse.observation.input"}
# Metadata is exported flattened: langfuse.{trace,observation}.metadata.<key>
ENCRYPTED_METADATA_SUFFIX = ".metadata.account_no"


def load_field_key(project_id: str) -> bytes:
    with open(KEY_FILE) as fh:
        for line in fh:
            name, _, val = line.strip().partition("=")
            if name == f"FIELD_KEY_{project_id}":
                return base64.urlsafe_b64decode(val)
    raise SystemExit(f"no AES key for project {project_id} in _base/.env.field-keys")


def b64u(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode()


def make_mask(project_id: str, key: bytes):
    aes = AESGCM(key)
    seen_keys: set[str] = set()

    def encrypt(plaintext: str) -> str:
        nonce = secrets.token_bytes(12)                      # fresh 12-byte nonce per value
        ct = aes.encrypt(nonce, plaintext.encode(), project_id.encode())   # AAD = project id
        return f"enc:v1:{project_id}:{b64u(nonce + ct)}"

    def mask_otel_spans(*, params: MaskOtelSpansParams):
        patches = {}
        for ident, span in params.spans.items():
            new_keys = set(span.attributes) - seen_keys
            if new_keys:                                     # log attribute KEYS once (never values)
                seen_keys.update(new_keys)
                print(f"  span '{span.name}' attribute keys: {sorted(span.attributes)}")
            sets = {k: encrypt(str(v)) for k, v in span.attributes.items()
                    if k in INPUT_KEYS or k.endswith(ENCRYPTED_METADATA_SUFFIX)}
            if sets:
                patches[ident] = OtelSpanPatch(set_attributes=sets)
        # An exception here would drop the whole export batch (fail closed: no plaintext is sent).
        return MaskOtelSpansResult(span_patches=patches)

    return mask_otel_spans


def main():
    mode, project_id, ts = sys.argv[1], sys.argv[2], int(sys.argv[3])
    n = int(sys.argv[4]) if len(sys.argv) > 4 else 2
    if mode not in ("hook", "control"):
        raise SystemExit(__doc__)
    sfx = "" if mode == "hook" else "-CTRL"
    if mode == "control":
        n = 1
    lf = Langfuse(
        base_url=os.environ.get("LANGFUSE_HOST", "http://localhost:3000"),
        public_key=os.environ["FE_PUBLIC_KEY"],
        secret_key=os.environ["FE_SECRET_KEY"],
        mask_otel_spans=make_mask(project_id, load_field_key(project_id)) if mode == "hook" else None,
    )
    if not lf.auth_check():
        raise SystemExit("auth check failed")
    warnings.simplefilter("ignore", DeprecationWarning)      # set_trace_io is deprecated, still the evaluator path

    for i in range(n):
        # Fixed, fabricated plaintexts with unique markers (see 14-decrypt-fields.py: same formulas).
        inp = f"Transfer status for ENCMARK-IN-{ts}{sfx}"
        acct = f"110-23-{ts % 1_000_000:06d}{sfx}"
        out = f"Your transfer ENCMARK-OUT-{ts}{sfx} is complete"
        with lf.start_as_current_observation(as_type="span", name="transfer-status", input=inp) as root:
            with propagate_attributes(trace_name="transfer-status", metadata={"account_no": acct}):
                trace_id = lf.get_current_trace_id()
                with lf.start_as_current_observation(as_type="generation", name="answer", model="demo-model",
                                                     input=inp, metadata={"account_no": acct}) as gen:
                    gen.update(output=out)
            root.update(output=out)
            root.set_trace_io(input=inp, output=out)
        print(f"TRACE_ID {trace_id}")
    lf.flush()
    lf.shutdown()


if __name__ == "__main__":
    main()
