"""Shared helpers for this lab's Python steps (stdlib + httpx, which the anthropic SDK brings).

- env(): the secrets file (LF_ENV_FILE, default _base/.env of this clone), parsed like compose does
- Session: a NextAuth login with a cookie jar, and tRPC calls the way the Langfuse UI makes them
- ch(): a ClickHouse query against this lab's ClickHouse (:18423), JSON rows
- psql(): one statement against this lab's Postgres
- state(): read and update .run/state.json (issued keys, run results; gitignored, mode 600)

Admin setup goes through tRPC because 4.75.0 has no public API for the gateway's control plane
(provider credentials, gateway keys, ingestion settings): those are UI-only procedures in
web/src/features/ai-gateway/server/router.ts.
"""

from __future__ import annotations

import json
import os
import stat
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import httpx

LAB_DIR = Path(__file__).resolve().parent
REPO = LAB_DIR.parents[2]
RUN_DIR = LAB_DIR / ".run"
STATE = RUN_DIR / "state.json"

WEB = "http://localhost:13000"
GATEWAY = "http://localhost:18480"
CLICKHOUSE = "http://localhost:18423"
LITELLM = "http://localhost:18440"
PROJECT = "lf-gateway-lab"
CONNECTION = "anthropic-lab"  # the credential name becomes the model-ID prefix: anthropic-lab:<model>
MODEL = "claude-haiku-4-5"  # cheapest current Anthropic model; the provider returns the dated ID


def env() -> dict[str, str]:
    path = Path(os.environ.get("LF_ENV_FILE", REPO / "_base" / ".env"))
    out: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        if " #" in val:
            val = val.split(" #", 1)[0]
        val = val.strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
            val = val[1:-1]
        out[key.strip()] = val
    return out


def state() -> dict:
    return json.loads(STATE.read_text()) if STATE.exists() else {}


def save_state(data: dict) -> None:
    RUN_DIR.mkdir(mode=0o700, exist_ok=True)
    STATE.write_text(json.dumps(data, indent=2, sort_keys=True))
    STATE.chmod(stat.S_IRUSR | stat.S_IWUSR)


def update_state(**kv) -> dict:
    data = state()
    data.update(kv)
    save_state(data)
    return data


class TrpcError(Exception):
    def __init__(self, status: int, body: dict):
        err = (body or {}).get("error", {}).get("json", {})
        self.status = status
        self.code = err.get("data", {}).get("code")
        self.message = err.get("message", "")
        super().__init__(f"HTTP {status} {self.code}: {self.message[:300]}")


def _superjson(value: dict) -> dict:
    """Dates become ISO strings plus superjson meta, as the UI's tRPC client sends them."""
    out, meta = {}, {}
    for key, val in value.items():
        if isinstance(val, datetime):
            out[key] = val.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
            meta[key] = ["Date"]
        else:
            out[key] = val
    body = {"json": out}
    if meta:
        body["meta"] = {"values": meta}
    return body


class Session:
    def __init__(self, email: str, password: str):
        self.email = email
        self.http = httpx.Client(base_url=WEB, timeout=90, follow_redirects=False)
        csrf = self.http.get("/api/auth/csrf").json()["csrfToken"]
        self.http.post(
            "/api/auth/callback/credentials",
            data={"csrfToken": csrf, "email": email, "password": password,
                  "callbackUrl": f"{WEB}/", "json": "true"},
        )
        me = self.http.get("/api/auth/session").json()
        if not me.get("user"):
            raise SystemExit(f"✗ login failed for {email}")
        self.user = me["user"]

    def query(self, proc: str, value: dict):
        r = self.http.get(f"/api/trpc/{proc}", params={"input": json.dumps(_superjson(value))})
        return self._result(r)

    def mutate(self, proc: str, value: dict):
        r = self.http.post(f"/api/trpc/{proc}", json=_superjson(value))
        return self._result(r)

    @staticmethod
    def _result(r: httpx.Response):
        try:
            body = r.json()
        except ValueError:
            body = {}
        if r.status_code != 200 or "error" in body:
            raise TrpcError(r.status_code, body)
        return body["result"]["data"]["json"]


def ch(sql: str) -> list[dict]:
    e = env()
    r = httpx.post(
        CLICKHOUSE, params={"default_format": "JSONEachRow"}, content=sql,
        auth=(e.get("CLICKHOUSE_USER", "clickhouse"), e.get("CLICKHOUSE_PASSWORD", "clickhouse")),
        timeout=60,
    )
    r.raise_for_status()
    return [json.loads(line) for line in r.text.splitlines() if line.strip()]


def psql(sql: str) -> str:
    """One statement against this lab's Postgres, unaligned output (docker exec; no host port)."""
    e = env()
    return subprocess.run(["docker", "exec", f"{PROJECT}-postgres-1", "psql", "-U", e.get("POSTGRES_USER", "postgres"),
                           "-d", e.get("POSTGRES_DB", "postgres"), "-At", "-c", sql],
                          capture_output=True, text=True, check=True).stdout.strip()


def litellm_admin(method: str, path: str, **kw) -> httpx.Response:
    """LiteLLM admin API with the master key from .run/ (07-litellm-up.sh made it)."""
    key = (RUN_DIR / "litellm-master-key").read_text().strip()
    return httpx.request(method, LITELLM + path, headers={"Authorization": f"Bearer {key}"}, timeout=60, **kw)


def now() -> datetime:
    return datetime.now(timezone.utc)
