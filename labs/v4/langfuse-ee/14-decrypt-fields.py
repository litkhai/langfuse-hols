#!/usr/bin/env python3
"""14-decrypt-fields.py — the reader side of lab 14: fetch traces over the public API with the project's
API key and decrypt the `enc:v1:` fields with the project's AES key.

    14-decrypt-fields.py <project_id> <run_ts> <trace_id> [<trace_id> ...]

From the environment: FE_PUBLIC_KEY / FE_SECRET_KEY (that project's API keys), LANGFUSE_HOST.
AES key: _base/.env.field-keys (FIELD_KEY_<project_id>=<base64url>). Exits 1 unless every check is PASS.
Reads /api/public/v2/observations (v1 traces/observations endpoints are 404 in v4 events_only mode).
Checks per observation: (1) the API returns ciphertext, not plaintext; (2) decrypting with the project's key gives the
expected plaintext; (3) decrypting with ANOTHER project's key fails (GCM InvalidTag); (4) the output is plaintext.
"""
import base64
import json
import os
import sys
import urllib.request

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

KEY_FILE = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "_base", ".env.field-keys"))
HOST = os.environ.get("LANGFUSE_HOST", "http://localhost:3000")


def load_keys() -> dict[str, bytes]:
    keys = {}
    with open(KEY_FILE) as fh:
        for line in fh:
            name, _, val = line.strip().partition("=")
            if name.startswith("FIELD_KEY_"):
                keys[name[len("FIELD_KEY_"):]] = base64.urlsafe_b64decode(val)
    return keys


def decrypt(value: str, key: bytes) -> str:
    _, _, pid, blob = value.split(":", 3)
    raw = base64.urlsafe_b64decode(blob)
    return AESGCM(key).decrypt(raw[:12], raw[12:], pid.encode()).decode()


def try_decrypt(value, key: bytes):
    """Plaintext on success, None if the value is not a valid enc:v1 value for this key (never raises)."""
    try:
        return decrypt(value, key)
    except Exception:
        return None


def api_get(path: str):
    pk, sk = os.environ["FE_PUBLIC_KEY"], os.environ["FE_SECRET_KEY"]
    req = urllib.request.Request(HOST + path)
    req.add_header("Authorization", "Basic " + base64.b64encode(f"{pk}:{sk}".encode()).decode())
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


fails = 0


def check(name: str, ok: bool, observed: str):
    global fails
    fails += 0 if ok else 1
    print(f"{'PASS' if ok else 'FAIL'}  {name}: {observed}")


def main():
    project_id, ts = sys.argv[1], int(sys.argv[2])
    trace_ids = sys.argv[3:]
    keys = load_keys()
    mine = keys[project_id]
    other = next(k for p, k in keys.items() if p != project_id)    # any other project's key
    want_in = f"Transfer status for ENCMARK-IN-{ts}"
    want_acct = f"110-23-{ts % 1_000_000:06d}"
    want_out = f"Your transfer ENCMARK-OUT-{ts} is complete"

    for tid in trace_ids:
        # Langfuse v4 (events_only): /api/public/traces and /observations return 404; v2/observations serves the events table.
        obs = api_get(f"/api/public/v2/observations?traceId={tid}&fields=core,basic,io,metadata&limit=50")["data"]
        print(f"── trace {tid}: {len(obs)} observations")
        for o in obs:
            label = f"{'root' if o.get('parentObservationId') is None else 'child'} observation {o.get('name')}"
            inp = o.get("input")
            acct = (o.get("metadata") or {}).get("account_no")
            out = o.get("output")
            # What the API (and so the UI) returns, truncated: ciphertext.
            print(f"   {label}: input = {str(inp)[:50]}…  account_no = {str(acct)[:40]}…")
            s = inp if isinstance(inp, str) else json.dumps(inp)
            check(f"{label} input is ciphertext", s.startswith("enc:v1:") and want_in not in s, s[:40] + "…")
            check(f"{label} input decrypts to the expected plaintext", try_decrypt(s, mine) == want_in,
                  "decrypted value equals expected")
            try:
                decrypt(s, other)
                check(f"{label} input with another project's key fails", False, "decrypted (unexpected)")
            except InvalidTag:
                check(f"{label} input with another project's key fails", True, "InvalidTag")
            except Exception as exc:                         # not an enc:v1 value at all
                check(f"{label} input with another project's key fails", False, f"not decryptable: {type(exc).__name__}")
            check(f"{label} metadata.account_no is ciphertext",
                  isinstance(acct, str) and acct.startswith("enc:v1:") and want_acct not in acct, str(acct)[:40] + "…")
            check(f"{label} metadata.account_no decrypts to the expected plaintext", try_decrypt(acct, mine) == want_acct,
                  "decrypted value equals expected")
            check(f"{label} output is plaintext (search control)", want_out == out, str(out))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
