# STATUS.md

**As of 2026-10-07** — v4 `langfuse-eval` was re-run end to end ([#45](https://github.com/litkhai/langfuse-hols/issues/45)). As of 2026-10-06: the labs are split into a v3 and a v4 track (`labs/v3/`, `labs/v4/`,
[#33](https://github.com/litkhai/langfuse-hols/issues/33)), and both tracks were run end to end on their pins
([#34](https://github.com/litkhai/langfuse-hols/issues/34)). Lab 11 changed after that run ([#37](https://github.com/litkhai/langfuse-hols/issues/37)) and was re-checked alone.
The notes-site export (`docs/labs.json`) now publishes `labs/v4/langfuse-ee`; `labs/v3/` is not
published. As of 2026-10-03: `docs/labs.json` added. As of 2026-10-02: split out of
[litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols/tree/pre-split-2026-10) with history.

## Verification

Both tracks were run end to end on **2026-10-06** at their current paths, on fresh volumes, with
a real enterprise licence key (Docker 29.8.2, Compose v5.5.1, Python 3.12.14).

| Track | Verified against | Labs | Model calls |
|---|---|---|---|
| v4 — [langfuse-ee](labs/v4/langfuse-ee/README.md), [langfuse-eval](labs/v4/langfuse-eval/README.md) | Langfuse v4.52.0 / SDK 4.17.0 / ClickHouse 26.8.18.2 | `langfuse-ee` 01–11, `langfuse-eval` 01–07 | offline, and real Anthropic `claude-haiku-4-5` for `langfuse-ee` 02 and `langfuse-eval` 04–05 (managed evaluator included) |
| v3 — [langfuse-ee](labs/v3/langfuse-ee/README.md), [langfuse-eval](labs/v3/langfuse-eval/README.md) | Langfuse v3.225.11 / SDK 3.15.0 / ClickHouse 26.8.18.2 | `langfuse-ee` 01–11, `langfuse-eval` 01–07 | offline only; the OpenAI path was not run |

The per-lab results are in each lab's README, and the logs in each lab's `lab-output.md`.

**Changed since the end-to-end run.** Lab 11 (`langfuse-ee/11-ee-parquet-export.sh`, both tracks) was
changed after the run ([#37](https://github.com/litkhai/langfuse-hols/issues/37)):

- The schema peek now shows 15 columns with a closed border.
- On v3, the script now compares the source count with the read-back count.

Lab 11 alone was re-run on a fresh EE stack per track. Both tracks behaved the same way:

- On an empty project it exits 1, as the positive control should.
- After seeding 10 traces it passes: `10 == 10` on v3 and `34 == 34` on v4.

That is a targeted check, so the end-to-end claim above still names the 2026-10-06 run.

`langfuse-eval/07-scores-in-clickhouse.sql` section 5 (both tracks) now pivots with
`anyIfOrNull`, so a trace without a `hallucination-check` shows `NULL`, not `0`
([#46](https://github.com/litkhai/langfuse-hols/issues/46)). Step 07 was re-run per track on 2026-10-07:
on v4 against the data of the re-run below, and on v3 after an offline 01–06 on fresh volumes.
Only the error-trace cells changed (two on v4, one on v3). The v3 claim above still names the 2026-10-06 run.

**Re-run since.** v4 `langfuse-eval` 01–07 was run end to end again on **2026-10-07** on the same
pins and fresh volumes, with real `claude-haiku-4-5` calls for 04–05 and the managed evaluator
([#45](https://github.com/litkhai/langfuse-hols/issues/45)). The offline results matched. The
real-model numbers moved but kept their direction: keyword-recall v1 → v2 went from 0.345 → 0.152
to 0.311 → 0.110, and the judge from 0.420 → 0.250 to 0.450 → 0.235. That lab's README and
`lab-output.md` now carry this run.

## CI

`checks` (on pull requests):

- `links`
- `syntax`
- `compose`, run once per track. Every overlay set merges, carries what its lab needs, and resolves to that track's pins. The base file refuses to resolve without a track.
- `sql`. Each track's `.sql` files parse in that track's ClickHouse image.
- `secrets` (gitleaks)
- `hygiene`

GitHub secret scanning and push protection are on.

Last result: every job green on the heads of #36 (`1a6e4c9`), #38 (`c6ac9a9`) and #39 (`d9c55d4`).

## Pins

What differs by track is in `_base/<track>/versions.env` and `_base/<track>/requirements.txt`.
The shared images are the `${VAR:-default}` defaults in [`_base/docker-compose.yml`](_base/docker-compose.yml), or
fixed tags and digests there. A run can override any of them without editing a file.

| Pin | v3 | v4 | Why |
|---|---|---|---|
| `langfuse/langfuse`, `langfuse/langfuse-worker` | 3.225.11 | 4.52.0 | Latest release of each major on 2026-10-06. v3 receives security patches only until 2027-01-31 ([#35](https://github.com/litkhai/langfuse-hols/issues/35)) |
| `clickhouse/clickhouse-server` | 26.8.18.2 | 26.8.18.2 | Newest patch of the current LTS on 2026-10-06. Langfuse v4 requires ≥ 25.12 and recommends 26.4. Langfuse 3.225.11 applies all 37 of its ClickHouse migrations on it, none dirty: first on a throwaway stack, then in the v3 run's `check.sh` (2026-10-06) |
| `langfuse` (PyPI) | 3.15.0 | 4.17.0 | Latest of each SDK major (2026-05-21, 2026-10-05); both need Python ≥ 3.10 |
| `anthropic`, `opentelemetry-instrumentation-anthropic` (PyPI) | — | 1.11.0, 0.62.4 | v4's optional real calls; latest on 2026-10-06. v3's real-call path uses OpenAI, is not pinned, and is not part of a verification run |
| `redis` | 7.2.16 | 7.2.16 | Langfuse v4 requires ≥ 7.0 and recommends 7.2 |
| `postgres` | 17.11 | 17.11 | Langfuse v4 requires ≥ 15 (16 recommended); 17 is the upstream compose default and this stack's existing major |
| `cgr.dev/chainguard/minio` | `@sha256:4cf4831a…0034` | same | The registry publishes only `latest` / `latest-dev`, so the pin is the index digest of `latest`, resolved on 2026-10-06 |
| `python` (lab 08 masking sidecar) | 3.12.15-slim | same | Highest `3.12.<patch>-slim` on Docker Hub on 2026-10-06 |

How each was confirmed (read on 2026-10-06):

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
[needs a re-run](https://github.com/litkhai/langfuse-hols/issues?q=is%3Aopen+label%3Are-verify) (none open on 2026-10-06).
Open on 2026-10-06: [#35](https://github.com/litkhai/langfuse-hols/issues/35) (remove the v3 track after 2027-01-31),
[#12](https://github.com/litkhai/langfuse-hols/issues/12) (revisit D7 past four labs), [#8](https://github.com/litkhai/langfuse-hols/issues/8) (roadmap).
