#!/usr/bin/env python3
"""04-tokenizers.py — how each text-index tokenizer treats Korean, with real indexes.

1. tokens() of one sentence per tokenizer, on both servers (the stack's 26.8 and the lab's own).
2. The JSON decode that 03-copy-mv.sql relies on, on both servers.
3. On the lab's own server: one table per tokenizer, each with a text index on lower(content),
   filled with the 9000 rows of the copy (remote() from the stack's server); every search term
   is run through the index function and compared with the truth, positionUTF8 on the same text.
4. Langfuse's own UI search predicate (v4.56.0) on events_full, per observation name.

Writes .run/tokenizers.json and prints the tables. Read-only on the stack's server.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lablib  # noqa: E402

DB = lablib.LAB_DB
SENTENCE = "주택담보대출을 OTP가 API timeout으로"

TOKENIZERS = [
    # (key, index tokenizer expression, tokens() arguments)
    ("splitByNonAlpha", "splitByNonAlpha", "'splitByNonAlpha'"),
    ("icu('ko')", "icu('ko')", "'icu', 'ko'"),
    ("asciiCJK", "asciiCJK", "'asciiCJK'"),
    ("ngrams(2)", "ngrams(2)", "'ngrams', 2"),
    ("ngrams(3)", "ngrams(3)", "'ngrams', 3"),
    ("sparseGrams", "sparseGrams", "'sparseGrams'"),
]

TERMS = ["대출", "주택담보대출", "담보대출", "비밀번호 재설정", "환불요청", "OTP", "앱", "timeout"]


def remote_src():
    u, p = os.environ["CLICKHOUSE_USER"], os.environ["CLICKHOUSE_PASSWORD"]
    return f"remote('host.docker.internal:9000', {DB}.events_text, '{u}', '{p}')"


def esc(s):
    return s.replace("\\", "\\\\").replace("'", "\\'")


def main():
    os.makedirs(lablib.RUN_DIR, exist_ok=True)
    out = {"versions": {t: lablib.ch(t, "SELECT version()").strip() for t in ("LF", "FTS")}}

    print("── 1. tokens() of one sentence")
    print(f"   {SENTENCE}")
    out["tokens"] = {}
    for key, _, args in TOKENIZERS:
        res = {t: lablib.ch(t, f"SELECT tokens('{SENTENCE}', {args})", fmt="TSV").strip() for t in ("LF", "FTS")}
        same = res["LF"] == res["FTS"]
        out["tokens"][key] = {"tokens": res["FTS"], "same_on_both": same}
        print(f"   {key:16} {res['FTS']}{'' if same else '   (26.8: ' + res['LF'] + ')'}")

    print("── 2. JSON decode used by the copy (03-copy-mv.sql)")
    # What the Python SDK writes for a list of messages: json.dumps with ensure_ascii (\\uXXXX escapes).
    probe = json.dumps([{"role": "user", "content": "대출을 갚으면"}])
    assert "\\u" in probe and "대출" not in probe
    out["decode"] = {}
    for t in ("LF", "FTS"):
        got = lablib.ch(t, f"SELECT JSONExtractString(concat('{{\"v\":', '{esc(probe)}', '}}'), 'v')", fmt="TSVRaw").strip()
        out["decode"][t] = got
        print(f"   {t}: {got}")

    print("── 3. index per tokenizer, 9000 rows, every term through the index function")
    lablib.ch("FTS", f"CREATE DATABASE IF NOT EXISTS {DB}")
    lablib.ch("FTS", f"DROP TABLE IF EXISTS {DB}.src")
    lablib.ch("FTS", f"""CREATE TABLE {DB}.src ENGINE = MergeTree ORDER BY (trace_id, span_id) AS
        SELECT trace_id, span_id, name, concat(input_text, '\\n', output_text) AS content
        FROM {remote_src()}""")
    n = int(lablib.ch("FTS", f"SELECT count() FROM {DB}.src"))
    out["rows"] = n
    truth = {}
    for term in TERMS:
        truth[term] = int(lablib.ch("FTS", f"SELECT countIf(positionUTF8(lower(content), lower('{esc(term)}')) > 0) FROM {DB}.src"))
    out["truth"] = truth
    out["matrix"] = {}
    for key, tok, args in TOKENIZERS:
        tbl = f"{DB}.tok_" + "".join(c for c in key if c.isalnum()).lower()
        lablib.ch("FTS", f"DROP TABLE IF EXISTS {tbl}")
        lablib.ch("FTS", f"""CREATE TABLE {tbl} (trace_id String, span_id String, content String,
            INDEX idx lower(content) TYPE text(tokenizer = {tok}))
            ENGINE = MergeTree ORDER BY (trace_id, span_id)""")
        lablib.ch("FTS", f"INSERT INTO {tbl} SELECT trace_id, span_id, content FROM {DB}.src")
        row = {}
        for term in TERMS:
            r = {}
            needle = lablib.ch("FTS", f"SELECT tokens(lower('{esc(term)}'), {args})", fmt="TSV").strip()
            r["needle_tokens"] = needle
            for fn in ("hasAllTokens", "hasPhrase", "hasToken"):
                if fn == "hasToken" and key != "splitByNonAlpha":
                    continue
                if fn == "hasPhrase" and key not in ("asciiCJK", "ngrams(2)", "splitByNonAlpha"):
                    continue
                sql = f"""SELECT count() AS found,
                          countIf(positionUTF8(lower(content), lower('{esc(term)}')) = 0) AS false_pos
                          FROM {tbl} WHERE {fn}(lower(content), lower('{esc(term)}'))"""
                try:
                    res = lablib.rows("FTS", sql, settings={"force_data_skipping_indices": "idx"})[0]
                    res = {k: int(v) for k, v in res.items()}
                    res["missed"] = truth[term] - (res["found"] - res["false_pos"])
                except RuntimeError as e:
                    res = {"error": str(e).splitlines()[0][:200]}
                r[fn] = res
            row[term] = r
        out["matrix"][key] = row
        print(f"   {key}")
        for term in TERMS:
            cells = []
            for fn in ("hasAllTokens", "hasPhrase", "hasToken"):
                if fn in row[term]:
                    c = row[term][fn]
                    cells.append(f"{fn}: " + (c["error"] if "error" in c else
                                 f"found {c['found']}, missed {c['missed']}, false+ {c['false_pos']}"))
            print(f"     {term:10} truth {truth[term]:5}  needle {row[term]['needle_tokens']:40} " + " | ".join(cells))
    print("── 4. Langfuse's own search predicate on events_full (stack's server, read only)")
    # The content search of the UI on the v4 events path (packages/shared/src/server/queries/
    # clickhouse-sql/search.ts and fts.ts at v4.56.0): for each of input and output,
    #   col ILIKE '%q%' AND hasAllTokens(lower(col), arraySlice(arrayDistinct(tokens(lower('%q%'))), 1, 64))
    # OR the same with q re-encoded as \uXXXX escapes (toJsonUnicodeEscaped), for JSON written by
    # an ensure_ascii serializer. Truth: positionUTF8 on the decoded text of the copy.
    def pred(col):
        one = lambda p: (f"({col} ILIKE {{{p}:String}} AND hasAllTokens(lower({col}), "  # noqa: E731
                         f"arraySlice(arrayDistinct(tokens(lower({{{p}:String}}))), 1, 64)))")
        return f"({one('q')} OR {one('qe')})"
    out["langfuse_ui"] = {}
    B = chr(92)  # a backslash
    for term in ["중도상환수수료", "주택담보대출", "OTP", "대출"]:
        qe = "".join(c if ord(c) < 0x80 else "\\u%04x" % ord(c) for c in term)
        sql = f"""SELECT e.name AS name, countIf({pred('e.input')} OR {pred('e.output')}) AS ui,
                  countIf(positionUTF8(t.input_text, '{esc(term)}') > 0 OR positionUTF8(t.output_text, '{esc(term)}') > 0) AS truth
                  FROM default.events_full AS e INNER JOIN {DB}.events_text AS t USING (span_id)
                  WHERE has(e.tags, '{lablib.LAB_TAG}') AND has(e.tags, 'batch:base') GROUP BY name ORDER BY name"""
        res = lablib.rows("LF", sql, settings={"param_q": f"%{term}%", "param_qe": f"%{qe}%"})
        # v4.83.0 (search.ts) passes both values through escapeSqlLikePattern first: \ → \\, % → \%, _ → \_.
        like = lambda v: v.replace(B, B + B).replace("%", B + "%").replace("_", B + "_")  # noqa: E731
        res483 = lablib.rows("LF", sql, settings={"param_q": f"%{like(term)}%", "param_qe": f"%{like(qe)}%"})
        ui483 = {r["name"]: int(r["ui"]) for r in res483}
        out["langfuse_ui"][term] = {r["name"]: {"ui": int(r["ui"]), "ui_4_83": ui483[r["name"]], "truth": int(r["truth"])} for r in res}
        print(f"   {term:8} " + "  ".join(f"{r['name']} {r['ui']}/{r['truth']} (4.83 form {ui483[r['name']]})" for r in res))
    json.dump(out, open(os.path.join(lablib.RUN_DIR, "tokenizers.json"), "w"), ensure_ascii=False, indent=1)
    print(f"✓ .run/tokenizers.json ({n} rows, {len(TOKENIZERS)} tokenizers, {len(TERMS)} terms)")


if __name__ == "__main__":
    main()
