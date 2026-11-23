#!/usr/bin/env python3
"""06-langfuse-search.py — Langfuse's built-in full-text search, run for real, on the same Korean terms.

Langfuse v4 ships full-text search over input and output (since v4.0.0). Two entry points:

  * the UI search bar (content:, input:, output:) — its predicate is measured in 04-tokenizers.py step 4;
  * the Observations API v2 `matches` operator — this script calls it:
        GET /api/public/v2/observations?filter=[{"type":"string","column":"output","operator":"matches","value":…}]
    Source (v4.56.0 clickhouse-filter.ts / fts.ts, v4.83.0 events-predicate.ts):
        position(lower(col), lower(q)) > 0 AND hasAllTokens(lower(col), q)
    with no second try on the \\uXXXX-escaped form, unlike the UI search.

For every term and column the script pages through the API, keeps the observations of this lab
(tag lab:langfuse-ch-fts, batch base) and compares them, per observation name, with the truth:
positionUTF8 on the decoded text of the copy (lab_langfuse_ch_fts.events_text). The same terms
through the copy's ngrams(2) index are counted alongside. Writes .run/langfuse-search.json.
"""
import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lablib  # noqa: E402

DB = lablib.LAB_DB
TAG = lablib.LAB_TAG
TERMS = ["중도상환수수료", "중도상환수수료는", "주택담보대출", "대출", "환불요청", "OTP", "timeout", "앱"]
NAMES = ["support-chat", "retrieve-context", "answer-generation"]


def esc(s):
    return s.replace("\\", "\\\\").replace("'", "\\'")


def api_ids(column, term):
    auth = base64.b64encode(f"{os.environ['LANGFUSE_PUBLIC_KEY']}:{os.environ['LANGFUSE_SECRET_KEY']}".encode()).decode()
    host = os.environ.get("LANGFUSE_HOST", "http://localhost:3000").rstrip("/")
    flt = json.dumps([{"type": "string", "column": column, "operator": "matches", "value": term}], ensure_ascii=False)
    ids, cursor, pages = set(), None, 0
    while True:
        params = {"filter": flt, "limit": 1000, "fields": "core"}
        if cursor:
            params["cursor"] = cursor
        req = urllib.request.Request(f"{host}/api/public/v2/observations?" + urllib.parse.urlencode(params),
                                     headers={"Authorization": "Basic " + auth})
        try:
            body = json.loads(urllib.request.urlopen(req, timeout=120).read())
        except urllib.error.HTTPError as e:
            return None, f"HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:160]}"
        ids.update(o["id"] for o in body.get("data", []))
        pages += 1
        cursor = (body.get("meta") or {}).get("cursor")
        if not cursor or not body.get("data") or pages > 50:
            return ids, None


def main():
    os.makedirs(lablib.RUN_DIR, exist_ok=True)
    version = lablib.ch("LF", "SELECT version()").strip()
    out = {"clickhouse": version, "terms": {}}
    print(f"── Observations API v2 `matches` (Langfuse on the stack, ClickHouse {version})")
    print(f"   per observation name: API found / truth   (copy ngrams(2) index found)")
    for term in TERMS:
        row = {}
        for column in ("input", "output"):
            ids, err = api_ids(column, term)
            if err:
                row[column] = {"error": err}
                print(f"   {term:10} {column:6} {err}")
                continue
            found = {n: 0 for n in NAMES}
            if ids:
                idlist = ",".join(f"'{i}'" for i in ids)
                for r in lablib.rows("LF", f"""SELECT name, count() AS c FROM default.events_full
                        WHERE span_id IN ({idlist}) AND has(tags, '{TAG}') AND has(tags, 'batch:base') GROUP BY name"""):
                    found[r["name"]] = int(r["c"])
            col = f"{column}_text"
            truth = {r["name"]: int(r["c"]) for r in lablib.rows("LF", f"""SELECT name, countIf(positionUTF8(lower({col}), lower('{esc(term)}')) > 0) AS c
                    FROM {DB}.events_text FINAL WHERE has(tags, 'batch:base') GROUP BY name""")}
            copy = {r["name"]: int(r["c"]) for r in lablib.rows("LF", f"""SELECT name, count() AS c FROM {DB}.events_text FINAL
                    WHERE has(tags, 'batch:base') AND hasAllTokens(lower({col}), lower('{esc(term)}')) GROUP BY name""")}
            row[column] = {n: {"api": found.get(n, 0), "truth": truth.get(n, 0), "copy_ngrams2": copy.get(n, 0)} for n in NAMES}
            print(f"   {term:10} {column:6} " + "  ".join(
                f"{n} {row[column][n]['api']}/{row[column][n]['truth']} ({row[column][n]['copy_ngrams2']})" for n in NAMES))
        out["terms"][term] = row
    json.dump(out, open(os.path.join(lablib.RUN_DIR, "langfuse-search.json"), "w"), ensure_ascii=False, indent=1)
    print("✓ .run/langfuse-search.json")


if __name__ == "__main__":
    main()
