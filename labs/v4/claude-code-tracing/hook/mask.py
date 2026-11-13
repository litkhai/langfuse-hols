"""Masking for the Claude Code -> Langfuse hook.

Langfuse applies `mask` to every observation input, output and metadata before export
(Langfuse(mask=...)). CC_LANGFUSE_CONTENT picks how much leaves this machine:

  masked   (default) everything is sent, with secret-shaped strings replaced by [REDACTED:<kind>]
           and the home directory written as ~ (file paths otherwise carry the user name)
  prompts  as masked, and the text you typed (role=user content) becomes [prompt hidden: N chars]
  none     every string value becomes [hidden: N chars]; observation names (Tool: Bash ...), model,
           token counts and timings remain
  full     no masking
"""
import os
import re
from typing import Any, Callable, List, Tuple

_PATTERNS: List[Tuple["re.Pattern[str]", str]] = [
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S), "[REDACTED:private-key]"),
    (re.compile(r"IQoJb3JpZ2lu[A-Za-z0-9/+=]{40,}"), "[REDACTED:aws-session-token]"),
    (re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"), "[REDACTED:aws-access-key-id]"),
    (re.compile(r"\b[sp]k-lf-[0-9a-f-]{20,}"), "[REDACTED:langfuse-key]"),
    (re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}"), "[REDACTED:anthropic-key]"),
    (re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}"), "[REDACTED:api-key]"),
    (re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})"), "[REDACTED:github-token]"),
    (re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}"), "[REDACTED:slack-token]"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"), "[REDACTED:jwt]"),
    (re.compile(r"(?i)(\bbearer\s+)[A-Za-z0-9._~+/=-]{16,}"), r"\1[REDACTED:bearer]"),
    (re.compile(r"(\b[a-z][a-z0-9+.-]*://[^\s:/@]+:)[^\s@/]{3,}(@)"), r"\1[REDACTED:password]\2"),
    (re.compile(r"(?i)(\s--?(?:password|passwd|token|secret|api-key|access-key)(?:=|\s+)[\"']?)(?!\[REDACTED)([^\s\"']{3,})"), r"\1[REDACTED:secret]"),
    # NAME=value / NAME: value where NAME looks like a credential (env files, configs, CLI flags)
    (re.compile(
        r"(?i)(\b[A-Z0-9_.-]*(?:SECRET|PASSWORD|PASSWD|TOKEN|API[_-]?KEY|ACCESS[_-]?KEY|PRIVATE[_-]?KEY|CREDENTIAL)[A-Z0-9_.-]*"
        r"[\"']?\s*[=:]\s*[\"']?)(?!\[REDACTED)([^\s\"',;]{6,})"), r"\1[REDACTED:secret]"),
]


def redact(s: str) -> str:
    for rx, repl in _PATTERNS:
        s = rx.sub(repl, s)
    return s


def _walk(data: Any, fn: Callable[[str], str], hide_user: bool) -> Any:
    if isinstance(data, str):
        return fn(data)
    if isinstance(data, list):
        return [_walk(x, fn, hide_user) for x in data]
    if isinstance(data, dict):
        if hide_user and data.get("role") == "user" and isinstance(data.get("content"), str):
            out = {k: _walk(v, fn, hide_user) for k, v in data.items() if k != "content"}
            out["content"] = f"[prompt hidden: {len(data['content'])} chars]"
            return out
        return {k: _walk(v, fn, hide_user) for k, v in data.items()}
    return data


def build_mask() -> Callable[..., Any]:
    mode = os.environ.get("CC_LANGFUSE_CONTENT", "masked").strip().lower()
    if mode == "full":
        return lambda *, data, **_: data
    if mode == "none":
        return lambda *, data, **_: _walk(data, lambda s: f"[hidden: {len(s)} chars]" if s else s, False)
    hide_user = mode == "prompts"
    home = os.path.expanduser("~").rstrip("/")
    def fn(s: str) -> str:
        s = redact(s)
        return s.replace(home + "/", "~/") if home and home != "~" else s
    return lambda *, data, **_: _walk(data, fn, hide_user)
