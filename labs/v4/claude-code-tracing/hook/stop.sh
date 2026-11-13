#!/bin/bash
# Claude Code Stop hook: sends the session's new turns to Langfuse, but only from repositories whose
# git origin (owner/name) is listed in repos.allow. Never blocks or fails the session: the upload runs
# in the background, and every early exit is 0.
#
#   CC_LANGFUSE_ENV_FILE   LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY, LANGFUSE_BASE_URL (default ~/.config/claude-langfuse.env);
#                          without this file the hook does nothing
#   CC_LANGFUSE_ALLOW      allowlist file (default repos.allow next to this script)
#   CC_LANGFUSE_PYTHON     Python with langfuse 4.x (default venv/bin/python next to this script)
#   CC_LANGFUSE_CONTENT    masked (default) | prompts | none | full, read by mask.py
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV="${CC_LANGFUSE_ENV_FILE:-$HOME/.config/claude-langfuse.env}"
ALLOW="${CC_LANGFUSE_ALLOW:-$H/repos.allow}"
PY="${CC_LANGFUSE_PYTHON:-$H/venv/bin/python}"
payload=$(cat)
[ -f "$ENV" ] || exit 0
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
url=$(git -C "${cwd:-$PWD}" remote get-url origin 2>/dev/null) || exit 0
# https://host/owner/name(.git), git@host:owner/name(.git), ssh://git@host/owner/name -> owner/name
repo=$(printf '%s' "$url" | sed -E 's#^[a-z+]+://##; s#^[^@/]*@##; s#^[^/:]+[:/]##; s#\.git$##')
grep -qxF "$repo" "$ALLOW" 2>/dev/null || exit 0
set -a; . "$ENV"; set +a
export TRACE_TO_LANGFUSE=true CC_LANGFUSE_REPO="${repo#*/}"
printf '%s' "$payload" | nohup "$PY" "$H/langfuse_hook.py" >/dev/null 2>&1 &
exit 0
