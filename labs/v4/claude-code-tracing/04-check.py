"""Checks the runs of 03 against what Langfuse stored, in ClickHouse (events_full) and in the raw
OTLP event files in MinIO, and measures them.

  python 04-check.py           expect: masked/prompts/none hold no fake value, full holds all of them
  python 04-check.py --fault   swaps the expectations of the masked and full runs: must FAIL

Langfuse v4 in events_only mode has no /api/public/traces, so everything is read from storage.
Results: .run/check.json. Exit 1 on any FAIL.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

LAB = Path(__file__).resolve().parent
RUN = LAB / ".run"
CH = "http://localhost:18423/"
fails = 0
results: list[dict] = []


def ch(sql: str) -> list[dict]:
    p = subprocess.run(["curl", "-fsS", "-u", "clickhouse:clickhouse", CH + "?default_format=JSONEachRow",
                        "--data-binary", sql], capture_output=True, text=True, check=True)
    return [json.loads(l) for l in p.stdout.splitlines() if l.strip()]


def check(name: str, ok: bool, detail: str = "") -> None:
    global fails
    fails += 0 if ok else 1
    results.append({"check": name, "ok": ok, "detail": detail})
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""))


def q(s: str) -> str:
    return s.replace("\\", "\\\\").replace("'", "\\'")


def main() -> int:
    fault = "--fault" in sys.argv
    f = json.loads((RUN / "fakes.json").read_text())
    runs = {(r["mode"], r["repo"]): r for r in json.loads((RUN / "runs.json").read_text())}
    sid = {k: r["session_id"] for k, r in runs.items()}

    # Langfuse's worker writes events_full asynchronously; wait until the four allowed sessions are in.
    allowed = [v for (m, w), v in sid.items() if w == "allowed"]
    inlist = ",".join(f"'{s}'" for s in allowed)
    for _ in range(60):
        if ch(f"SELECT count(DISTINCT session_id) AS n FROM events_full WHERE session_id IN ({inlist})")[0]["n"] == 4:
            break
        time.sleep(2)

    # 1. Repository filter
    d = ch(f"SELECT count() AS n FROM events_full WHERE session_id = '{sid[('masked', 'denied')]}'")[0]["n"]
    check("denied repository: nothing stored", d == 0, f"{d} rows")
    for mode in ("masked", "prompts", "none", "full"):
        rows = ch(f"SELECT type, name, tags FROM events_full WHERE session_id = '{sid[(mode, 'allowed')]}'")
        tagged = all("allowed-lab" in r["tags"] for r in rows)
        tool = any(r["name"] == "Tool: Read" for r in rows)
        check(f"{mode}: trace stored, tagged allowed-lab, Tool: Read kept", bool(rows) and tagged and tool,
              f"{len(rows)} observations")

    # 2. Fake values in ClickHouse
    expect_present = {"masked": False, "prompts": False, "none": False, "full": True}
    if fault:
        expect_present["masked"], expect_present["full"] = True, False
    for mode, present in expect_present.items():
        s = sid[(mode, "allowed")]
        found = []
        for k, v in f.items():
            n = ch(f"SELECT count() AS n FROM events_full WHERE session_id = '{s}' AND (position(input, '{q(v)}') > 0 "
                   f"OR position(output, '{q(v)}') > 0 OR arrayExists(x -> position(x, '{q(v)}') > 0, metadata_values))")[0]["n"]
            if n:
                found.append(k)
        if present:
            check(f"{mode}: all {len(f)} fake values stored (positive control)", len(found) == len(f), f"{len(found)} found")
        else:
            check(f"{mode}: no fake value stored in ClickHouse", not found, ", ".join(found) or "0 of 6")

    # 3. What each mode leaves
    def root_input(mode: str) -> str:
        r = ch(f"SELECT input FROM events_full WHERE session_id = '{sid[(mode, 'allowed')]}' AND type = 'SPAN' LIMIT 1")
        return r[0]["input"] if r else ""

    def tool_output(mode: str) -> str:
        r = ch(f"SELECT output FROM events_full WHERE session_id = '{sid[(mode, 'allowed')]}' AND name = 'Tool: Read' LIMIT 1")
        return r[0]["output"] if r else ""

    check("masked: prompt text kept, secret replaced", "Read config.env" in root_input("masked") and "[REDACTED:" in root_input("masked"))
    check("masked: tool output kept, secrets replaced", "LOG_LEVEL=info" in tool_output("masked") and "[REDACTED:" in tool_output("masked"))
    check("prompts: prompt replaced by its length", "[prompt hidden:" in root_input("prompts") and "Read config.env" not in root_input("prompts"))
    check("prompts: tool output kept, secrets replaced", "LOG_LEVEL=info" in tool_output("prompts") and "[REDACTED:" in tool_output("prompts"))
    check("none: prompt and tool output hidden", "Read config.env" not in root_input("none") and "LOG_LEVEL" not in tool_output("none")
          and "[hidden:" in tool_output("none"))
    home = str(Path.home()) + "/"
    for mode in ("masked", "prompts", "none"):
        n = ch(f"SELECT count() AS n FROM events_full WHERE session_id = '{sid[(mode, 'allowed')]}' AND (position(input, '{q(home)}') > 0 "
               f"OR position(output, '{q(home)}') > 0 OR arrayExists(x -> position(x, '{q(home)}') > 0, metadata_values))")[0]["n"]
        check(f"{mode}: no home directory path stored", n == 0, f"{n} rows")
    n = ch(f"SELECT count() AS n FROM events_full WHERE session_id = '{sid[('full', 'allowed')]}' AND position(input, '{q(home)}') > 0")[0]["n"]
    check("full: home directory path stored (positive control)", n > 0, f"{n} rows")
    usage = ch(f"SELECT sum(usage_details['total']) AS t FROM events_full WHERE session_id = '{sid[('none', 'allowed')]}'")[0]["t"]
    check("none: model and token counts kept", usage > 0, f"{usage} tokens")

    # 4. Raw OTLP event files in MinIO (Langfuse keeps them next to ClickHouse)
    copy = RUN / "minio-copy"
    subprocess.run(["rm", "-rf", str(copy)], check=True)
    subprocess.run(["docker", "cp", "-q", "lf-cc-lab-minio-1:/data/langfuse", str(copy)], check=True)
    blobs = [p.read_bytes() for p in copy.rglob("*") if p.is_file()]
    for mode, present in expect_present.items():
        mine = [b for b in blobs if sid[(mode, "allowed")].encode() in b]
        found = {k for k, v in f.items() if any(v.encode() in b for b in mine)}
        if present:
            check(f"{mode}: fake values in its raw event file (positive control)", bool(mine) and len(found) == len(f),
                  f"{len(mine)} files, {len(found)} values")
        else:
            check(f"{mode}: no fake value in its raw event file", bool(mine) and not found, f"{len(mine)} files")
    check("denied repository: no raw event file", not any(sid[("masked", "denied")].encode() in b for b in blobs))

    # 5. Measurements
    obs = ch(f"SELECT session_id, count() AS n, countIf(type = 'GENERATION') AS gens, countIf(type = 'TOOL') AS tools "
             f"FROM events_full WHERE session_id IN ({inlist}) GROUP BY session_id ORDER BY session_id")
    per_repo = ch("SELECT arrayJoin(arrayFilter(t -> t != 'claude-code', tags)) AS repo, uniqExact(session_id) AS sessions, "
                  "sum(usage_details['input']) AS input, sum(usage_details['output']) AS output, "
                  "sum(usage_details['cache_read_input_tokens']) AS cache_read, "
                  "sum(usage_details['cache_creation_input_tokens']) AS cache_write, "
                  "round(sum(total_cost), 6) AS langfuse_cost_usd "
                  "FROM events_full WHERE type = 'GENERATION' GROUP BY repo")
    hook_s = [float(l.split(" in ")[1].split("s")[0]) for l in (RUN / "state" / "langfuse_hook.log").read_text().splitlines()
              if "Processed" in l]
    payload = json.dumps({"session_id": sid[("masked", "allowed")], "cwd": str(RUN / "repos" / "allowed"),
                          "transcript_path": "/nonexistent"})
    t0 = time.perf_counter()
    subprocess.run([str(RUN / "hook" / "stop.sh")], input=payload, text=True,
                   env={"PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", "HOME": str(Path.home()),
                        "CC_LANGFUSE_ENV_FILE": str(RUN / "langfuse.env")}, check=True)
    stop_ms = round((time.perf_counter() - t0) * 1000)
    m = {"observations_per_turn": obs, "tokens_by_repo": per_repo,
         "hook_upload_seconds": {"min": min(hook_s), "max": max(hook_s), "n": len(hook_s)},
         "stop_sh_return_ms": stop_ms,
         "claude_cost_usd": {f"{k[0]}/{k[1]}": r["cost_usd"] for k, r in runs.items()}}
    print(json.dumps(m, indent=1))
    (RUN / "check.json").write_text(json.dumps({"fault": fault, "fails": fails, "results": results, "measurements": m}, indent=1))
    print(f"\n{len(results) - fails} PASS, {fails} FAIL" + ("  (--fault: failures expected)" if fault else ""))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
