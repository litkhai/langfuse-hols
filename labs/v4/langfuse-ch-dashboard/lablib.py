"""Shared helpers for this lab's Python steps (stdlib + httpx, which the langfuse SDK brings).

- env(): the secrets file (LF_ENV_FILE, default _base/.env of this clone), parsed like compose does
- api(): an authenticated call to the Langfuse public API (project keys of the init project)
- ch(): a query against the shared stack's ClickHouse over HTTP (:8123), JSON rows

Constants that every step shares sit here, so the seed, the panels and the checks agree:
the Langfuse environment and tag of this lab's traces and the lab's own ClickHouse database.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import httpx

LAB_DIR = Path(__file__).resolve().parent
REPO = LAB_DIR.parents[2]
SLUG = "langfuse-ch-dashboard"
ENVIRONMENT = "lab-ch-dashboard"       # langfuse.environment of every seeded observation
TAG = f"lab:{SLUG}"                    # langfuse.trace.tags of every seeded observation
LAB_DB = "lab_langfuse_ch_dashboard"   # this lab's own ClickHouse objects (scale copy, MV)


def env() -> dict[str, str]:
    path = Path(os.environ.get("LF_ENV_FILE") or REPO / "_base" / ".env")
    out: dict[str, str] = {}
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            v = v.split(" #", 1)[0].strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            out[k.strip()] = v
    out.update({k: v for k, v in os.environ.items() if k.startswith(("LANGFUSE_", "CLICKHOUSE_"))})
    return out


E = env()
HOST = E.get("LANGFUSE_HOST", "http://localhost:3000").rstrip("/")
PROJECT = E.get("LANGFUSE_INIT_PROJECT_ID", "llm-observability")
PK = E.get("LANGFUSE_PUBLIC_KEY") or E.get("LANGFUSE_INIT_PROJECT_PUBLIC_KEY", "")
SK = E.get("LANGFUSE_SECRET_KEY") or E.get("LANGFUSE_INIT_PROJECT_SECRET_KEY", "")
CH_URL = os.environ.get("CH_URL", "http://localhost:8123")


def api(method: str, path: str, **kw) -> httpx.Response:
    r = httpx.request(method, f"{HOST}{path}", auth=(PK, SK), timeout=60, **kw)
    return r


def ch(sql: str, settings: dict | None = None) -> list[dict]:
    params = {"default_format": "JSONEachRow", **(settings or {})}
    r = httpx.post(CH_URL, params=params, content=sql.encode(),
                   auth=(E.get("CLICKHOUSE_USER", "default"), E.get("CLICKHOUSE_PASSWORD", "")),
                   timeout=600)
    if r.status_code != 200:
        raise RuntimeError(f"ClickHouse {r.status_code}: {r.text[:500]}")
    return [json.loads(x) for x in r.text.splitlines() if x.strip()]
