"""Applies this lab's three additions to Langfuse's published langfuse_hook.py.

Usage: python patch_hook.py <published langfuse_hook.py> <out file>

1. CC_LANGFUSE_REPO (set by stop.sh) becomes a trace tag and metadata `repo`.
2. Every input, output and metadata goes through mask.py (Langfuse(mask=...), CC_LANGFUSE_CONTENT).
3. CC_LANGFUSE_STATE_DIR moves the state and log directory (default ~/.claude/state, as published).

Each anchor must exist exactly once, so a changed upstream script fails here instead of being
patched halfway.
"""
import sys

src, out = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()


def sub(old: str, new: str) -> None:
    global s
    n = s.count(old)
    if n != 1:
        sys.exit(f"patch_hook: anchor found {n} times, expected 1: {old.strip()[:70]!r}")
    s = s.replace(old, new)


sub('STATE_DIR = Path.home() / ".claude" / "state"\n',
    'STATE_DIR = Path(os.environ.get("CC_LANGFUSE_STATE_DIR") or (Path.home() / ".claude" / "state"))\n')
sub('        tags=["claude-code"],\n',
    '        tags=["claude-code"] + ([os.environ["CC_LANGFUSE_REPO"]] if os.environ.get("CC_LANGFUSE_REPO") else []),\n')
sub('                "source": "claude-code",\n',
    '                "source": "claude-code",\n                "repo": os.environ.get("CC_LANGFUSE_REPO", ""),\n')
sub("        langfuse = Langfuse(public_key=public_key, secret_key=secret_key, host=host)\n",
    "        from mask import build_mask  # lab addition, see patch_hook.py\n"
    "        langfuse = Langfuse(public_key=public_key, secret_key=secret_key, host=host, mask=build_mask())\n")
open(out, "w", encoding="utf-8").write(s)
