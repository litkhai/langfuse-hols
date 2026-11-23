#!/usr/bin/env python3
"""07-check.py — the lab's claims as checks, against the live servers and the .run/ results.

    python3 labs/v4/langfuse-ch-fts/07-check.py           # every check must pass
    python3 labs/v4/langfuse-ch-fts/07-check.py --fault   # two expectations inverted: must fail

Needs 03-copy-mv.sql, 04-tokenizers.py, 05-mv-live.py and 06-bench.py to have run.
"""
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lablib  # noqa: E402

FAULT = "--fault" in sys.argv
DB = lablib.LAB_DB
TAG = lablib.LAB_TAG
results = []


def check(name, ok):
    results.append((name, bool(ok)))
    print(f"  {'✓' if ok else '✗'} {name}")


def n(sql):
    return int(lablib.ch("LF", sql).strip())


def load(name):
    return json.load(open(os.path.join(lablib.RUN_DIR, name), encoding="utf-8"))


def main():
    print("── Langfuse's own table (read only)")
    raw_hangul = n(f"SELECT countIf(input LIKE '%대출%') FROM default.events_full WHERE has(tags, '{TAG}')")
    raw_escaped = n(f"SELECT countIf(input LIKE '%\\\\\\\\ub300\\\\\\\\ucd9c%') FROM default.events_full WHERE has(tags, '{TAG}')")
    out_hangul = n(f"SELECT countIf(output LIKE '%대출%') FROM default.events_full WHERE has(tags, '{TAG}') AND name = 'answer-generation'")
    check("events_full.input holds Korean as \\uXXXX escapes: LIKE '%대출%' finds 0 inputs", raw_hangul == 0)
    check("… and the escaped form \\ub300\\ucd9c finds them (positive control)", raw_escaped > 0)
    check("… while a plain-string output stays Hangul: LIKE '%대출%' on answer-generation output > 0", out_hangul > 0)
    ddl = lablib.ch("LF", "SELECT create_table_query FROM system.tables WHERE database = 'default' AND name = 'events_full'")
    check("events_full carries Langfuse's own text index lower(input) … splitByNonAlpha", "idx_fts_input_low" in ddl and "splitByNonAlpha" in ddl)

    print("── the copy and its materialized view")
    src = n(f"SELECT count() FROM default.events_full WHERE has(tags, '{TAG}')")
    cp = n(f"SELECT count() FROM {DB}.events_text FINAL WHERE is_deleted = 0")
    check(f"copy rows (FINAL) = events_full rows with the lab tag ({cp} = {src})", cp == src)
    check("copy input_text has Hangul: LIKE '%대출%' > 0", n(f"SELECT countIf(input_text LIKE '%대출%') FROM {DB}.events_text") > 0)
    check("copy holds only lab rows", n(f"SELECT countIf(NOT has(tags, '{TAG}')) FROM {DB}.events_text") == 0)
    mv = load("mv-live.json")
    check("MV: every new live row reached the copy", mv["insert"]["missing_in_copy"] == 0 and mv["insert"]["copy_rows"] >= 3)
    check("MV: new rows are searchable through the ngrams(2) index (index count = truth)",
          mv["insert"]["daechul_index"] == mv["insert"]["daechul_truth"])
    check("delete through the API removed the trace from events_full but not from the copy",
          mv["delete"]["copy_rows_after_delete"] > 0)
    check("reconcile DELETE removed it from the copy", mv["reconcile"]["copy_rows_after"] == 0)

    print("── tokenizers (.run/tokenizers.json)")
    tk = load("tokenizers.json")
    m = tk["matrix"]
    split_miss = m["splitByNonAlpha"]["담보대출"]["hasAllTokens"]["missed"] == tk["truth"]["담보대출"]
    check("splitByNonAlpha finds none of 담보대출 (inside 주택담보대출)", (not split_miss) if FAULT else split_miss)
    check("splitByNonAlpha misses the particle forms of 대출", m["splitByNonAlpha"]["대출"]["hasAllTokens"]["missed"] > 0)
    terms_ng2 = [t for t in tk["truth"] if t != "앱"]
    check("ngrams(2) hasAllTokens misses nothing (all terms but the one-syllable 앱)",
          all(m["ngrams(2)"][t]["hasAllTokens"]["missed"] == 0 for t in terms_ng2))
    check("ngrams(2) hasAllTokens has false positives on 환불요청", m["ngrams(2)"]["환불요청"]["hasAllTokens"]["false_pos"] > 0)
    check("ngrams(2) finds nothing for a one-syllable term (empty needle)", m["ngrams(2)"]["앱"]["hasAllTokens"]["found"] == 0)
    exact = all(m["asciiCJK"][t]["hasPhrase"]["missed"] == 0 and m["asciiCJK"][t]["hasPhrase"]["false_pos"] == 0 for t in tk["truth"])
    check("asciiCJK hasPhrase is exact on every term", exact)
    ui = tk["langfuse_ui"]["중도상환수수료"]
    check("Langfuse UI predicate: 0 answer-generation rows (plain-string output) for 중도상환수수료",
          ui["answer-generation"]["ui"] == 0 and ui["answer-generation"]["truth"] > 0)
    check("Langfuse UI predicate: every support-chat row (JSON-escaped output) for 중도상환수수료",
          ui["support-chat"]["ui"] == ui["support-chat"]["truth"] > 0)
    check("the JSON decode gives Hangul on both servers", all(v.startswith('[{"role":"user","content":"대출을') for v in tk["decode"].values()))

    print("── benchmark (.run/bench-*.json)")
    for path in sorted(glob.glob(os.path.join(lablib.RUN_DIR, "bench-*.json"))):
        b = json.load(open(path, encoding="utf-8"))
        v = b["version"]
        ok = [r for r in b["results"] if "error" not in r]
        by = {(r["term"], r["method"]): r for r in ok}
        rare = [t for t in {r["term"] for r in ok} if t.startswith("E")][0]
        exact_methods = ["LIKE, no index", "ILIKE, no index", "lower LIKE, ngrams(2)", "hasPhrase, ngrams(2)", "hasPhrase, asciiCJK"]
        check(f"[{v}] LIKE, ILIKE and hasPhrase return the true count for every term",
              all(by[(t, mm)]["count"] == by[(t, mm)]["truth"] for (t, mm) in by if mm in exact_methods))
        ui = by[("중도상환수수료", "Langfuse UI form, splitByNonAlpha")]
        ui_zero = ui["count"] == 0 and ui["truth"] > 0
        check(f"[{v}] the Langfuse UI search form finds 0 of {ui['truth']} rows for 중도상환수수료", (not ui_zero) if FAULT else ui_zero)
        scan = by[(rare, "LIKE, no index")]
        idx = by[(rare, "hasAllTokens, ngrams(2)")]
        check(f"[{v}] rare term: LIKE without index reads every row ({scan['read_rows']:.0f})",
              scan["read_rows"] >= b["sizes"]["b_none"]["rows"])
        check(f"[{v}] rare term: ngrams(2) hasAllTokens reads < 10% of the rows ({idx['read_rows']:.0f})",
              idx["read_rows"] < 0.10 * b["sizes"]["b_ng2"]["rows"])

    failed = [nm for nm, ok in results if not ok]
    print(f"{len(results) - len(failed)}/{len(results)} checks passed" + (" (--fault)" if FAULT else ""))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
