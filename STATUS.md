# STATUS.md

**As of 2026-10-02** — split out of [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols/tree/pre-split-2026-10) with history.

## Verification

Both labs were run end to end on **2026-10-02** against **Langfuse v4.48.0 / SDK 4.16.0 /
ClickHouse 26.8.15.10** on the pinned stack below. That run used a real enterprise licence key,
and real Anthropic calls for the optional path. The per-lab results are in the
[langfuse-ee](labs/langfuse-ee/README.md) and [langfuse-eval](labs/langfuse-eval/README.md)
READMEs, and the logs in each lab's `lab-output.md`.

## CI

`checks` (on pull requests): `links`, `syntax`, `compose` (every overlay set merges and carries
what its lab needs), `sql` (every `.sql` parses in the pinned ClickHouse image), `secrets`
(gitleaks), `hygiene` — green. GitHub secret scanning and push protection are on.

## Pins

The shared stack in [`_base/`](_base/) runs on these versions. Each image tag is the
`${VAR:-default}` default in the compose file, so a run can override it without editing the file.

| Pin | Version | Why |
|---|---|---|
| `langfuse/langfuse`, `langfuse/langfuse-worker` | 4.48.0 | Latest GA release on 2026-09-30, the target of the v4 re-verification ([#6](https://github.com/litkhai/langfuse-hols/issues/6)). v3 receives security patches only until 2027-01-31 |
| `clickhouse/clickhouse-server` | 26.8.15.10 | Current LTS. Langfuse v4 requires ≥ 25.12 and recommends 26.4. Langfuse's own CI tests 26.4.5.143, but the 26.4 line has had no patch image since 2026-08-06 |
| `redis` | 7.2.16 | Langfuse v4 requires ≥ 7.0 and recommends 7.2 |
| `postgres` | 17.11 | Langfuse v4 requires ≥ 15 (16 recommended); 17 is the upstream compose default and this stack's existing major |
| `cgr.dev/chainguard/minio` | `@sha256:4692462f…d285` | The registry publishes only `latest` / `latest-dev`, so the pin is the index digest of `latest` resolved on 2026-10-02 (MinIO RELEASE.2026-09-22T19-25-18Z) |
| `python` (lab 08 masking sidecar) | 3.12.14-slim | Highest `3.12.<patch>-slim` on Docker Hub on 2026-10-02 |
| `langfuse` (PyPI) | 4.16.0 | Latest Python SDK v4 (2026-09-30); needs Python ≥ 3.10 |
| `anthropic` (PyPI) | 1.11.0 | Optional real model calls; latest on 2026-10-02 |
| `opentelemetry-instrumentation-anthropic` (PyPI) | 0.62.4 | Traces those calls into Langfuse; latest on 2026-10-02 |

How each was confirmed: GitHub releases API and Docker Hub tags for the images, the registry's
tag list and manifest digest for MinIO, PyPI JSON for the Python packages, and Langfuse's
[v3 → v4 upgrade guide](https://langfuse.com/self-hosting/upgrade/upgrade-guides/upgrade-v3-to-v4)
for the minimum versions — all read on 2026-10-01/02.

## Inventory

2 labs and 1 reading page in the README tables; 0 single-language.

## Open work

Tracked as issues, not here: [all open](https://github.com/litkhai/langfuse-hols/issues) ·
[needs a re-run](https://github.com/litkhai/langfuse-hols/issues?q=is%3Aopen+label%3Are-verify).
