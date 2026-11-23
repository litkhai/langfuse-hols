"""lablib.py — shared helpers of the langfuse-ch-vector lab (no dependencies beyond the lab venv).

- env:      _base/.env (Langfuse keys, ClickHouse user and password), the same file compose reads
- ch():     ClickHouse over HTTP with query parameters (urllib, no driver)
- model():  the embedding model, pinned to one revision of the model card
- text_of(): the text of a Langfuse input/output value (JSON string or plain text)
"""
import json
import os
import urllib.parse
import urllib.request

LAB_DIR = os.path.dirname(os.path.abspath(__file__))
BASE_DIR = os.path.normpath(os.path.join(LAB_DIR, "..", "..", "..", "_base"))

LAB_TAG = "lab:langfuse-ch-vector"
DB = "lab_langfuse_ch_vector"

# nlpai-lab/KURE-v1: Korean retrieval model fine-tuned from BAAI/bge-m3, MIT licence,
# 567,754,752 parameters (2,271,064,456 bytes of safetensors), 1024 dimensions, output
# L2-normalised by its sentence-transformers Normalize module. Read from the model card and
# https://huggingface.co/api/models/nlpai-lab/KURE-v1?blobs=true on 2026-11-23.
MODEL_ID = os.environ.get("EMBED_MODEL", "nlpai-lab/KURE-v1")
MODEL_REVISION = os.environ.get("EMBED_REVISION", "444abe2a0ef1d6fd226b31de0b94133430b4de8e")
DIM = 1024


def load_dotenv(path=os.path.join(BASE_DIR, ".env")):
    if not os.path.exists(path):
        return
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            val = val.split(" #", 1)[0].strip().strip('"').strip("'")
            os.environ.setdefault(key.strip(), val)


load_dotenv()

CH_URL = os.environ.get("CH_URL", "http://localhost:8123")
CH_USER = os.environ.get("CLICKHOUSE_USER", "clickhouse")
CH_PASSWORD = os.environ.get("CLICKHOUSE_PASSWORD", "")
PROJECT_ID = os.environ.get("LANGFUSE_INIT_PROJECT_ID", "llm-observability")


def ch(query, params=None, data=None, url=None, settings=None, fmt=None, timeout=600):
    """Run one statement. `params` become ClickHouse query parameters ({name:Type} in SQL).
    `data` (bytes) is sent as the body after the query (INSERT ... FORMAT ...).
    Returns the response text; raises RuntimeError with ClickHouse's message on failure."""
    q = {"query": query} if data is not None else {}
    for k, v in (params or {}).items():
        if isinstance(v, (list, tuple)):
            v = "[" + ",".join(repr(float(x)) for x in v) + "]"
        q[f"param_{k}"] = str(v)
    for k, v in (settings or {}).items():
        q[k] = str(v)
    if fmt:
        q["default_format"] = fmt
    full = (url or CH_URL) + "/?" + urllib.parse.urlencode(q)
    body = data if data is not None else query.encode()
    req = urllib.request.Request(full, data=body, method="POST")
    req.add_header("X-ClickHouse-User", CH_USER)
    req.add_header("X-ClickHouse-Key", CH_PASSWORD)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read().decode()
    except urllib.error.HTTPError as e:
        raise RuntimeError(e.read().decode()[:2000]) from None


def ch_rows(query, **kw):
    """Rows as dicts (JSONEachRow)."""
    out = ch(query, fmt="JSONEachRow", **kw)
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def insert_rows(table, rows, url=None):
    if not rows:
        return
    body = "\n".join(json.dumps(r, ensure_ascii=False) for r in rows).encode()
    ch(f"INSERT INTO {table} FORMAT JSONEachRow", data=body, url=url)


_model = None


def model():
    global _model
    if _model is None:
        import torch
        from sentence_transformers import SentenceTransformer
        dev = "mps" if torch.backends.mps.is_available() else ("cuda" if torch.cuda.is_available() else "cpu")
        _model = SentenceTransformer(MODEL_ID, revision=MODEL_REVISION, device=dev)
    return _model


def embed(texts, batch_size=64):
    """L2-normalised float32 vectors, one per text."""
    return model().encode(list(texts), batch_size=batch_size, normalize_embeddings=True,
                          convert_to_numpy=True, show_progress_bar=False)


def text_of(value):
    """Langfuse stores input/output as a JSON string. Return the human text in it:
    a plain string as is; for objects the string leaves joined by newlines
    ({"question": "..."} → "..."; chat messages → their contents)."""
    if not value:
        return ""
    try:
        obj = json.loads(value)
    except (ValueError, TypeError):
        return value.strip()
    parts = []

    def walk(o):
        if isinstance(o, str):
            if o.strip():
                parts.append(o.strip())
        elif isinstance(o, dict):
            for k, v in o.items():
                if k in ("role", "type", "id"):
                    continue
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)

    walk(obj)
    return "\n".join(parts)
