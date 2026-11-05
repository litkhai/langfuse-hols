# STATUS.md

**As of 2026-11-05** — `labs/v4/ai-gateway` follow-ups ([#91](https://github.com/litkhai/langfuse-hols/issues/91)): LiteLLM in front of the gateway (12: 6 PASS, fault 5 FAIL; calls recorded twice, the gateway sees one key, caps and fallback hold), the gateway on the Helm chart 2.2.3 on kind with Traefik TLS and two replicas (14: 15 PASS, one replica 2 FAIL; a stream survives its pod's deletion; a first install loses the default model prices until the worker restarts), the LiteLLM image's cosign signature verified, and a lab card (`web: true`). **As of 2026-11-05** — `labs/v4/ai-gateway` compared with LiteLLM Proxy v1.108.0 on the same scenarios ([#89](https://github.com/litkhai/langfuse-hols/issues/89)), steps 07–10: 10-compare-check 17 PASS, fault 2 FAIL; 01–05 re-run in the same run (34 PASS). LiteLLM enforced a spend cap (one call over), a rate limit and a fallback, which the gateway does not have; both restrict models by exact name; LiteLLM's generations in Langfuse carry identity only in metadata (no `user_id`) and are not nested under an app span; LiteLLM rewrites the response `model`. **As of 2026-11-05** — new lab `labs/v4/ai-gateway` (v4 only, [#84](https://github.com/litkhai/langfuse-hols/issues/84)): Langfuse AI Gateway (beta) next to self-hosted Langfuse 4.75.0, as its own compose project on the `_base/` compose file (the v4 pin stays 4.56.0), real Anthropic calls with Claude Haiku 4.5 (0.04 USD for the run): 34 checks PASS, an injected fault failed 3; the EE audit step 2 PASS. Findings: the model allowlist matches exact IDs (an alias of an allowed model gets 403), losing gateway access deletes a person's keys, audit records need the Enterprise licence on a self-hosted instance. **As of 2026-11-05** — `labs/v4/langfuse-k8s` sizes the ClickHouse disk from a stated retention ([#87](https://github.com/litkhai/langfuse-hols/issues/87)): 1,850 GiB per replica = 30 days at 4,000 traces/min (43.1 GiB/day × 30 ÷ 0.7), from `langfuse-ops-checks` test 07 (2026-11-04, ~2.0 KB per observation); the earlier 512 GiB held ~8 days. README gives a 7/30/90-day table. `04-render-clouds.sh` 42 PASS on a fresh kind cluster. **As of 2026-11-04** — `labs/v4/langfuse-k8s` installs entirely from a private registry that needs a login, the pattern of a regulated customer on AKS + ACR ([#83](https://github.com/litkhai/langfuse-hols/issues/83)): `registry:2` with htpasswd and TLS on kind, 14 images and 3 charts mirrored with their digests, nodes cut off from public registries; 05-private-registry.sh 6 PASS (a public image fails, the private one fails without the pull Secret), 03-checks.sh 19 PASS, 06-private-registry-checks.sh 7 PASS (every image and resolved digest from the registry). Chart 2.2.1 has no `global.imageRegistry`: four `repository` keys and three `pullSecrets` keys. ACR itself not run. **As of 2026-11-04** — new lab `labs/v4/langfuse-ops-checks` (v4 only, [#81](https://github.com/litkhai/langfuse-hols/issues/81)): five operations checks on the v4 stack. Blob-storage calls are one PUT + one GET per OTLP POST, changed only by client batching; ClickHouse inserts follow `LANGFUSE_INGESTION_CLICKHOUSE_WRITE_INTERVAL_MS`; `LANGFUSE_TRACE_BATCH_*` is Cloud-only. One 2-CPU web + worker sustained 4,000 traces/min on a laptop (web-bound). A 20 s kill lost 4 / 1,972 / 8 accepted observations (worker / ClickHouse / Redis), all re-processed from blob storage; web and MinIO outages lost data on the client. Per-instance ClickHouse databases work. On 4.75.0 the ClickHouse `audit_logs` table stays empty on self-hosted (relay is Cloud-only). **As of 2026-11-04** — new lab `labs/v4/kong-gateway-otel` (v4 only, [#79](https://github.com/litkhai/langfuse-hols/issues/79)): Kong Gateway OSS 3.9.4 exporting OTLP to the v4 stack, run end to end with a mock model: 18 checks PASS (model gateway, agent gateway and SDK agent in one trace; a Lua bridge turns `ai-proxy` statistics into a generation; header → user/session on every span); an injected propagation fault failed 5 of them. `kong/kong-gateway` 3.14.0.16 without a licence was run for comparison (native Gen AI span). **As of 2026-11-04** — `labs/v4/langfuse-aks` renamed to `labs/v4/langfuse-k8s` ([#77](https://github.com/litkhai/langfuse-hols/issues/77)): one `values-base.yaml` (sizing, placement, ClickHouse 1 × 3, Keeper 3) plus `values-aks.yaml`, `values-eks.yaml` (with `storageclass-eks.yaml`) and `values-gke.yaml`; node pools on the custom label `workload=app|clickhouse`. Run from a deleted kind cluster: `03-checks.sh` 19 PASS on base + kind overlay, `04-render-clouds.sh` 42 PASS (14 per cloud, server-side dry run). Not run on any cloud. **As of 2026-11-03** — new lab `labs/v4/langfuse-aks` (v4 only, [#74](https://github.com/litkhai/langfuse-hols/issues/74)): Helm values for AKS with generous sizing on the official chart langfuse 2.2.1 (Langfuse 4.70.1, ClickHouse 26.8.36.3; clickhouse-operator 0.0.8, cert-manager v1.20.2), verified on a fresh kind cluster (kind 0.33.0, Kubernetes v1.37.0): `03-checks.sh` 19 PASS (placement, wiring, data path, ClickHouse replica and Keeper failover), `04-render-aks.sh` 11 PASS (the AKS file alone, server-side dry run); an injected fault (replicas 3 → 2) failed the render check. Two earlier first installs ended in `Dirty database version 5` (liveness probe killed web mid-migration); fixed with a 300 s liveness delay and a staged first install. Not run on AKS or the Azure managed services. **As of 2026-11-02** — `langfuse-ee` v4 has two more steps (16 SSO: Keycloak OIDC, a SAML IdP behind the broker, enforcement; 17 encryption in transit and at rest), run end to end on the current pins ([#69](https://github.com/litkhai/langfuse-hols/issues/69)). **As of 2026-10-12** — `langfuse-ee` v4 has four more steps (12–15: masking failure modes, project isolation, field encryption, ClickHouse row policies), run end to end on the current pins ([#65](https://github.com/litkhai/langfuse-hols/issues/65)). As of 2026-10-10: the pins are Langfuse v4 4.56.0 and ClickHouse 26.8.22.13, and both tracks were run end to end on them ([#55](https://github.com/litkhai/langfuse-hols/issues/55)). As of 2026-10-08: Langfuse v4 4.53.0 and ClickHouse 26.8.19.9, run end to end ([#49](https://github.com/litkhai/langfuse-hols/issues/49)). As of 2026-10-06: the labs are split into a v3 and a v4 track (`labs/v3/`, `labs/v4/`,

**As of 2026-11-03** — new upgrade lab [`labs/upgrade/langfuse-helm-v3-to-v4`](labs/upgrade/langfuse-helm-v3-to-v4/README.md): Helm chart 1.5.41 → 2.2.1 and Langfuse 3.172.1 → 3.225.15 → 4.72.0 on kind, run end to end ([#73](https://github.com/litkhai/langfuse-hols/issues/73)). **As of 2026-11-02** — `langfuse-ee` v4 has two more steps (16 SSO: Keycloak OIDC, a SAML IdP behind the broker, enforcement; 17 encryption in transit and at rest), run end to end on the current pins ([#69](https://github.com/litkhai/langfuse-hols/issues/69)). **As of 2026-10-12** — `langfuse-ee` v4 has four more steps (12–15: masking failure modes, project isolation, field encryption, ClickHouse row policies), run end to end on the current pins ([#65](https://github.com/litkhai/langfuse-hols/issues/65)). As of 2026-10-10: the pins are Langfuse v4 4.56.0 and ClickHouse 26.8.22.13, and both tracks were run end to end on them ([#55](https://github.com/litkhai/langfuse-hols/issues/55)). As of 2026-10-08: Langfuse v4 4.53.0 and ClickHouse 26.8.19.9, run end to end ([#49](https://github.com/litkhai/langfuse-hols/issues/49)). As of 2026-10-06: the labs are split into a v3 and a v4 track (`labs/v3/`, `labs/v4/`,
[#33](https://github.com/litkhai/langfuse-hols/issues/33)).
As of 2026-10-08: the notes-site export (`docs/labs.json`) publishes all four labs, both tracks
([#56](https://github.com/litkhai/langfuse-hols/issues/56), [#58](https://github.com/litkhai/langfuse-hols/issues/58)). As of 2026-10-03: `docs/labs.json` added. As of 2026-10-02: split out of
[litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols/tree/pre-split-2026-10) with history.

## Verification

Both tracks were run end to end on **2026-10-10** at their current paths, on fresh volumes, with
a real enterprise licence key (Docker 29.8.2, Compose v5.5.1, Python 3.12.14) ([#55](https://github.com/litkhai/langfuse-hols/issues/55)).

| Track | Verified against | Labs | Model calls |
|---|---|---|---|
| v4 — [langfuse-ee](labs/v4/langfuse-ee/README.md), [langfuse-eval](labs/v4/langfuse-eval/README.md) | Langfuse v4.56.0 / SDK 4.17.0 / ClickHouse 26.8.22.13 | `langfuse-ee` 01–11, `langfuse-eval` 01–07 | offline, and real Anthropic `claude-haiku-4-5` for `langfuse-ee` 02 and `langfuse-eval` 04–05 (managed evaluator included) |
| v3 — [langfuse-ee](labs/v3/langfuse-ee/README.md), [langfuse-eval](labs/v3/langfuse-eval/README.md) | Langfuse v3.225.11 / SDK 3.15.0 / ClickHouse 26.8.22.13 | `langfuse-ee` 01–11, `langfuse-eval` 01–07 | offline only; the OpenAI path was not run |

On **2026-10-12**, `langfuse-ee` v4 steps 12–15 were run end to end on the same v4 pins, with the licence key and no model calls except step 14's real `claude-haiku-4-5` judge run (2026-10-13, 9 calls), on existing volumes ([#65](https://github.com/litkhai/langfuse-hols/issues/65)). The rest of the table was not re-run.

On **2026-11-02**, `langfuse-ee` v4 steps 16–17 were run end to end on the same v4 pins plus Keycloak 26.8.1, with the licence key and no model calls, on existing volumes; step 17 puts ClickHouse on its own fresh volume (Docker 29.9.2, Compose v5.6.1) ([#69](https://github.com/litkhai/langfuse-hols/issues/69)). 16: 21 checks PASS. 17: 22 PASS, 3 INFO. The rest of the table was not re-run.

On **2026-11-04**, `labs/v4/kong-gateway-otel` 01–05 were run end to end against the running v4 stack (Langfuse v4.56.0 / SDK 4.17.0 / ClickHouse 26.8.22.13, existing volumes, `events_only`) with Kong Gateway OSS 3.9.4 and, for step 05, `kong/kong-gateway` 3.14.0.16 without a licence; a mock model, no model calls; Docker 29.9.2, Compose v5.6.1 ([#79](https://github.com/litkhai/langfuse-hols/issues/79)). 04: 18 PASS. The rest of the table was not re-run.

On **2026-11-05** (third run), `labs/v4/ai-gateway` 01, 02, 07, 08, 11, 12 on the compose project from deleted volumes, and 13–15 on kind 0.33.0 (one node; cert-manager v1.20.2, clickhouse-operator 0.0.8, Traefik 42.3.0, langfuse chart 2.2.3 / Langfuse 4.75.0, ClickHouse 26.8.36.3 from the chart) from a deleted cluster, with real Anthropic calls (about 0.27 USD) ([#91](https://github.com/litkhai/langfuse-hols/issues/91)). 12: 6 PASS, 2 INFO; 14: 15 PASS; faults: 5 FAIL and 2 FAIL. 13 was run twice on the second cluster (the first pass missed the worker restart, see lab-output.md).

On **2026-11-05** (second run), `labs/v4/ai-gateway` 01–05 and 07–10 were run end to end from deleted volumes: the same pins plus LiteLLM Proxy `ghcr.io/berriai/litellm:v1.108.0` (digest in lab-output.md) and its Postgres 17.11, real Anthropic calls (gateway 0.040 USD, LiteLLM 0.014 USD as Langfuse priced them) ([#89](https://github.com/litkhai/langfuse-hols/issues/89)). 05: 34 PASS, 2 INFO; 10: 17 PASS, 7 INFO; LiteLLM `FAULT=1`: 2 FAIL. 06 was not re-run.

On **2026-11-04**, `labs/v4/langfuse-ops-checks` 01–05 were run end to end ([#81](https://github.com/litkhai/langfuse-hols/issues/81)): 01–04 against the running v4 stack (Langfuse v4.56.0 / SDK 4.17.0 / ClickHouse 26.8.22.13, existing volumes, `events_only`, OSS; 03c with the EE overlay for one step), 05 on Langfuse v4.75.0 with the EE overlay on a throwaway compose project with fresh volumes; no model calls; Docker 29.9.2, Compose v5.6.1. Test 02 ran while other projects' containers shared the Docker VM (recorded per step). The rest of the table was not re-run.

On **2026-11-04**, `labs/v4/langfuse-ops-checks` 06–08 were run end to end ([#81](https://github.com/litkhai/langfuse-hols/issues/81)) on the same pins (Langfuse v4.56.0 / SDK 4.17.0 / ClickHouse 26.8.22.13, OSS): 06 and 07 against the running v4 stack on existing volumes, 08 on a throwaway compose project with fresh volumes (ClickHouse 1 shard × 3 replicas + Keeper 26.8.22.13) while the v4 stack was stopped; HAProxy 3.2.24, OpenTelemetry Collector contrib 0.162.0; no model calls. A kind cluster of another project shared the Docker VM during the first half of 06 (06 counts losses, not timing).

On **2026-11-05**, `labs/v4/ai-gateway` 01–06 were run end to end from deleted volumes as compose project `lf-gateway-lab` (Langfuse v4.75.0 web, worker and `langfuse/ai-gateway` 4.75.0 / SDK 4.17.0 / ClickHouse 26.8.22.13, `events_only`), with real Anthropic API calls (Claude Haiku 4.5, Anthropic SDK 1.12.1, Claude Code 2.1.220; 16 generations, 0.04006 USD as Langfuse priced them); Docker 29.9.2, Compose v5.6.1 ([#84](https://github.com/litkhai/langfuse-hols/issues/84)). 05: 34 PASS, 2 INFO; `FAULT=1`: 3 FAIL; 06 (licence from `_base/.env`): 2 PASS. The shared v4 stack and the rest of the table were not touched or re-run.

On **2026-11-03**, `labs/upgrade/langfuse-helm-v3-to-v4` 01–12 were run end to end on kind 0.33.0 (Kubernetes 1.37.0), Helm 4.3.1, Docker 29.9.2: chart 1.5.41 → 2.2.1, Langfuse 3.172.1 → 3.225.15 → 4.72.0, SDK 3.15.0 and 4.17.0, ClickHouse 25.2.1.3085 → 26.8.36.3, no model calls ([#73](https://github.com/litkhai/langfuse-hols/issues/73)). Step 05 ran as a stopped run plus a resume with `--force`, as its README explains; the committed script passes `--force` from the start and was not re-run that way. The tracks above were not re-run.

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
#44 (`014e82a`), #47 (`8ec4744`), #48 (`c36f1dd`), #51 (`7680dbb`), #52 (`e9a1c3b`), #60 (`5929652`) and #61 (`7d3a6ad`). The workflow runs on pull requests only, not on pushes to `main`.

## Pins

What differs by track is in `_base/<track>/versions.env` and `_base/<track>/requirements.txt`.
The shared images are the `${VAR:-default}` defaults in [`_base/docker-compose.yml`](_base/docker-compose.yml), or
fixed tags and digests there. A run can override any of them without editing a file.

| Pin | v3 | v4 | Why |
|---|---|---|---|
| `langfuse/langfuse`, `langfuse/langfuse-worker` | 3.225.11 | 4.56.0 | Latest release of each major on 2026-10-10 (4.56.0 published 2026-10-09T10:13Z). v3 receives security patches only until 2027-01-31 ([#35](https://github.com/litkhai/langfuse-hols/issues/35)) |
| `clickhouse/clickhouse-server` | 26.8.22.13 | 26.8.22.13 | Newest patch of the current LTS on 2026-10-10 (tag pushed 2026-10-09T14:51Z; the changelogs of 26.8.20–22 list bug-fix and performance backports only). Langfuse v4 requires ≥ 25.12 and recommends 26.4. Langfuse 3.225.11 applies all 37 of its ClickHouse migrations on it, none dirty, in the v3 run's `check.sh` (2026-10-10) |
| `langfuse` (PyPI) | 3.15.0 | 4.17.0 | Latest of each SDK major (2026-05-21, 2026-10-05); both need Python ≥ 3.10 |
| `anthropic`, `opentelemetry-instrumentation-anthropic` (PyPI) | — | 1.12.1, 0.62.4 | v4's optional real calls; latest on 2026-10-10. v3's real-call path uses OpenAI, is not pinned, and is not part of a verification run |
| `cryptography` (PyPI) | — | 50.0.2 | v4 `langfuse-ee` step 14 (AES-GCM field encryption); latest on PyPI on 2026-10-12 (PyPI JSON, uploaded 2026-09-30) |
| `redis` | 7.2.16 | 7.2.16 | Langfuse v4 requires ≥ 7.0 and recommends 7.2 |
| `postgres` | 17.11 | 17.11 | Langfuse v4 requires ≥ 15 (16 recommended); 17 is the upstream compose default and this stack's existing major |
| `cgr.dev/chainguard/minio` | `@sha256:4cf4831a…0034` | same | The registry publishes only `latest` / `latest-dev`, so the pin is the index digest of `latest`, resolved on 2026-10-06 |
| `python` (lab 08 masking sidecar) | 3.12.15-slim | same | Highest `3.12.<patch>-slim` on Docker Hub on 2026-10-06 |
| `quay.io/keycloak/keycloak` (lab 16) | 26.8.1 | same | Newest release tag on quay.io on 2026-11-02 (tag API; `26.8.1-2` rebuilt 2026-10-31) |

How each was confirmed (Langfuse, ClickHouse and the PyPI packages read on 2026-10-10; Redis, Postgres, MinIO and `python` read on 2026-10-06 and not re-checked; Keycloak read on 2026-11-02):

- Langfuse images: GitHub releases API and Docker Hub tags
- the other images: Docker Hub tags
- MinIO: the cgr.dev manifest API
- Keycloak: the quay.io tag API
- Python packages: PyPI JSON

The v4 minimum versions and the v3 support end date come from Langfuse's
[v3 → v4 upgrade guide](https://langfuse.com/self-hosting/upgrade/upgrade-guides/upgrade-v3-to-v4)
(read 2026-10-01/02).

## Inventory

9 labs (2 labs × 2 tracks; `langfuse-k8s`, `kong-gateway-otel`, `langfuse-ops-checks` and `ai-gateway` on v4 only; and the upgrade lab `langfuse-helm-v3-to-v4`) and 1 reading page in the README tables; 0 single-language.

## Open work

Tracked as issues, not here: [all open](https://github.com/litkhai/langfuse-hols/issues) ·
[needs a re-run](https://github.com/litkhai/langfuse-hols/issues?q=is%3Aopen+label%3Are-verify) (none open on 2026-10-10).
Open on 2026-10-10: [#62](https://github.com/litkhai/langfuse-hols/issues/62) (bump `anthropic` 1.12.1 → 1.13.0 with the next pin bump), [#35](https://github.com/litkhai/langfuse-hols/issues/35) (remove the v3 track after 2027-01-31) and
[#12](https://github.com/litkhai/langfuse-hols/issues/12) (revisit D7 past four labs). [#8](https://github.com/litkhai/langfuse-hols/issues/8) (roadmap) was closed as not planned on 2026-10-07.
