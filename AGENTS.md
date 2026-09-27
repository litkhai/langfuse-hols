# AGENTS.md

Instructions for coding agents working in this repository.

This repository was split out of [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols). Its
[AGENTS.md](https://github.com/litkhai/clickhouse-hols/blob/main/AGENTS.md) still applies here —
bilingual READMEs (English first, `## English` / `## 한국어`), no links to labs
that do not exist yet, and the **Verification claims** rule: only write
*"Verified on …"* when the scripts actually ran end to end against that version.

Differences from the core repository:

- No Pages site and no `site` CI job (decision D7). The root README tables are
  documentation only, not a site index.
- Enable the guard once per clone: `git config core.hooksPath .githooks`.

## Rules for this repository

- `labs/langfuse-eval` imports the trace generator from `labs/langfuse-ee` and shares its
  compose stack. They are siblings on purpose — never move one without the other.
- Verification lines name Langfuse, the Python SDK and ClickHouse versions
  (e.g. *Langfuse v3.197.1 / SDK 3.7.0 / CH 25.11*).
- `labs/langfuse-ee/08-generate-pii-traces.py` fabricates PII on purpose and is allowlisted
  in `.gitleaks.toml`. Do not widen that allowlist to a directory.

## Where things came from

Paths were renamed by `git filter-repo`, so `git log --follow` works across the
split. The original locations:

| In clickhouse-hols | Here |
|---|---|
| `usecase/langfuse-ee/` | `labs/langfuse-ee/` |
| `usecase/langfuse-eval/` | `labs/langfuse-eval/` |
