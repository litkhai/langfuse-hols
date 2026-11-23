"""lablib.py — shared by this lab's Python scripts (stdlib only, no ClickHouse driver).

    LF   the shared stack's ClickHouse (Langfuse's own server), credentials from _base/.env
    FTS  the lab's own, newer ClickHouse started by 01-up.sh (user default, password lab)

    ch(target, sql, fmt=None, settings=None) -> str     one statement over HTTP
    rows(target, sql) -> list[dict]                     JSONEachRow
    run_file(target, path)                              statements ending in ';' at end of line
"""
import json
import os
import re
import sys
import urllib.parse
import urllib.request
import base64

LAB_DIR = os.path.dirname(os.path.abspath(__file__))
BASE_DIR = os.path.normpath(os.path.join(LAB_DIR, "..", "..", "..", "_base"))
RUN_DIR = os.path.join(LAB_DIR, ".run")
LAB_DB = "lab_langfuse_ch_fts"
LAB_TAG = "lab:langfuse-ch-fts"


def load_env(path):
    if not os.path.exists(path):
        return
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        v = v.split(" #", 1)[0].strip().strip('"').strip("'")
        os.environ.setdefault(k.strip(), v)


load_env(os.environ.get("LF_ENV_FILE") or os.path.join(BASE_DIR, ".env"))

TARGETS = {
    "LF": (f"http://127.0.0.1:{os.environ.get('LF_CH_HTTP', '8123')}/",
           os.environ.get("CLICKHOUSE_USER", "clickhouse"), os.environ.get("CLICKHOUSE_PASSWORD", "")),
    "FTS": (f"http://127.0.0.1:{os.environ.get('FTS_HTTP', '38123')}/", "default", "lab"),
}


def ch(target, sql, fmt=None, settings=None, timeout=600):
    url, user, pw = TARGETS[target]
    params = dict(settings or {})
    if fmt:
        sql = f"{sql}\nFORMAT {fmt}"
    q = url + ("?" + urllib.parse.urlencode(params) if params else "")
    req = urllib.request.Request(q, data=sql.encode("utf-8"), method="POST")
    req.add_header("Authorization", "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode())
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{target}: {e.read().decode('utf-8', 'replace')[:600]}\n--- SQL ---\n{sql[:400]}") from None


def rows(target, sql, settings=None):
    out = ch(target, sql, fmt="JSONEachRow", settings=settings)
    return [json.loads(l) for l in out.splitlines() if l.strip()]


def statements(path):
    """Split a .sql file on lines that end with ';' (comment lines kept with their statement)."""
    buf, out = [], []
    for line in open(path, encoding="utf-8").read().splitlines():
        buf.append(line)
        if line.rstrip().endswith(";") and not line.lstrip().startswith("--"):
            stmt = "\n".join(buf).strip()[:-1].strip()
            buf = []
            if any(l.strip() and not l.lstrip().startswith("--") for l in stmt.splitlines()):
                out.append(stmt)
    return out


def run_file(target, path, echo=True):
    for stmt in statements(path):
        head = next(l for l in stmt.splitlines() if l.strip() and not l.lstrip().startswith("--"))
        if echo:
            print(f"  [{target}] {head[:100]}")
        res = ch(target, stmt)
        if res.strip() and echo:
            print(res.rstrip())


if __name__ == "__main__":
    # python3 lablib.py LF|FTS file.sql
    run_file(sys.argv[1], sys.argv[2])
