#!/usr/bin/env bash
# Installs the hook into .run/hook/ (never into ~/.claude): Langfuse's published langfuse_hook.py,
# fetched from the docs page and checked against the pinned sha256, plus this lab's patch, mask.py and
# stop.sh, a venv with the track's langfuse pin, and .run/settings.json that registers the Stop hook
# for the runs of 03 only (claude --settings).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
DOC_URL=https://langfuse.com/integrations/developer-tools/claude-code.md
# The hook script block of that page on 2026-11-13. A different hash stops the lab: read the new
# script, then update this pin and patch_hook.py.
DOC_SHA256=6dfb65d9c910eecf6a49d0c8e5018d80163f78587d750a6ca2a786f9d50d5049
HOOK="$RUN_DIR/hook"
mkdir -p "$HOOK" "$RUN_DIR/state"

curl -fsS -m 30 "$DOC_URL" -o "$RUN_DIR/claude-code.md"
python3 - "$RUN_DIR/claude-code.md" "$RUN_DIR/langfuse_hook.published.py" <<'PY'
import re, sys
page = open(sys.argv[1], encoding="utf-8").read()
blocks = [b for b in re.findall(r"```python\n(.*?)```", page, re.S) if "Claude Code -> Langfuse hook" in b]
if len(blocks) != 1:
    sys.exit(f"expected one hook script block on the page, found {len(blocks)}")
open(sys.argv[2], "w", encoding="utf-8").write(blocks[0])
PY
got=$(shasum -a 256 "$RUN_DIR/langfuse_hook.published.py" | cut -c1-64)
[[ "$got" == "$DOC_SHA256" ]] || { echo "✗ published hook changed: sha256 $got, pinned $DOC_SHA256" >&2; exit 1; }
echo "✓ published hook script matches the pin (${got:0:12}…)"

python3 "$LAB_DIR/hook/patch_hook.py" "$RUN_DIR/langfuse_hook.published.py" "$HOOK/langfuse_hook.py"
cp "$LAB_DIR/hook/mask.py" "$LAB_DIR/hook/stop.sh" "$HOOK/"
echo "lab/allowed-lab" > "$HOOK/repos.allow"

[[ -x "$HOOK/venv/bin/python" ]] || python3.12 -m venv "$HOOK/venv"
"$HOOK/venv/bin/pip" install -q --disable-pip-version-check "$(grep -E '^langfuse==' "$TRACK_DIR/requirements.txt")"
"$HOOK/venv/bin/python" -m py_compile "$HOOK/langfuse_hook.py" "$HOOK/mask.py"

# Keys of the lab project (the LANGFUSE_INIT_PROJECT_* values of the secrets file); the state
# directory stays inside .run/ so the runs never touch ~/.claude/state.
umask 077
python3 - "$LF_ENV_FILE" "$RUN_DIR" > "$RUN_DIR/langfuse.env" <<'PY'
import sys
env = {}
for raw in open(sys.argv[1], encoding="utf-8"):
    line = raw.split(" #", 1)[0].strip()
    if "=" in line and not line.startswith("#"):
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip().strip("\"'")
print(f"LANGFUSE_PUBLIC_KEY={env['LANGFUSE_INIT_PROJECT_PUBLIC_KEY']}")
print(f"LANGFUSE_SECRET_KEY={env['LANGFUSE_INIT_PROJECT_SECRET_KEY']}")
print("LANGFUSE_BASE_URL=http://localhost:13000")
print(f"CC_LANGFUSE_STATE_DIR={sys.argv[2]}/state")
PY
cat > "$RUN_DIR/settings.json" <<JSON
{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "$HOOK/stop.sh", "timeout": 10}]}]}}
JSON
echo "✓ hook installed in $HOOK (langfuse $("$HOOK/venv/bin/python" -c 'from importlib.metadata import version; print(version("langfuse"))'))"
