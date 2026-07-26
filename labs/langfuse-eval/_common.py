"""_common.py — shared helpers for the langfuse-eval lab.

Keeps the numbered scripts (02–06) focused on ONE Langfuse feature each by
centralizing the boring parts: loading .env, building a Langfuse client, a tiny
REST helper for endpoints without an SDK method (annotation queues / score
configs), and the canonical support Q&A used by the dataset + experiments.

No third-party deps beyond `langfuse` (+ optional `openai`). Everything runs
FULLY OFFLINE unless OPENAI_API_KEY is set.
"""
from __future__ import annotations  # PEP 563 — keep `X | None` hints working on 3.9

import base64
import json
import os
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))


# ── .env loading (same file docker-compose / the sibling lab read) ────────────
def load_env(path: str | None = None) -> None:
    path = path or os.path.join(HERE, ".env")
    if not os.path.exists(path):
        return
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            val = val.split(" #", 1)[0].strip().strip('"').strip("'")
            os.environ.setdefault(key, val)


# ── Langfuse client (v3, OpenTelemetry-native) ────────────────────────────────
def client():
    """Init + return the singleton Langfuse client. Exits if auth fails."""
    load_env()
    from langfuse import Langfuse, get_client

    Langfuse(
        host=os.environ.get("LANGFUSE_HOST", "http://localhost:3000"),
        public_key=os.environ["LANGFUSE_PUBLIC_KEY"],
        secret_key=os.environ["LANGFUSE_SECRET_KEY"],
    )
    lf = get_client()
    if not lf.auth_check():
        raise SystemExit(
            "✗ Auth check failed — is the Langfuse stack up (sibling lab "
            "`../langfuse-ee/01-up.sh`) and are LANGFUSE_* keys set in .env?"
        )
    return lf


# ── Minimal Public-API REST helper (Basic auth = public:secret) ───────────────
# Used for endpoints the Python SDK does not wrap directly: score configs and
# annotation queues (lab 06).
def api(method: str, path: str, body: dict | None = None) -> dict:
    load_env()
    host = os.environ.get("LANGFUSE_HOST", "http://localhost:3000").rstrip("/")
    token = base64.b64encode(
        f"{os.environ['LANGFUSE_PUBLIC_KEY']}:{os.environ['LANGFUSE_SECRET_KEY']}".encode()
    ).decode()
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        host + path,
        data=data,
        method=method,
        headers={"Authorization": f"Basic {token}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        raise SystemExit(f"✗ {method} {path} → HTTP {e.code}: {detail}") from e


# ── Canonical support knowledge base (shared by 03 dataset + 04 experiments) ──
# (question, grounded expected answer). Kept small so a run is fast & readable.
SUPPORT_QA = [
    ("How do I reset my password?",
     "Reset your password from Settings then Security then Reset password."),
    ("Why was my invoice higher this month?",
     "Your invoice rose because usage exceeded the included quota; see the Billing page."),
    ("Can I export my data to S3?",
     "Yes, configure a Blob Storage Export under Project Settings then Exports."),
    ("How do I add a teammate to my project?",
     "Open Organization Settings then Members and invite them by email with a role."),
    ("Does the API support pagination?",
     "Yes, list endpoints accept limit and page query parameters."),
    ("How do I rotate my API keys?",
     "Create new keys in Project Settings then API Keys, then revoke the old ones."),
    ("What regions are available for hosting?",
     "We host in US and EU regions; choose the region at project creation."),
    ("How do I set a data retention policy?",
     "Owners or Admins set it in Project Settings then Data Retention, minimum 3 days."),
    ("Can I use SSO with Okta?",
     "Yes, Okta is supported via OIDC or SAML on self-hosted Enterprise."),
    ("The dashboard is loading slowly, what can I do?",
     "Narrow the date range; large time windows scan more data and load slower."),
]


# ── Answer generation used by experiments (04) and the LLM judge (05) ─────────
def generate_answer(*, system_prompt: str, question: str, expected: str,
                    variant: str, model: str = "gpt-4o-mini") -> str:
    """Produce an assistant answer.

    - With OPENAI_API_KEY set: a real call via Langfuse's drop-in OpenAI wrapper
      (auto-traced), honoring the system prompt fetched from Prompt Management.
    - Offline (default): deterministic simulation whose quality depends on the
      prompt VARIANT, so the v2 (guard-railed) prompt visibly outscores v1. This
      makes the experiment comparison meaningful without any API key.
    """
    if os.environ.get("OPENAI_API_KEY"):
        from langfuse.openai import openai  # drop-in, auto-creates the generation

        oai_model = model if str(model).startswith("gpt") else "gpt-4o-mini"
        resp = openai.chat.completions.create(
            model=oai_model,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": question},
            ],
        )
        return resp.choices[0].message.content

    # Offline simulation: v2 answers from the grounded KB; v1 is generic/deflecting.
    if variant in ("v2", "latest", "production"):
        return expected
    return "Thanks for reaching out — please check our documentation or contact support."
