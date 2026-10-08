# STATUS.md

**As of 2026-10-08** — the pins are Langfuse v4 4.53.0 and ClickHouse 26.8.19.9, and both tracks were run end to end on them ([#49](https://github.com/litkhai/langfuse-hols/issues/49)). That run includes the lab 11 changes of [#37](https://github.com/litkhai/langfuse-hols/issues/37) and the step-07 `NULL` handling of [#46](https://github.com/litkhai/langfuse-hols/issues/46). As of 2026-10-06: the labs are split into a v3 and a v4 track (`labs/v3/`, `labs/v4/`,
[#33](https://github.com/litkhai/langfuse-hols/issues/33)).
The notes-site export (`docs/labs.json`) now publishes `labs/v4/langfuse-ee`; `labs/v3/` is not
published. As of 2026-10-03: `docs/labs.json` added. As of 2026-10-02: split out of
[litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols/tree/pre-split-2026-10) with history.

## Verification

Both tracks were run end to end on **2026-10-08** at their current paths, on fresh volumes, with
a real enterprise licence key (Docker 29.8.2, Compose v5.5.1, Python 3.12.14) ([#49](https://github.com/litkhai/langfuse-hols/issues/49)).

| Track | Verified against | Labs | Model calls |
|---|---|---|---|
| v4 — [langfuse-ee](labs/v4/langfuse-ee/README.md), [langfuse-eval](labs/v4/langfuse-eval/README.md) | Langfuse v4.53.0 / SDK 4.17.0 / ClickHouse 26.8.19.9 | `langfuse-ee` 01–11, `langfuse-eval` 01–07 | offline, and real Anthropic `claude-haiku-4-5` for `langfuse-ee` 02 and `langfuse-eval` 04–05 (managed evaluator included) |
| v3 — [langfuse-ee](labs/v3/langfuse-ee/README.md), [langfuse-eval](labs/v3/langfuse-eval/README.md) | Langfuse v3.225.11 / SDK 3.15.0 / ClickHouse 26.8.19.9 | `langfuse-ee` 01–11, `langfuse-eval` 01–07 | offline only; the OpenAI path was not run |

The per-lab results are in each lab's README, and the logs in each lab's `lab-output.md`.

## CI

`checks` (on pull requests):

- `links`
- `syntax`
- `compose`, run once per track. Every overlay set merges, carries what its lab needs, and resolves to that track's pins. The base file refuses to resolve without a track.
- `sql`. Each track's `.sql` files parse in that track's ClickHouse image.
- `secrets` (gitleaks)
- `hygiene`

GitHub secret scanning and push protection are on.

Last result: every job green on the heads of #36 (`1a6e4c9`), #38 (`c6ac9a9`), #39 (`d9c55d4`), #42 (`86b72e4`),
#44 (`014e82a`), #47 (`8ec4744`) and #48 (`c36f1dd`). The workflow runs on pull requests only, not on pushes to `main`.

## Pins

What differs by track is in `_base/<track>/versions.env` and `_base/<track>/requirements.txt`.
The shared images are the `${VAR:-default}` defaults in [`_base/docker-compose.yml`](_base/docker-compose.yml), or
fixed tags and digests there. A run can override any of them without editing a file.

| Pin | v3 | v4 | Why |
|---|---|---|---|
| `langfuse/langfuse`, `langfuse/langfuse-worker` | 3.225.11 | 4.53.0 | Latest release of each major on 2026-10-07 (4.53.0 published 2026-10-06T12:27Z). v3 receives security patches only until 2027-01-31 ([#35](https://github.com/litkhai/langfuse-hols/issues/35)) |
| `clickhouse/clickhouse-server` | 26.8.19.9 | 26.8.19.9 | Newest patch of the current LTS on 2026-10-07 (tag pushed 2026-10-06T16:46Z; bug-fix backports only). Langfuse v4 requires ≥ 25.12 and recommends 26.4. Langfuse 3.225.11 applies all 37 of its ClickHouse migrations on it, none dirty, in the v3 run's `check.sh` (2026-10-08) |
| `langfuse` (PyPI) | 3.15.0 | 4.17.0 | Latest of each SDK major (2026-05-21, 2026-10-05); both need Python ≥ 3.10 |
| `anthropic`, `opentelemetry-instrumentation-anthropic` (PyPI) | — | 1.11.0, 0.62.4 | v4's optional real calls; latest on 2026-10-07. v3's real-call path uses OpenAI, is not pinned, and is not part of a verification run |
| `redis` | 7.2.16 | 7.2.16 | Langfuse v4 requires ≥ 7.0 and recommends 7.2 |
| `postgres` | 17.11 | 17.11 | Langfuse v4 requires ≥ 15 (16 recommended); 17 is the upstream compose default and this stack's existing major |
| `cgr.dev/chainguard/minio` | `@sha256:4cf4831a…0034` | same | The registry publishes only `latest` / `latest-dev`, so the pin is the index digest of `latest`, resolved on 2026-10-06 |
| `python` (lab 08 masking sidecar) | 3.12.15-slim | same | Highest `3.12.<patch>-slim` on Docker Hub on 2026-10-06 |

How each was confirmed (Langfuse, ClickHouse and the PyPI packages read on 2026-10-07; Redis, Postgres, MinIO and `python` read on 2026-10-06 and not re-checked):

- Langfuse images: GitHub releases API and Docker Hub tags
- the other images: Docker Hub tags
- MinIO: the cgr.dev manifest API
- Python packages: PyPI JSON

The v4 minimum versions and the v3 support end date come from Langfuse's
[v3 → v4 upgrade guide](https://langfuse.com/self-hosting/upgrade/upgrade-guides/upgrade-v3-to-v4)
(read 2026-10-01/02).

## Inventory

4 labs (2 labs × 2 tracks) and 1 reading page in the README tables; 0 single-language.

## Open work

Tracked as issues, not here: [all open](https://github.com/litkhai/langfuse-hols/issues) ·
[needs a re-run](https://github.com/litkhai/langfuse-hols/issues?q=is%3Aopen+label%3Are-verify) (none open once [#49](https://github.com/litkhai/langfuse-hols/issues/49) closes).
Open on 2026-10-08: [#35](https://github.com/litkhai/langfuse-hols/issues/35) (remove the v3 track after 2027-01-31),
[#12](https://github.com/litkhai/langfuse-hols/issues/12) (revisit D7 past four labs), [#8](https://github.com/litkhai/langfuse-hols/issues/8) (roadmap).
