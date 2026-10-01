"""_common.py — shared helpers for the langfuse-eval lab.

Keeps the numbered scripts (02–06) focused on ONE Langfuse feature each by
centralizing the boring parts: loading .env, building a Langfuse client, a tiny
REST helper for endpoints without an SDK method (annotation queues / score
configs), the canonical support Q&A used by the dataset + experiments, and the
optional real-model call.

Third-party deps: `langfuse` (4.x, Python 3.10+). `anthropic` and
`opentelemetry-instrumentation-anthropic` are imported only when ANTHROPIC_API_KEY
is set (see _base/requirements.txt). Everything runs FULLY OFFLINE unless it is.
"""
import base64
import json
import os
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))


# ── .env loading (_base/.env: the one file docker-compose and every lab read) ─
BASE_ENV = os.path.normpath(os.path.join(HERE, "..", "..", "_base", ".env"))


def load_env(path: str | None = None) -> None:
    path = path or BASE_ENV
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


# ── Langfuse client (v4, OpenTelemetry-native) ────────────────────────────────
def client():
    """Init + return the singleton Langfuse client. Exits if auth fails."""
    load_env()
    from langfuse import Langfuse, get_client

    # `base_url` replaces the deprecated `host=` argument in SDK v4.
    Langfuse(
        base_url=os.environ.get("LANGFUSE_HOST", "http://localhost:3000"),
        public_key=os.environ["LANGFUSE_PUBLIC_KEY"],
        secret_key=os.environ["LANGFUSE_SECRET_KEY"],
    )
    lf = get_client()
    if not lf.auth_check():
        raise SystemExit(
            "✗ Auth check failed — is the Langfuse stack up (`_base/bin/up.sh`, "
            "check with `_base/bin/check.sh`) and are LANGFUSE_* keys set in _base/.env?"
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


# ── Real model calls (optional): the official Anthropic SDK, traced by OTel ───
_claude = None   # the Anthropic client, created (and instrumented) on first use


def use_anthropic() -> bool:
    """True when ANTHROPIC_API_KEY is set → real calls; unset → offline simulation."""
    load_env()
    return bool(os.environ.get("ANTHROPIC_API_KEY"))


def ask_claude(*, system: str, user: str, model: str, max_tokens: int) -> str:
    """One real Anthropic call; returns the text. Exits with a clear message on API errors.

    Approach 1 of https://langfuse.com/integrations/model-providers/anthropic: the
    official `anthropic` SDK, traced by opentelemetry-instrumentation-anthropic. The
    Langfuse client is initialised by `client()` before the first call, and the
    instrumentor runs before the Anthropic client is first used (right here). Langfuse
    v4's default span filter exports spans carrying `gen_ai.*` attributes, which is what
    the instrumentation emits, so no `should_export_span` is needed. Measured on Langfuse
    4.48.0 / SDK 4.16.0: the call lands in events_full as a GENERATION named
    `anthropic.chat` with the dated model id, token usage and a non-zero total_cost.
    """
    global _claude
    try:
        import anthropic
        if _claude is None:
            from opentelemetry.instrumentation.anthropic import AnthropicInstrumentor

            AnthropicInstrumentor().instrument()
            # Reads ANTHROPIC_API_KEY. The SDK's default read timeout is 600 s, so a stalled
            # connection would freeze the lab for ten minutes; time out at 60 s instead
            # (the SDK retries a timed-out request twice before raising).
            _claude = anthropic.Anthropic(timeout=60.0)
    except ImportError as exc:
        raise SystemExit(
            f"✗ ANTHROPIC_API_KEY is set but {exc.name} is not installed — "
            "run: .venv/bin/pip install -r _base/requirements.txt"
        ) from exc

    try:
        resp = _claude.messages.create(
            model=model,
            max_tokens=max_tokens,
            system=system,
            messages=[{"role": "user", "content": user}],
        )
    except anthropic.AuthenticationError as exc:
        raise SystemExit("✗ Anthropic rejected ANTHROPIC_API_KEY (HTTP 401) — fix the key "
                         "in _base/.env, or blank it to run offline.") from exc
    except anthropic.APIStatusError as exc:
        raise SystemExit(f"✗ Anthropic API returned HTTP {exc.status_code}: {exc.message}") from exc
    except anthropic.APIConnectionError as exc:
        raise SystemExit(f"✗ Could not reach the Anthropic API: {exc}") from exc
    if resp.stop_reason == "refusal":
        category = resp.stop_details.category if resp.stop_details else None
        print(f"  ! model refused ({category or 'no category'})", file=sys.stderr)
        return ""
    return "".join(b.text for b in resp.content if b.type == "text")


# ── Answer generation used by experiments (04) and the LLM judge (05) ─────────
def generate_answer(*, system_prompt: str, question: str, expected: str,
                    variant: str, model: str = "claude-haiku-4-5") -> str:
    """Produce an assistant answer.

    - With ANTHROPIC_API_KEY set: a real Claude call (auto-traced as a GENERATION),
      honoring the system prompt fetched from Prompt Management.
    - Offline (default): deterministic simulation whose quality depends on the
      prompt VARIANT, so the v2 (guard-railed) prompt visibly outscores v1. This
      makes the experiment comparison meaningful without any API key.
    """
    if use_anthropic():
        return ask_claude(system=system_prompt, user=question, model=model, max_tokens=1024)

    # Offline simulation: v2 answers from the grounded KB; v1 is generic/deflecting.
    if variant in ("v2", "latest", "production"):
        return expected
    return "Thanks for reaching out — please check our documentation or contact support."
