#!/usr/bin/env python3
"""05-transcripts.py [id ...] — print what each 04-ask.sh run did: model, MCP tool calls
(the SQL for run_query), errors returned to the model, the final answer, turns, time and the
cost Claude Code reported. Reads .run/ask/<id>.jsonl; with no ids, every run there.
--md writes the same as Markdown to .run/ask/<id>.md (pasted into lab-output.md)."""
import glob, json, os, sys

RUN = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".run", "ask")


def load(i):
    rows = [json.loads(l) for l in open(os.path.join(RUN, f"{i}.jsonl")) if l.strip()]
    init = next(r for r in rows if r.get("type") == "system" and r.get("subtype") == "init")
    result = next(r for r in rows if r.get("type") == "result")
    calls, outs = [], {}
    for r in rows:
        msg = r.get("message") or {}
        for c in msg.get("content") or [] if isinstance(msg.get("content"), list) else []:
            if c.get("type") == "tool_use":
                calls.append(c)
            if c.get("type") == "tool_result":
                txt = c.get("content")
                if isinstance(txt, list):
                    txt = "\n".join(x.get("text", "") for x in txt if isinstance(x, dict))
                outs[c["tool_use_id"]] = (bool(c.get("is_error")), str(txt))
    return init, result, calls, outs


def render(i, md=False):
    init, result, calls, outs = load(i)
    servers = ", ".join(f"{s['name']}:{s['status']}" for s in init.get("mcp_servers", []))
    lines = [f"## {i}", "", f"- model: `{init.get('model')}` · Claude Code {init.get('claude_code_version', '?')} · MCP {servers}",
             f"- turns {result.get('num_turns')} · {result.get('duration_ms', 0) / 1000:.1f} s · reported cost {result.get('total_cost_usd')} USD",
             ""]
    for n, c in enumerate(calls, 1):
        name = c["name"].replace("mcp__", "")
        err, out = outs.get(c["id"], (False, ""))
        args = c.get("input") or {}
        lines.append(f"{n}. `{name}`" + (" → **error**" if err or "Exception" in out[:300] else ""))
        if "query" in args:
            lines += ["", "```sql", args["query"].strip(), "```", ""]
        elif args:
            lines += ["", "```json", json.dumps(args, ensure_ascii=False)[:600], "```", ""]
        if err or "Exception" in out[:300] or "error" in out[:80].lower():
            lines += ["   " + out.strip().splitlines()[0][:300] if out.strip() else "", ""]
    lines += ["**Answer**", "", result.get("result", "").strip(), ""]
    # tool results can name files under the home directory (Claude Code spills long results there)
    text = "\n".join(lines).replace(os.path.expanduser("~"), "~")
    if md:
        open(os.path.join(RUN, f"{i}.md"), "w").write(text)
    return text


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--md"]
    ids = args or sorted(os.path.basename(p)[:-6] for p in glob.glob(os.path.join(RUN, "*.jsonl")))
    for i in ids:
        print(render(i, md="--md" in sys.argv))
