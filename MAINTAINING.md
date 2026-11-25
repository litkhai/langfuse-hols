# Maintaining langfuse-hols

Reference for maintainers, read when needed. `AGENTS.md` points here.

### Where things came from

Paths were renamed by `git filter-repo`, so `git log --follow` works across the
split. The original locations:

| In clickhouse-hols | Here, until #33 | Here, since #33 |
|---|---|---|
| `usecase/langfuse-ee/` | `labs/langfuse-ee/` | `labs/v4/langfuse-ee/` (moved), `labs/v3/langfuse-ee/` (restored) |
| `usecase/langfuse-eval/` | `labs/langfuse-eval/` | `labs/v4/langfuse-eval/` (moved), `labs/v3/langfuse-eval/` (restored) |

`labs/v4/` was moved with `git mv`, so `--follow` reaches back through the v4 port. `labs/v3/`
was written from `git show 1a93628:…`, so its own history starts at #33; for what came before,
run `git log 1a93628 -- labs/langfuse-ee`.
