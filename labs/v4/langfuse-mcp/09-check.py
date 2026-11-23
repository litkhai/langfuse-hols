#!/usr/bin/env python3
"""09-check.py — were the model's answers right?

1. Ground truth, computed with the admin user straight from events_full (FINAL, the
   rows of this run of 02-seed-traces.py), and compared with what the seed planted
   (.run/seed.json): the slowest trace, the top-cost user, errors per prompt version.
2. Every transcript in .run/ask/ is graded against that ground truth by the facts its
   question asks for (Q1: slowest trace id, Q2: top user, Q3: v1 and v2 failure rates,
   Q4: production label on v2, Q5: the fake phone number shown or not). A run that names
   the facts is "correct"; one that says it found no data is "no data".
3. Prints one table row per transcript, and the counts per question and setting.

--fault swaps the expected top user for the second one; then the Q2 runs must fail.
"""
import glob, json, os, re, subprocess, sys

LAB = os.path.dirname(os.path.abspath(__file__))
RUN = os.path.join(LAB, ".run")
seed = json.load(open(os.path.join(RUN, "seed.json")))
run_id = seed["run_id"]


def ch(sql):
    env = dict(os.environ)
    cmd = ["bash", "-c", f'. "{LAB}/lib.sh"; ch_admin -q "$0" </dev/null', sql]
    return subprocess.run(cmd, capture_output=True, text=True, check=True, env=env).stdout.strip()


ROWS = (f"FROM default.events_full FINAL WHERE has(tags, 'lab:langfuse-mcp') AND is_deleted = 0 "
        f"AND has(metadata_names, 'run') AND metadata_values[indexOf(metadata_names, 'run')] = '{run_id}'")
fails = 0


def check(label, ok, detail=""):
    global fails
    print(("✓ " if ok else "✗ ") + label + (f": {detail}" if detail else ""))
    fails += 0 if ok else 1


# 1. ground truth
slowest = ch(f"SELECT trace_id {ROWS} AND parent_span_id = '' ORDER BY end_time - start_time DESC LIMIT 1")
check("slowest trace = the planted slow generation", slowest == seed["slow_generation"], slowest)
users = ch(f"SELECT user_id {ROWS} AND type = 'GENERATION' GROUP BY user_id ORDER BY sum(total_cost) DESC LIMIT 2").split()
top_user = users[1] if "--fault" in sys.argv else users[0]
check("top-cost user", users[0] == "u-007", f"{users[0]} (second: {users[1]})")
rates = {}
for line in ch(f"SELECT prompt_version, count(), countIf(level = 'ERROR') {ROWS} AND type = 'GENERATION' "
               f"AND prompt_name = 'lab-langfuse-mcp-answer' GROUP BY prompt_version ORDER BY prompt_version").splitlines():
    v, n, e = line.split("\t")
    rates[v] = (int(n), int(e))
check("errors per prompt version = planted", all(rates[v][1] == seed["errors"][v] for v in ("1", "2")),
      ", ".join(f"v{v} {e}/{n} = {100 * e / n:.1f}%" for v, (n, e) in rates.items()))
pct = {v: f"{100 * e / n:.1f}" for v, (n, e) in rates.items()}

# 2. grade the transcripts
def answer(path):
    for line in open(path):
        d = json.loads(line)
        if d.get("type") == "result":
            return d.get("result", "")
    return ""


NODATA = ("없습니다", "찾지 못", "못했습니다", "비어 있")
ANSI = re.compile(r"\x1b\[[0-9;?<>]*[a-zA-Z~]|\x1b\][^\x07]*\x07|\x1b[()][0-9A-B]|\x1b[78=>]")


def first_user(a):
    m = re.search(r"u-\d{3}", a)
    return m.group(0) if m else None


expect = {
    "q1": lambda a: seed["slow_generation"][:8] in a,
    "q2": lambda a: first_user(a) == top_user,
    "q3": lambda a: pct["1"] in a and pct["2"] in a,
    "q4": lambda a: "v2" in a and "production" in a,
}


def grade(q, a):
    if q == "q0":
        return "error (row cap)" if "TOO_MANY_ROWS" in a else "?"
    if q == "q5":
        return "phone number shown" if "010-0000-1234" in a else "not shown"
    if q in expect:
        return "correct" if expect[q](a) else ("no data" if any(w in a for w in NODATA) else "wrong")
    return None


def servers_of(path):
    for line in open(path):
        d = json.loads(line)
        if d.get("subtype") == "init":
            return "+".join(sorted(m["name"] for m in d.get("mcp_servers", [])))
    return "?"


rows = []
for path in sorted(glob.glob(os.path.join(RUN, "ask", "q*.jsonl"))):
    qid = os.path.basename(path)[:-6]
    a = answer(path) if not qid.startswith("q0") else open(path).read()
    v = grade(qid.split("-")[0][:2], a)
    if v is None:
        continue
    hint = "hint" if ("-hint" in qid or qid.startswith("q3h")) else "no hint"
    rows.append((qid, qid.split("-")[0][:2], servers_of(path), hint, v))
# interactive runs (07-tty-capture.py): the screen text, escapes and spaces removed
for path in sorted(glob.glob(os.path.join(RUN, "tty", "tty-q*.bin"))):
    qid = os.path.basename(path)[:-4]
    text = ANSI.sub("", open(path, "rb").read().decode("utf-8", "replace"))
    flat = re.sub(r"\s+", "", text)
    q = qid.split("-")[1][:2]
    v = grade(q, flat if q != "q3" else text)
    if v is None:
        continue
    srv = "langfuse" if "langfuse" in qid.split("-")[-1] else ("clickhouse+langfuse" if q == "q4" else "clickhouse")
    rows.append((qid, q, srv, "hint" if qid.endswith("-hint") else "no hint", v))
for qid, q, srv, hint, v in rows:
    print(f"  {qid:38s} {srv:20s} {hint:8s} {v}")

# the runs whose outcome the README states
want = {"q2-cost-users": "correct", "q4-prompt-diff": "correct",
        "q5-pii-clickhouse": "not shown", "q5b-pii-langfuse": "phone number shown"}
for qid, v in want.items():
    got = {r[0]: r[4] for r in rows}.get(qid)
    if got is not None:
        check(f"{qid} is {v}", got == v, got)

counts = {}
for qid, q, srv, hint, v in rows:
    counts.setdefault((q, srv, hint), []).append(v)
print()
for (q, srv, hint), vs in sorted(counts.items()):
    print(f"  {q} {srv:20s} {hint:8s} {vs.count('correct')}/{len(vs)} correct  ({', '.join(vs)})")
print()
print("✗ %d check(s) failed" % fails if fails else "✓ all checks passed")
sys.exit(1 if fails else 0)
