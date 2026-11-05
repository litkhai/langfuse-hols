# Langfuse AI Gateway (beta) next to self-hosted Langfuse v4: real Anthropic calls, per-person keys, cost per user, key and model

[English](#english) | [한국어](#한국어)

---

## English

**Verified end to end on 2026-11-05** with **Langfuse v4.75.0 web and worker / `langfuse/ai-gateway` 4.75.0 / SDK 4.17.0 / CH 26.8.22.13** (its own compose project on the `_base/` compose file, `events_only` mode), **real calls to the Anthropic API** with Claude Haiku 4.5 (`claude-haiku-4-5-20251001`), Anthropic Python SDK 1.12.1, Claude Code 2.1.220, Docker 29.9.2, Compose v5.6.1, Python 3.12.14: [05-check.py](05-check.py) passed 34 checks (2 INFO); with an injected fault (a service forgets `langfuse-user-id`, an app forgets `traceparent`) 3 of them failed. [06-ee-audit.sh](06-ee-audit.sh) found no audit record without a licence, and `create` and `delete` in Postgres `audit_logs` with the Enterprise licence. Log: [lab-output.md](lab-output.md). All model calls of the run cost 0.04006 USD (16 generations; 0.0397 of it one Claude Code call), as Langfuse priced them.

**Compared with LiteLLM Proxy, verified end to end on 2026-11-05** in a second run from deleted volumes: 01–05 again (05: 34 PASS, 2 INFO) and steps 07–10 with **LiteLLM Proxy v1.108.0** (`ghcr.io/berriai/litellm:v1.108.0`) on the same Langfuse project, Anthropic key, people and key metadata: [10-compare-check.py](10-compare-check.py) passed 17 checks (7 INFO); with an injected fault (a service forgets `x-litellm-end-user-id`, an app forgets `traceparent`) 2 of them failed. 06 was not re-run in the second run. Model calls of the second run: gateway 0.040 USD, LiteLLM 0.014 USD. See [Compared with LiteLLM Proxy](#compared-with-litellm-proxy).

**Follow-ups verified on 2026-11-05** ([#91](https://github.com/litkhai/langfuse-hols/issues/91)): LiteLLM in front of the gateway ([12-chain-check.py](12-chain-check.py) 6 PASS, 2 INFO; a wrong upstream key fails 5), the gateway through the Helm chart 2.2.3 on kind with Traefik TLS and two replicas ([14-helm-check.py](14-helm-check.py) 15 PASS; one replica fails 2), and the cosign signature of the LiteLLM image (verified; the rotated-out key does not verify). Model calls of the follow-ups: about 0.27 USD at Claude Haiku 4.5 list prices, most of it two 8,000-token streams and four Claude Code calls. See [LiteLLM in front of the gateway](#litellm-in-front-of-the-gateway) and [On Helm with TLS and two replicas](#on-helm-with-tls-and-two-replicas).

The gateway went into public beta with Langfuse v4.75.0 (released 2026-11-04). Apps and coding agents send their OpenAI or Anthropic requests to the gateway with a gateway key; the gateway swaps in the organization's provider key, forwards the request unchanged, and records the call as a Langfuse generation.

### The short answer

| Claim | What the run showed |
|---|---|
| Only the base URL and the API key change | **Yes.** The Anthropic SDK with `base_url=<gateway>/anthropic` and a gateway key got Anthropic's own response (Anthropic `request-id`, dated model, usage), streaming included. `claude -p` worked with `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN`. |
| No shared provider keys | **Yes.** The provider key lives once, encrypted, in Postgres (`gateway_ai_connections`); the gateway container has none in its environment; it gets the key from web per request. Gateway keys are Langfuse API keys (`sk-lf-…`) with the role `AI_GATEWAY`, stored hashed. |
| Cost per user, key and model | **Yes.** Every generation carries user, key name, key ID and the key's metadata (`team`, `cost_center`) next to model, usage and cost. One `GROUP BY` over `events_full` gives the table the gateway's Analytics page shows. A user key always records its owner: a `langfuse-user-id` header is ignored. A service account key takes the end user from that header, or falls back to the key name. |
| Tracing for apps you cannot instrument | **Yes, in `FULL` mode:** input and output are stored. **`USAGE` mode** (the default) stores model, usage, cost and latency without input or output. |
| Model allowlist | **Works, by exact ID.** With only `claude-haiku-4-5-20251001` allowed, the model list shows only it and other models get `403`. The alias `claude-haiku-4-5` of the same model **also gets `403`**: the check compares strings. |
| Key expiry, revocation | **Immediate.** An expired key got `401` on the first call after `expiresAt`; a revoked key on the first call after revoke (web evicts it from the resolve cache). |
| Losing gateway access | **Deletes the person's keys.** Changing a member's role to VIEWER made their key fail on the next call, and the key row was gone. Changing the role back does not bring it back; they issue a new key. |
| Audit logging | **Enterprise only on self-hosted.** Without a licence no audit record is written for key creation or revocation; with the licence both are recorded. On Langfuse Cloud the code always writes them (source, not tested here). |
| SDK trace + gateway | **One trace.** With `traceparent` from a Langfuse SDK span, the gateway's generation got the app's trace ID and the app span as its parent. |

### What runs

```mermaid
flowchart LR
  dev["alice, bob<br/>Anthropic SDK, Claude Code<br/>user keys"] -->|"base URL + gateway key"| gw
  svc["checkout-service<br/>service account key<br/>langfuse-* headers, traceparent"] -->|"base URL + gateway key"| gw
  gw["ai-gateway :18480<br/>langfuse/ai-gateway 4.75.0<br/>stateless"] -->|"resolve key<br/>(shared service key)"| web["Langfuse web :13000<br/>4.75.0"]
  web -->|"provider key, ingestion grant"| gw
  gw -->|"x-api-key: provider key"| an["api.anthropic.com"]
  gw -.->|"generation (OTLP, upload token)"| web
  web --> wk["worker"] --> ch["ClickHouse :18423<br/>events_full"]
  web --> pg["Postgres<br/>provider key encrypted<br/>gateway keys hashed"]
```

| File | Does |
|---|---|
| [docker-compose.yml](docker-compose.yml) | Overlay on `_base/docker-compose.yml`: web and worker with the gateway variables, the `ai-gateway` container, host ports 13000 (web), 18480 (gateway), 18423 (ClickHouse HTTP); the other backends publish nothing |
| [lib.sh](lib.sh) | `lab_compose`: the `_base` files plus the overlay as compose project `lf-gateway-lab`, Langfuse pinned to 4.75.0 for this project only |
| [lablib.py](lablib.py) | NextAuth login and tRPC calls as the UI makes them, ClickHouse and Postgres queries, `.run/state.json` |
| [01-up.sh](01-up.sh) | Generates the gateway service key and the ES256 signing key into `.run/` once, starts the project, waits for web `/api/public/health` and gateway `/health`, `/ready` |
| [02-setup.py](02-setup.py) | Admin setup: two developers with the AI Gateway role, ingestion project and `FULL` mode, the Anthropic credential `anthropic-lab`, three gateway keys with metadata |
| [03-calls.py](03-calls.py) | Seven scenarios with real calls (below). `FAULT=1` injects the fault, `SKIP_CLAUDE_CODE=1` leaves out `claude -p` |
| [04-controls.py](04-controls.py) | Allowlist, expiry, revocation, role change, `USAGE` mode, and what the AI Gateway role may not do |
| [05-check.py](05-check.py) | 34 checks against ClickHouse, Postgres, the gateway container and the v2 observations API |
| [06-ee-audit.sh](06-ee-audit.sh) · [06-audit-probe.py](06-audit-probe.py) | Optional: a key created and revoked without and with the Enterprise licence, audit records counted |
| [docker-compose.litellm.yml](docker-compose.litellm.yml) · [litellm-config.yaml](litellm-config.yaml) | LiteLLM Proxy and its Postgres in the same project, behind the profile `litellm` (host port 18440); models `claude-haiku-4-5`, `claude-haiku-4-5-20251001` and `haiku-broken` (a rejected key, for the fallback), callback `langfuse_otel` |
| [07-litellm-up.sh](07-litellm-up.sh) | Generates LiteLLM's master and salt keys into `.run/` once and starts it |
| [08-litellm-setup.py](08-litellm-setup.py) | The same people and keys on LiteLLM: internal users alice and bob, team `payments`, keys `alice-laptop`, `bob-laptop`, service account key `checkout-service`, same metadata |
| [09-litellm-calls.py](09-litellm-calls.py) | The seven calls against LiteLLM (l1–l7), then model restriction, expiry, key delete, user delete, spend cap, rate limit, fallback, and latency against a direct call. `FAULT=1` injects the fault |
| [10-compare-check.py](10-compare-check.py) | 17 checks on LiteLLM's side (its generations in Langfuse, its database and container) plus INFO rows for the comparison |
| [11-chain.py](11-chain.py) · [12-chain-check.py](12-chain-check.py) | LiteLLM's model `haiku-via-gateway` calls the gateway with a gateway service account key; plain call, client headers, spend cap, fallback; 12 pairs each LiteLLM generation with the gateway's and checks both |
| [helm/](helm/) | `kind-config.yaml` (one node, 443 → 127.0.0.1:18443), `values.yaml` (chart values: gateway on, 2 replicas, Traefik Ingress with TLS, small resources), `traefik-values.yaml` (620 s timeouts) |
| [13-helm-up.sh](13-helm-up.sh) | kind cluster `lf-gateway-helm`, cert-manager v1.20.2, clickhouse-operator 0.0.8, Traefik 42.3.0, a self-signed CA, secrets into `.run/`, chart 2.2.3; restarts the worker once if it missed the default model prices |
| [14-helm-check.py](14-helm-check.py) | 15 checks: what the chart deployed, TLS with and without the CA, SDK and Claude Code over HTTPS, pricing, a stream whose pod is deleted, a rolling restart, a pod deleted under traffic. `FAULT=1` runs on one replica |
| [15-helm-down.sh](15-helm-down.sh) | Deletes the kind cluster; `--purge` also removes its secrets, CA and state in `.run/` |
| [lab.yaml](lab.yaml) | Publishing keys: a card on the notes site (`web: true`, owner's choice 2026-11-05) |
| [99-down.sh](99-down.sh) | Stops the project; `--purge` also removes its volumes and `.run/` |

| Scenario | Key | What it shows |
|---|---|---|
| s1 sdk-basic | alice (user) | Anthropic SDK, only `base_url` and `api_key` changed |
| s2 sdk-stream | alice (user) | `stream=True`, model ID with the credential prefix `anthropic-lab:` |
| s3 user-key-override | bob (user) | `langfuse-user-id: mallory@example.com` is ignored for a user key |
| s4 service-end-user | checkout-service | end user, session, environment, tags, metadata and trace name from `langfuse-*` headers |
| s5 service-default | checkout-service | no headers: the key name becomes the user |
| s6 sdk-traceparent | checkout-service | a Langfuse SDK span injects `traceparent`; the generation joins that trace |
| s7 claude-code | alice (user) | `claude -p` with `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN`, a fresh `CLAUDE_CONFIG_DIR` |

### Run

Needs `ANTHROPIC_API_KEY` in `_base/.env` (or `LF_ENV_FILE`): the gateway always calls `api.anthropic.com` and `api.openai.com`, so there is no mock. The calls use `max_tokens` 10 or less.

```bash
labs/v4/ai-gateway/01-up.sh
.venv-v4/bin/python labs/v4/ai-gateway/02-setup.py
.venv-v4/bin/python labs/v4/ai-gateway/03-calls.py
.venv-v4/bin/python labs/v4/ai-gateway/04-controls.py
.venv-v4/bin/python labs/v4/ai-gateway/05-check.py
labs/v4/ai-gateway/06-ee-audit.sh                    # optional: needs LANGFUSE_EE_LICENSE_KEY
labs/v4/ai-gateway/07-litellm-up.sh                  # LiteLLM comparison, after 01–05
.venv-v4/bin/python labs/v4/ai-gateway/08-litellm-setup.py
.venv-v4/bin/python labs/v4/ai-gateway/09-litellm-calls.py
.venv-v4/bin/python labs/v4/ai-gateway/10-compare-check.py
.venv-v4/bin/python labs/v4/ai-gateway/11-chain.py      # LiteLLM in front of the gateway, after 07–08
.venv-v4/bin/python labs/v4/ai-gateway/12-chain-check.py
labs/v4/ai-gateway/13-helm-up.sh                     # Helm on kind; independent of the compose project
.venv-v4/bin/python labs/v4/ai-gateway/14-helm-check.py
labs/v4/ai-gateway/15-helm-down.sh                   # --purge also removes the Helm secrets and CA
labs/v4/ai-gateway/99-down.sh                        # --purge removes the volumes and .run/
```

The UI is at http://localhost:13000 (the headless-init user of `_base/.env`): **Organization settings → AI Gateway** has Setup, Models, Gateway keys and Analytics. `LF_ENV_FILE=<path>` points the scripts at another clone's `_base/.env`. The shared stack on :3000 can keep running; this project shares nothing with it.

### Self-hosting: what the gateway needs

- **Langfuse ≥ 4.75.0** for web and gateway, the same version for both. Not in `legacy` write mode: gateway generations are stored only in the v4 tables.
- **On web:** `LANGFUSE_AI_GATEWAY_DEPLOYED=true` (otherwise the UI says the gateway is not deployed), `LANGFUSE_AI_GATEWAY_PUBLIC_URL` (shown in the UI and the setup snippets), `LANGFUSE_AI_GATEWAY_SERVICE_KEY`, `LANGFUSE_AI_GATEWAY_JWT_PRIVATE_KEY` (ES256 PEM; `openssl ecparam -name prime256v1 -genkey -noout`), and `ENCRYPTION_KEY`, which encrypts the provider keys. Changing it makes stored provider keys unreadable.
- **On the gateway:** `LANGFUSE_AI_GATEWAY_WEB_URL`, the same service key, and `LANGFUSE_AI_GATEWAY_ALLOW_HTTP_WEB_URL=true` when web is reached over plain http (only on a private network: web's answers carry the provider key).
- **Supported path: the Helm chart** (`langfuse.gateway.enabled: true`, chart after 2.2.0). The Docker Compose file of Langfuse does not ship the gateway; this lab adds it the way the self-hosting page describes for other setups. It ran read-only, with all capabilities dropped and as non-root.
- **TLS:** the gateway does not terminate TLS. Put it behind a proxy or load balancer with timeouts above 120 s (600 s for the longest streams), no response buffering and a 16 MiB body limit. This lab used plain http on localhost; `claude -p` accepted that.
- **Egress:** the gateway and web call the official provider URLs directly and ignore `HTTP(S)_PROXY`. Azure OpenAI, Amazon Bedrock and internal LLM proxies are not supported in the beta.
- **No licence needed** for the gateway itself on a self-hosted instance (it is enabled for every organization unless `LANGFUSE_AI_GATEWAY_ENABLED` says otherwise); the code is under the MIT part of the repository (`ai-gateway/`, `web/src/features/ai-gateway/`).

### What arrives

One generation per model call, named after the API format (`anthropic.messages`), from `service_name = langfuse-ai-gateway`, ingested over OTLP with the gateway key as `ingestion_api_key`. From s4 (FULL mode):

| Field | Value |
|---|---|
| `provided_model_name` | `claude-haiku-4-5-20251001` (requested `claude-haiku-4-5`, kept as `langfuse.gateway.model.requested`) |
| `usage_details` / `cost_details` | input 15, output 5 tokens · 0.000015 + 0.000025 = 0.00004 USD |
| `user_id` · `session_id` · `environment` · `tags` · `trace_name` | `end-user-42` · `checkout-<run>` · `production` · `checkout, beta` · `checkout-summary` |
| `input` / `output` | the request's `messages` and the assistant message with `stop_reason` |
| metadata | `langfuse.gateway.api_key.{id,name}`, `langfuse.gateway.api_key.metadata.{team,cost_center}`, `langfuse.gateway.connection.{id,name,provider}`, `langfuse.gateway.user_id_source` (`api_key_owner`, `client` or `api_key_name`), `langfuse.gateway.ingestion.mode`, `langfuse.gateway.request.id`, `langfuse.gateway.upstream.request.id` (Anthropic's `request-id`), body sizes, status codes, client user agent; the request's own `langfuse-metadata` keys (`order`, `region`) |

Response headers: `langfuse-trace-id`, `langfuse-observation-id`, `langfuse-request-id`, `langfuse-provider`, plus Anthropic's own `request-id`.

Cost per user, key and model, straight from ClickHouse:

```sql
SELECT user_id,
       metadata_values[indexOf(metadata_names, 'langfuse.gateway.api_key.name')]         AS key_name,
       metadata_values[indexOf(metadata_names, 'langfuse.gateway.api_key.metadata.team')] AS team,
       provided_model_name AS model, count() AS calls, round(sum(total_cost), 6) AS cost_usd
FROM events_full FINAL
WHERE project_id = 'llm-observability' AND has(metadata_names, 'langfuse.gateway.api_key.id')
GROUP BY user_id, key_name, team, model
ORDER BY cost_usd DESC
```

| user | key | team | model | calls | cost (USD) |
|---|---|---|---|---:|---:|
| alice@example.com | alice-laptop | platform | claude-haiku-4-5-20251001 | 7 | 0.039835 |
| bob@example.com | bob-laptop | data | claude-haiku-4-5-20251001 | 3 | 0.000066 |
| *(empty)* | checkout-service | payments | claude-haiku-4-5-20251001 | 1 | 0.000040 |
| checkout-service | checkout-service | payments | claude-haiku-4-5-20251001 | 1 | 0.000040 |
| end-user-42 | checkout-service | payments | claude-haiku-4-5-20251001 | 1 | 0.000040 |
| bob@example.com | bob-temp | data | claude-haiku-4-5-20251001 | 2 | 0.000026 |
| alice@example.com | alice-short | platform | claude-haiku-4-5-20251001 | 1 | 0.000013 |

Alice's 0.0398 USD is almost all the single Claude Code call: Claude Code sends a ~119 KB request (system prompt and 24 tool definitions), for which Anthropic reported 31,590 prompt-cache write tokens. The empty user is s6: inside an app's own trace the gateway keeps the user of the app's spans, and that span set none. The same numbers appear on **Organization settings → AI Gateway → Analytics**, which leaves service account keys out of its per-user charts.

### Controls, measured

| Control | Test | Result |
|---|---|---|
| Allowlist | credential allows only `claude-haiku-4-5-20251001` | model list shows only that ID; `claude-haiku-4-5-20251001` and `anthropic-lab:claude-haiku-4-5-20251001` → 200; `claude-sonnet-4-5-20250929` → **403** `permission_error: Model is not allowed for this provider connection`; the alias `claude-haiku-4-5` → **403** as well; after *Enable all* the alias → 200 |
| Expiry | user key with `expiresAt` = creation + 40 s | 200 before; **401** on the first call after `expiresAt` (0.1 s later) |
| Revocation | key used twice (cached lookup), then revoked | **401** on the first call after revoke |
| Role change | bob AI_GATEWAY → VIEWER → AI_GATEWAY | 401 on the next call; his key row was **deleted**; after the role came back the old key stayed 401 and a newly issued key → 200 |
| Ingestion mode | one call in `USAGE` | usage and cost recorded, `input` and `output` empty, `langfuse.gateway.ingestion.mode = usage` |
| Role scope | a member with the AI Gateway role calls `createConnection` | **403 FORBIDDEN** |
| Audit log | create + revoke a key, without and with the EE licence | none without; `create`, `delete` in Postgres `audit_logs` with it |

Expiry, revocation and the role change did not wait for the 60 s resolve cache: web evicts the key on revoke and on the role change, and caps a cached lookup at the key's `expiresAt`. Config and credential changes evict the organization's entries too. A role change only stops the key because Langfuse deletes it.

### Compared with LiteLLM Proxy

Same questions, same Anthropic key, same people and key metadata, same Langfuse project; LiteLLM exports its generations with `langfuse_otel` (OTel v2, `llm_only`, message content on). Measured on 2026-11-05.

| Question | Langfuse AI Gateway 4.75.0 | LiteLLM Proxy v1.108.0 |
|---|---|---|
| Client change | base URL + key; SDK, streaming, `claude -p` worked | the same (`/v1/messages`) |
| Response body | relayed unchanged (`model: claude-haiku-4-5-20251001`) | rewritten: `model` is the requested name `claude-haiku-4-5` |
| Where the provider key lives | encrypted in Langfuse's Postgres; the gateway has none | in the proxy (here its environment; LiteLLM can also keep it in its database, not tested) |
| Client keys at rest | hashed | hashed |
| Who the call belongs to | Langfuse `user_id` = key owner; a header cannot change it | key owner (`user_api_key_user_id`) cannot be changed; the client sets an end user (`x-litellm-end-user-id`); both only in metadata, Langfuse `user_id` empty on 27 of 27 |
| Key, team, tags in Langfuse | key name, key metadata, `langfuse-*` headers | key alias, team, end user, `x-litellm-tags` |
| Sessions | from the agent (`claude-code:<id>`) or a header | Claude Code's session id; empty otherwise |
| `traceparent` from an app span | same trace, **child of the app span** | same trace, **no parent** (flat) |
| Model restriction | exact ID: the alias gets `403` | exact name: the alias gets `403 key_model_access_denied` |
| Expiry, revocation | `401` on the next call | `401` on the next call |
| Person leaves | role change deletes their user keys | user delete deletes their keys |
| Spend cap | none | `max_budget` 0.00006 USD: refused on call 6 with `422 budget_exceeded` at 0.000065 (one call over) |
| Rate limit | none on self-hosted | `rpm_limit: 2`: `[200, 200, 429]` |
| A failing model | error goes to the client (`404`), no fallback setting | `fallbacks`: answered from the next model, `x-litellm-attempted-fallbacks: 1` |
| Providers | OpenAI, Anthropic | 100+ by its docs (only Anthropic run here) |
| Audit log without a licence | none (Enterprise) | none (`LiteLLM_AuditLog` 0 rows; Enterprise by its docs) |
| Latency, median of 5 after a warm-up | 526 ms | 547 ms (a direct call on a new connection: 610 ms) |
| Extra infrastructure | one stateless container next to Langfuse | the proxy and its own Postgres |
| Cost in Langfuse | priced by Langfuse's model table | LiteLLM's own cost, sent as provided cost |

Both gateways were faster than the direct call because they reuse their upstream connection; the direct sample opened a new one each time. With 5 calls on one host, the 21 ms between the gateways is within noise.

**What follows from it** (*recommendation*):
- Needs spend caps, rate limits, fallbacks or providers beyond OpenAI and Anthropic: LiteLLM has them today; the Langfuse gateway does not.
- Wants the trace to be the record (user field, nesting under the app span, the provider's response unchanged, evaluations on it): the Langfuse gateway gives that without extra work.
- Both, LiteLLM in front with `langfuse_otel`: caps, limits and fallbacks from LiteLLM, generations in Langfuse; but identity sits in metadata (filter on `user_api_key_*`, the Users view stays empty) and the generation is not nested under the app span.
- Pin LiteLLM by version or digest and verify its cosign signature: on 2026-10-21 its release pipeline was compromised, and credential-stealing malware shipped as `litellm==1.107.0` on PyPI for about 2 hours and in the Docker tags `v1.107.0`, `latest`, `main-latest` and `main-stable` for about 2.5 hours (LiteLLM's incident report). Its repository published 18 GitHub security advisories in 2026 up to 2026-11-05, 5 of them critical; the Langfuse repository published 2. Counts of published advisories are not a security rating; they say how often to plan upgrades.

### LiteLLM in front of the gateway

LiteLLM's model `haiku-via-gateway` points its Anthropic route at the gateway (`api_base: http://ai-gateway:8080/anthropic`; LiteLLM appends `/v1/messages`) with a gateway service account key `litellm-upstream`; clients keep their LiteLLM virtual keys. Measured on 2026-11-05:

| Question | Result |
|---|---|
| Does it answer | `200`; the response `model` is LiteLLM's name `haiku-via-gateway` |
| LiteLLM's spend cap | the second call on a 0.00004 USD key got `422`; the refused call never reached the gateway |
| Fallback `haiku-broken-chain` → `haiku-via-gateway` | `200`, `x-litellm-attempted-fallbacks: 1`, recorded by the gateway |
| Records per call | **two**, LiteLLM's and the gateway's, in separate traces (LiteLLM sends no `traceparent` upstream), so the project counts the cost twice |
| Who the gateway sees | one identity for every caller: the key `litellm-upstream` (user source `api_key_name`) |
| Client headers | `langfuse-user-id` is not forwarded (LiteLLM forwards `x-` headers only); `x-pass-langfuse-user-id` and `x-pass-langfuse-tags` did not arrive on `/v1/messages` either |
| A wrong upstream key | the first call `401`; LiteLLM then cooled the deployment down and answered `429 No deployments available` (fault run) |

**What follows from it** (*recommendation*): chain them only when you need LiteLLM's caps and fallbacks and also want the provider key out of LiteLLM. Then turn off one of the two Langfuse exports, or send them to different projects, and attribute people from LiteLLM's metadata: the gateway sees only LiteLLM's key.

### On Helm with TLS and two replicas

The supported self-hosted path, on a local kind cluster: kind 0.33.0 (one node), cert-manager v1.20.2 and clickhouse-operator 0.0.8 (the chart's ClickHouse runs on the operator), Traefik 42.3.0 (v3.7.17) as the TLS front, the langfuse chart 2.2.3 (Langfuse 4.75.0) with [helm/values.yaml](helm/values.yaml): `langfuse.gateway.enabled: true`, `replicas: 2`, an Ingress with TLS on `gateway.127.0.0.1.nip.io`. Langfuse's page shows ingress-nginx annotations; ingress-nginx was retired in March 2026 (Kubernetes' announcement; the repository is archived, last push 2026-03-23), so Traefik takes the long timeouts on its entrypoint (`620s`) and does not buffer responses. Measured on 2026-11-05, from a deleted cluster:

| Check | Result |
|---|---|
| What the chart deploys | gateway Deployment with 2 replicas, Service, Ingress, PDB `maxUnavailable: 1`, `terminationGracePeriodSeconds: 350`; web gets `LANGFUSE_AI_GATEWAY_DEPLOYED=true` and the public URL; the gateway reaches web on its in-cluster Service over http (`LANGFUSE_AI_GATEWAY_ALLOW_HTTP_WEB_URL=true`) |
| TLS | `/health` with the lab CA `200`; without it `CERTIFICATE_VERIFY_FAILED` |
| Clients over HTTPS | Anthropic SDK with the CA (anthropic 1.12.1 runs on httpx2: pass `anthropic.DefaultHttpxClient(verify=…)`; an `httpx.Client` is refused); `claude -p` fails without `NODE_EXTRA_CA_CERTS` and works with it |
| The pod serving a stream is deleted | the stream ran 49.5 s more and finished (8,000 tokens); the pod logged `gateway draining`; the generation was recorded |
| Rolling restart | new pods ready after 16.4 s, old pods gone after 28.9 s |
| A pod deleted under traffic | 20 of 20 calls `200` |
| One replica (fault run) | deleting the only pod: 14 of 20 calls `503` until the new pod was ready |
| Pricing on a first install | the worker started before Postgres answered, logged `Error upserting default model prices` and did not retry: 87 model rows, none for `claude-haiku-4-5`, every cost 0. A worker restart loaded them (188 rows) and costs appeared; 13-helm-up.sh now does that. Seen on both fresh installs |

A short stream finishes inside the 10 s `preStop` sleep, before the pod even gets `SIGTERM`; the 8,000-token stream outlived it and was carried by the drain.

### Image signature (LiteLLM)

`cosign verify` (cosign v3.1.4) of `ghcr.io/berriai/litellm@sha256:c560d317…` against `cosign.pub` at LiteLLM commit `e82a3c6`: verified. The key file's SHA-256 equals the fingerprint LiteLLM's docs publish (`e3fe3e08…`). Negative control: the key from before the October rotation (commit `0112e53`) gives `no matching signatures`.

### Gaps

- **Allowlists match strings, not models.** The provider's model list gives dated IDs for older models (`claude-haiku-4-5-20251001`) and undated ones for newer models. Clients that send an alias get `403` once a credential has an explicit list, so allow the IDs your clients actually send, or tell clients to send the listed ID.
- **Losing gateway access deletes keys.** A role change to VIEWER (or NONE) removes the person's user keys at once. Restoring the role does not restore them. Use service account keys for anything that must survive membership changes.
- **Audit records need the Enterprise licence on a self-hosted instance** (`isAuditLogEnabled`: Cloud always, self-hosted only with the `audit-logs` entitlement). Without it, key creation and revocation leave no trace.
- **The OpenAI route was not run** (no OpenAI key). Responses, Chat Completions, Codex and Copilot are documented by Langfuse but not tested here.
- **LiteLLM, not run:** its Enterprise features (SSO beyond 5 users, audit logs, per-key guardrails), Redis and more than one proxy instance, credentials stored in its database, budgets on users and teams, long streams and failures on LiteLLM's side.
- **Not run:** the Helm chart on a cloud cluster, the HPA, certificates from cert-manager, the memory budget and `503` under load, Claude Desktop, turn grouping for Claude Code (`CLAUDE_CODE_PROPAGATE_TRACEPARENT`), `NONE` mode, Langfuse Cloud and its rate limits.
- **Known beta cost bugs** (Langfuse's list, not reproduced here): estimated cost on failed or cancelled OpenAI calls, OpenAI cache writes at $0, Anthropic 1-hour cache writes at the 5-minute rate. Input over 5 MiB is not stored; output over 1 MiB is cut in the record.
- **Analytics loses the names of deleted keys.** Keys that were revoked or removed by a role change show up as raw IDs in *Cost by gateway key*; the name stays in each generation's `langfuse.gateway.api_key.name`, so a ClickHouse query still has it.
- **Key metadata is fixed at creation.** To change `team` or `cost_center`, issue a new key and revoke the old one.
- **One trace per model call** for Claude Code by default (s7: one call, one trace, session `claude-code:<id>`); use sessions or turn grouping.
- **Generic names:** every generation is `anthropic.messages`; set `langfuse-trace-name` per call when you want something else.

### Sources (all read 2026-11-04)

- Langfuse: [AI Gateway overview](https://langfuse.com/docs/gateway/overview) · [Concepts](https://langfuse.com/docs/gateway/concepts) · [Set up as an admin](https://langfuse.com/docs/gateway/get-started/admin-setup) · [Send your first request](https://langfuse.com/docs/gateway/get-started/first-request) · [Authentication (keys)](https://langfuse.com/docs/gateway/features/api-keys) · [Model management](https://langfuse.com/docs/gateway/features/models) · [Tracing](https://langfuse.com/docs/gateway/features/tracing) · [REST API](https://langfuse.com/docs/gateway/features/rest-api) · [Analytics](https://langfuse.com/docs/gateway/features/analytics) · [Known limitations](https://langfuse.com/faq/all/ai-gateway-known-limitations) · [Self-hosting the AI Gateway](https://langfuse.com/self-hosting/configuration/ai-gateway) · [Claude Code with the gateway](https://langfuse.com/integrations/developer-tools/claude-code-gateway)
- Helm and the TLS front (read 2026-11-05): [langfuse chart](https://github.com/langfuse/langfuse-k8s) 2.2.3 values · [Traefik chart](https://github.com/traefik/traefik-helm-chart) 42.3.0 · [Ingress NGINX retirement](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/) and the [archived repository](https://github.com/kubernetes/ingress-nginx) · [LiteLLM: forward client headers](https://docs.litellm.ai/docs/proxy/forward_client_headers)
- LiteLLM (read 2026-11-05): [docs index](https://docs.litellm.ai/llms.txt) · [Virtual keys](https://docs.litellm.ai/docs/proxy/virtual_keys) · [Budgets, rate limits](https://docs.litellm.ai/docs/proxy/users) · [Customers / end users](https://docs.litellm.ai/docs/proxy/customers) · [Fallbacks](https://docs.litellm.ai/docs/proxy/reliability) · [Claude Code](https://docs.litellm.ai/docs/proxy/client_setup/claude_code) · [OpenTelemetry v2, `langfuse_otel`](https://docs.litellm.ai/docs/observability/opentelemetry_v2) · [Audit logs](https://docs.litellm.ai/docs/proxy/audit_logs) · [Docker image security](https://docs.litellm.ai/docs/proxy/docker_image_security) · [Oct 21, 2026 incident](https://docs.litellm.ai/blog/security-incident-oct-21-2026) · [security advisories](https://github.com/BerriAI/litellm/security/advisories) · [releases](https://github.com/BerriAI/litellm/releases) (v1.108.0, 2026-11-04)
- Release and image: [langfuse v4.75.0](https://github.com/langfuse/langfuse/releases/tag/v4.75.0) (2026-11-04) · [`langfuse/ai-gateway` on Docker Hub](https://hub.docker.com/r/langfuse/ai-gateway) (tag 4.75.0)
- Source read at v4.75.0: `ai-gateway/src/resolution/contracts.rs` (official provider origins), `ai-gateway/src/providers/mod.rs` (origin override only in tests), `web/src/features/ai-gateway/server/router.ts` (tRPC control plane), `web/src/features/ai-gateway/fns/isGatewayModelAllowed.ts` (exact match), `web/src/features/ai-gateway/server/apiKey/{gatewayApiKeyService,userBoundApiKeys}.ts` (revoke, delete on role change), `web/src/features/ai-gateway/server/availability.ts`, `web/src/features/audit-logs/isAuditLogEnabled.ts`

---

## 한국어

**2026-11-05 처음부터 끝까지 검증.** 대상은 **Langfuse v4.75.0 web·worker / `langfuse/ai-gateway` 4.75.0 / SDK 4.17.0 / CH 26.8.22.13**(`_base/` compose 파일 위의 별도 compose 프로젝트, `events_only` 모드)이고, Claude Haiku 4.5(`claude-haiku-4-5-20251001`)로 **Anthropic API를 실제로 호출**했습니다(Anthropic Python SDK 1.12.1, Claude Code 2.1.220, Docker 29.9.2, Compose v5.6.1, Python 3.12.14). [05-check.py](05-check.py)는 34개 검사를 통과했습니다(INFO 2개). 결함을 넣으면(서비스가 `langfuse-user-id`를, 앱이 `traceparent`를 빠뜨림) 그중 3개가 실패합니다. [06-ee-audit.sh](06-ee-audit.sh)는 라이선스 없이는 감사 기록이 없고, Enterprise 라이선스가 있으면 Postgres `audit_logs`에 `create`와 `delete`가 남는 것을 확인했습니다. 로그: [lab-output.md](lab-output.md). 이 실행의 모델 호출 비용은 Langfuse 계산으로 0.04006 USD였습니다(generation 16개, 그중 0.0397은 Claude Code 호출 한 번).

**LiteLLM Proxy와의 비교도 2026-11-05 처음부터 끝까지 검증했습니다.** 볼륨을 지우고 다시 돌린 두 번째 실행에서 01–05를 다시 돌렸고(05: 34 PASS, INFO 2개), 07–10단계로 **LiteLLM Proxy v1.108.0**(`ghcr.io/berriai/litellm:v1.108.0`)을 같은 Langfuse 프로젝트, Anthropic 키, 사람, 키 metadata로 돌렸습니다. [10-compare-check.py](10-compare-check.py)는 17개 검사를 통과했습니다(INFO 7개). 결함을 넣으면(서비스가 `x-litellm-end-user-id`를, 앱이 `traceparent`를 빠뜨림) 그중 2개가 실패합니다. 두 번째 실행에서 06은 다시 돌리지 않았습니다. 두 번째 실행의 모델 호출 비용: 게이트웨이 0.040 USD, LiteLLM 0.014 USD. [LiteLLM Proxy와 비교](#litellm-proxy와-비교)를 보세요.

**후속 확인도 2026-11-05 검증했습니다**([#91](https://github.com/litkhai/langfuse-hols/issues/91)). LiteLLM을 게이트웨이 앞에 잇는 구성([12-chain-check.py](12-chain-check.py) 6 PASS, INFO 2개, 위쪽 키를 틀리게 넣으면 5개 실패), kind 위 Helm 차트 2.2.3과 Traefik TLS, replica 2개인 게이트웨이([14-helm-check.py](14-helm-check.py) 15 PASS, replica 1개면 2개 실패), LiteLLM 이미지의 cosign 서명(검증됨, 교체 전 키로는 검증 안 됨)입니다. 후속 확인의 모델 호출 비용은 Claude Haiku 4.5 정가 기준 약 0.27 USD로, 대부분 8,000토큰 스트림 두 번과 Claude Code 호출 네 번입니다. [LiteLLM을 게이트웨이 앞에 잇기](#litellm을-게이트웨이-앞에-잇기)와 [Helm, TLS, replica 2개](#helm-tls-replica-2개)를 보세요.

게이트웨이는 Langfuse v4.75.0(2026-11-04 출시)과 함께 공개 베타가 됐습니다. 앱과 코딩 에이전트가 OpenAI나 Anthropic 요청을 게이트웨이 키와 함께 게이트웨이로 보내면, 게이트웨이가 조직의 공급자 키로 바꿔 끼워 요청을 그대로 넘기고, 그 호출을 Langfuse generation으로 기록합니다.

### 짧은 답

| 주장 | 실행 결과 |
|---|---|
| base URL과 API 키만 바꾸면 된다 | **예.** Anthropic SDK에 `base_url=<gateway>/anthropic`과 게이트웨이 키만 주면 Anthropic의 응답이 그대로 왔습니다(Anthropic `request-id`, 날짜가 붙은 모델, usage). 스트리밍도 같습니다. `claude -p`도 `ANTHROPIC_BASE_URL`과 `ANTHROPIC_AUTH_TOKEN`으로 동작했습니다. |
| 공급자 키를 나눠 갖지 않는다 | **예.** 공급자 키는 Postgres(`gateway_ai_connections`)에 한 번, 암호화되어 있습니다. 게이트웨이 컨테이너 환경에는 없고, 요청마다 web에서 받아 씁니다. 게이트웨이 키는 역할이 `AI_GATEWAY`인 Langfuse API 키(`sk-lf-…`)이고 해시로 저장됩니다. |
| 사용자·키·모델별 비용 | **예.** 모든 generation에 모델, 사용량, 비용과 함께 사용자, 키 이름, 키 ID, 키 metadata(`team`, `cost_center`)가 붙습니다. `events_full`에 `GROUP BY` 하나면 게이트웨이 Analytics 화면과 같은 표가 나옵니다. 사용자 키는 언제나 키 주인을 기록하고 `langfuse-user-id` 헤더는 무시합니다. 서비스 계정 키는 그 헤더에서 최종 사용자를 받고, 없으면 키 이름을 씁니다. |
| 계측할 수 없는 앱도 tracing | **`FULL` 모드에서 예:** 입력과 출력이 저장됩니다. 기본값인 **`USAGE` 모드**는 모델, 사용량, 비용, 지연 시간만 저장하고 입력과 출력은 저장하지 않습니다. |
| 모델 허용 목록 | **정확한 ID로만 동작합니다.** `claude-haiku-4-5-20251001`만 허용하면 모델 목록에 그것만 보이고 다른 모델은 `403`입니다. 같은 모델의 별칭 `claude-haiku-4-5`도 **`403`입니다**. 문자열을 비교하기 때문입니다. |
| 키 만료, 폐기 | **즉시.** 만료된 키는 `expiresAt` 뒤 첫 호출부터, 폐기한 키는 폐기 뒤 첫 호출부터 `401`이었습니다(web이 resolve 캐시에서 지웁니다). |
| 게이트웨이 권한을 잃으면 | **그 사람의 키가 삭제됩니다.** 멤버의 역할을 VIEWER로 바꾸자 다음 호출부터 키가 실패했고, 키 행이 사라졌습니다. 역할을 되돌려도 키는 돌아오지 않으며 새로 발급해야 합니다. |
| 감사 로그 | **셀프호스팅에서는 Enterprise 전용.** 라이선스가 없으면 키 생성과 폐기에 감사 기록이 남지 않고, 라이선스가 있으면 둘 다 남습니다. Langfuse Cloud에서는 코드상 항상 기록합니다(소스 확인, 실행하지 않음). |
| SDK trace + 게이트웨이 | **trace 하나.** Langfuse SDK span의 `traceparent`를 넘기면 게이트웨이 generation이 앱의 trace ID를 쓰고 앱 span을 부모로 삼았습니다. |

### 구성

```mermaid
flowchart LR
  dev["alice, bob<br/>Anthropic SDK, Claude Code<br/>사용자 키"] -->|"base URL + 게이트웨이 키"| gw
  svc["checkout-service<br/>서비스 계정 키<br/>langfuse-* 헤더, traceparent"] -->|"base URL + 게이트웨이 키"| gw
  gw["ai-gateway :18480<br/>langfuse/ai-gateway 4.75.0<br/>상태 없음"] -->|"키 확인<br/>(공유 service key)"| web["Langfuse web :13000<br/>4.75.0"]
  web -->|"공급자 키, 기록 권한"| gw
  gw -->|"x-api-key: 공급자 키"| an["api.anthropic.com"]
  gw -.->|"generation (OTLP, upload token)"| web
  web --> wk["worker"] --> ch["ClickHouse :18423<br/>events_full"]
  web --> pg["Postgres<br/>공급자 키는 암호화<br/>게이트웨이 키는 해시"]
```

| 파일 | 하는 일 |
|---|---|
| [docker-compose.yml](docker-compose.yml) | `_base/docker-compose.yml` 위의 overlay: 게이트웨이 변수를 넣은 web과 worker, `ai-gateway` 컨테이너, 호스트 포트 13000(web), 18480(게이트웨이), 18423(ClickHouse HTTP). 나머지 백엔드는 포트를 열지 않습니다 |
| [lib.sh](lib.sh) | `lab_compose`: `_base` 파일과 overlay를 compose 프로젝트 `lf-gateway-lab`으로 묶고, 이 프로젝트에만 Langfuse 4.75.0을 고정 |
| [lablib.py](lablib.py) | UI와 같은 방식의 NextAuth 로그인과 tRPC 호출, ClickHouse·Postgres 조회, `.run/state.json` |
| [01-up.sh](01-up.sh) | 게이트웨이 service key와 ES256 서명 키를 `.run/`에 한 번 만들고, 프로젝트를 띄워 web `/api/public/health`와 게이트웨이 `/health`, `/ready`를 기다립니다 |
| [02-setup.py](02-setup.py) | 관리자 설정: AI Gateway 역할의 개발자 두 명, 기록 프로젝트와 `FULL` 모드, Anthropic 자격 증명 `anthropic-lab`, metadata가 붙은 게이트웨이 키 세 개 |
| [03-calls.py](03-calls.py) | 실제 호출 시나리오 7개(아래). `FAULT=1`은 결함 주입, `SKIP_CLAUDE_CODE=1`은 `claude -p` 생략 |
| [04-controls.py](04-controls.py) | 허용 목록, 만료, 폐기, 역할 변경, `USAGE` 모드, AI Gateway 역할이 못 하는 일 |
| [05-check.py](05-check.py) | ClickHouse, Postgres, 게이트웨이 컨테이너, v2 observations API로 34개 검사 |
| [06-ee-audit.sh](06-ee-audit.sh) · [06-audit-probe.py](06-audit-probe.py) | 선택: Enterprise 라이선스 없이와 있이 키 하나를 만들고 폐기해 감사 기록을 셉니다 |
| [docker-compose.litellm.yml](docker-compose.litellm.yml) · [litellm-config.yaml](litellm-config.yaml) | 같은 프로젝트 안의 LiteLLM Proxy와 그 Postgres, 프로필 `litellm`(호스트 포트 18440). 모델 `claude-haiku-4-5`, `claude-haiku-4-5-20251001`, `haiku-broken`(fallback 시험용으로 거부되는 키), 콜백 `langfuse_otel` |
| [07-litellm-up.sh](07-litellm-up.sh) | LiteLLM master key와 salt key를 `.run/`에 한 번 만들고 띄웁니다 |
| [08-litellm-setup.py](08-litellm-setup.py) | LiteLLM에 같은 사람과 키: 내부 사용자 alice·bob, 팀 `payments`, 키 `alice-laptop`, `bob-laptop`, 서비스 계정 키 `checkout-service`, 같은 metadata |
| [09-litellm-calls.py](09-litellm-calls.py) | LiteLLM으로 같은 호출 7개(l1–l7), 이어서 모델 제한, 만료, 키 삭제, 사용자 삭제, 예산 상한, rate limit, fallback, 직접 호출과의 지연 비교. `FAULT=1`은 결함 주입 |
| [10-compare-check.py](10-compare-check.py) | LiteLLM 쪽 17개 검사(Langfuse에 들어간 generation, LiteLLM DB와 컨테이너)와 비교용 INFO 행 |
| [11-chain.py](11-chain.py) · [12-chain-check.py](12-chain-check.py) | LiteLLM의 모델 `haiku-via-gateway`가 게이트웨이 서비스 계정 키로 게이트웨이를 부름. 일반 호출, 클라이언트 헤더, 예산 상한, fallback. 12는 LiteLLM generation과 게이트웨이 generation을 짝지어 양쪽을 검사 |
| [helm/](helm/) | `kind-config.yaml`(노드 하나, 443 → 127.0.0.1:18443), `values.yaml`(차트 값: 게이트웨이 켬, replica 2개, TLS Traefik Ingress, 작은 자원), `traefik-values.yaml`(620초 타임아웃) |
| [13-helm-up.sh](13-helm-up.sh) | kind 클러스터 `lf-gateway-helm`, cert-manager v1.20.2, clickhouse-operator 0.0.8, Traefik 42.3.0, 자체 서명 CA, `.run/`의 비밀값, 차트 2.2.3. worker가 기본 모델 가격을 못 읽었으면 한 번 재시작 |
| [14-helm-check.py](14-helm-check.py) | 15개 검사: 차트가 배포한 것, CA 있이·없이 TLS, HTTPS로 SDK와 Claude Code, 가격 계산, 처리 중인 파드를 지운 스트림, rolling restart, 트래픽 중 파드 삭제. `FAULT=1`은 replica 1개로 |
| [15-helm-down.sh](15-helm-down.sh) | kind 클러스터를 지웁니다. `--purge`는 `.run/`의 비밀값, CA, 상태까지 |
| [lab.yaml](lab.yaml) | 게시 키: notes 사이트의 실습 카드(`web: true`, 2026-11-05 소유자 결정) |
| [99-down.sh](99-down.sh) | 프로젝트를 멈춥니다. `--purge`는 볼륨과 `.run/`까지 지웁니다 |

| 시나리오 | 키 | 보여 주는 것 |
|---|---|---|
| s1 sdk-basic | alice(사용자) | Anthropic SDK에서 `base_url`과 `api_key`만 바꿈 |
| s2 sdk-stream | alice(사용자) | `stream=True`, 자격 증명 접두사 `anthropic-lab:`이 붙은 모델 ID |
| s3 user-key-override | bob(사용자) | 사용자 키에서는 `langfuse-user-id: mallory@example.com`이 무시됨 |
| s4 service-end-user | checkout-service | `langfuse-*` 헤더로 최종 사용자, 세션, 환경, 태그, metadata, trace 이름 |
| s5 service-default | checkout-service | 헤더가 없으면 키 이름이 사용자 |
| s6 sdk-traceparent | checkout-service | Langfuse SDK span이 `traceparent`를 넣고, generation이 그 trace에 들어감 |
| s7 claude-code | alice(사용자) | `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, 새 `CLAUDE_CONFIG_DIR`로 `claude -p` |

### 실행

`_base/.env`(또는 `LF_ENV_FILE`)에 `ANTHROPIC_API_KEY`가 있어야 합니다. 게이트웨이는 언제나 `api.anthropic.com`과 `api.openai.com`을 부르므로 mock이 없습니다. 호출은 `max_tokens` 10 이하입니다.

```bash
labs/v4/ai-gateway/01-up.sh
.venv-v4/bin/python labs/v4/ai-gateway/02-setup.py
.venv-v4/bin/python labs/v4/ai-gateway/03-calls.py
.venv-v4/bin/python labs/v4/ai-gateway/04-controls.py
.venv-v4/bin/python labs/v4/ai-gateway/05-check.py
labs/v4/ai-gateway/06-ee-audit.sh                    # 선택: LANGFUSE_EE_LICENSE_KEY 필요
labs/v4/ai-gateway/07-litellm-up.sh                  # LiteLLM 비교, 01–05 다음에
.venv-v4/bin/python labs/v4/ai-gateway/08-litellm-setup.py
.venv-v4/bin/python labs/v4/ai-gateway/09-litellm-calls.py
.venv-v4/bin/python labs/v4/ai-gateway/10-compare-check.py
.venv-v4/bin/python labs/v4/ai-gateway/11-chain.py      # LiteLLM을 게이트웨이 앞에, 07–08 다음에
.venv-v4/bin/python labs/v4/ai-gateway/12-chain-check.py
labs/v4/ai-gateway/13-helm-up.sh                     # kind 위 Helm, compose 프로젝트와 무관
.venv-v4/bin/python labs/v4/ai-gateway/14-helm-check.py
labs/v4/ai-gateway/15-helm-down.sh                   # --purge는 Helm 비밀값과 CA까지 삭제
labs/v4/ai-gateway/99-down.sh                        # --purge는 볼륨과 .run/까지 삭제
```

UI는 http://localhost:13000(`_base/.env`의 headless-init 사용자)입니다. **Organization settings → AI Gateway**에 Setup, Models, Gateway keys, Analytics가 있습니다. `LF_ENV_FILE=<경로>`를 주면 다른 클론의 `_base/.env`를 읽습니다. :3000의 공유 스택은 계속 돌아가도 됩니다. 이 프로젝트는 그것과 아무것도 공유하지 않습니다.

### 셀프호스팅: 게이트웨이에 필요한 것

- **Langfuse ≥ 4.75.0**, web과 게이트웨이가 같은 버전. `legacy` 쓰기 모드는 안 됩니다. 게이트웨이 generation은 v4 테이블에만 저장됩니다.
- **web에:** `LANGFUSE_AI_GATEWAY_DEPLOYED=true`(없으면 UI가 게이트웨이가 배포되지 않았다고 표시), `LANGFUSE_AI_GATEWAY_PUBLIC_URL`(UI와 설정 스니펫에 표시), `LANGFUSE_AI_GATEWAY_SERVICE_KEY`, `LANGFUSE_AI_GATEWAY_JWT_PRIVATE_KEY`(ES256 PEM, `openssl ecparam -name prime256v1 -genkey -noout`), 그리고 공급자 키를 암호화하는 `ENCRYPTION_KEY`. 이 값을 바꾸면 저장된 공급자 키를 읽을 수 없습니다.
- **게이트웨이에:** `LANGFUSE_AI_GATEWAY_WEB_URL`, 같은 service key, web에 평문 http로 닿을 때는 `LANGFUSE_AI_GATEWAY_ALLOW_HTTP_WEB_URL=true`(사설 네트워크에서만. web의 응답에 공급자 키가 들어 있습니다).
- **지원 경로는 Helm 차트**(`langfuse.gateway.enabled: true`, 2.2.0 이후 차트)입니다. Langfuse의 Docker Compose 파일에는 게이트웨이가 없습니다. 이 실습은 셀프호스팅 페이지가 다른 구성용으로 적은 방법으로 게이트웨이를 붙였습니다. 읽기 전용 파일시스템, 모든 capability 제거, non-root로 돌았습니다.
- **TLS:** 게이트웨이는 TLS를 직접 종료하지 않습니다. 앞에 프록시나 로드 밸런서를 두고 타임아웃을 120초보다 길게(가장 긴 스트림은 600초), 응답 버퍼링을 끄고, 본문 한도를 16 MiB로 잡으세요. 이 실습은 localhost에서 평문 http를 썼고 `claude -p`는 그대로 받아들였습니다.
- **외부 통신:** 게이트웨이와 web은 공식 공급자 URL을 직접 부르고 `HTTP(S)_PROXY`를 무시합니다. 베타에서는 Azure OpenAI, Amazon Bedrock, 사내 LLM 프록시를 지원하지 않습니다.
- 셀프호스팅에서 게이트웨이 자체에는 **라이선스가 필요 없습니다**(`LANGFUSE_AI_GATEWAY_ENABLED`로 막지 않으면 모든 조직에서 켜짐). 코드는 저장소의 MIT 부분(`ai-gateway/`, `web/src/features/ai-gateway/`)에 있습니다.

### 들어오는 것

모델 호출 하나에 generation 하나입니다. 이름은 API 형식(`anthropic.messages`), `service_name = langfuse-ai-gateway`, OTLP로 들어오고 `ingestion_api_key`는 게이트웨이 키입니다. s4(FULL 모드)에서:

| 필드 | 값 |
|---|---|
| `provided_model_name` | `claude-haiku-4-5-20251001`(요청한 이름 `claude-haiku-4-5`는 `langfuse.gateway.model.requested`에 남음) |
| `usage_details` / `cost_details` | 입력 15, 출력 5토큰 · 0.000015 + 0.000025 = 0.00004 USD |
| `user_id` · `session_id` · `environment` · `tags` · `trace_name` | `end-user-42` · `checkout-<run>` · `production` · `checkout, beta` · `checkout-summary` |
| `input` / `output` | 요청의 `messages`와 `stop_reason`이 있는 assistant 메시지 |
| metadata | `langfuse.gateway.api_key.{id,name}`, `langfuse.gateway.api_key.metadata.{team,cost_center}`, `langfuse.gateway.connection.{id,name,provider}`, `langfuse.gateway.user_id_source`(`api_key_owner`, `client`, `api_key_name`), `langfuse.gateway.ingestion.mode`, `langfuse.gateway.request.id`, `langfuse.gateway.upstream.request.id`(Anthropic의 `request-id`), 본문 크기, 상태 코드, 클라이언트 user agent, 그리고 요청의 `langfuse-metadata` 키(`order`, `region`) |

응답 헤더: `langfuse-trace-id`, `langfuse-observation-id`, `langfuse-request-id`, `langfuse-provider`, 그리고 Anthropic의 `request-id`.

사용자·키·모델별 비용을 ClickHouse에서 바로:

```sql
SELECT user_id,
       metadata_values[indexOf(metadata_names, 'langfuse.gateway.api_key.name')]         AS key_name,
       metadata_values[indexOf(metadata_names, 'langfuse.gateway.api_key.metadata.team')] AS team,
       provided_model_name AS model, count() AS calls, round(sum(total_cost), 6) AS cost_usd
FROM events_full FINAL
WHERE project_id = 'llm-observability' AND has(metadata_names, 'langfuse.gateway.api_key.id')
GROUP BY user_id, key_name, team, model
ORDER BY cost_usd DESC
```

| 사용자 | 키 | team | 모델 | 호출 | 비용(USD) |
|---|---|---|---|---:|---:|
| alice@example.com | alice-laptop | platform | claude-haiku-4-5-20251001 | 7 | 0.039835 |
| bob@example.com | bob-laptop | data | claude-haiku-4-5-20251001 | 3 | 0.000066 |
| *(비어 있음)* | checkout-service | payments | claude-haiku-4-5-20251001 | 1 | 0.000040 |
| checkout-service | checkout-service | payments | claude-haiku-4-5-20251001 | 1 | 0.000040 |
| end-user-42 | checkout-service | payments | claude-haiku-4-5-20251001 | 1 | 0.000040 |
| bob@example.com | bob-temp | data | claude-haiku-4-5-20251001 | 2 | 0.000026 |
| alice@example.com | alice-short | platform | claude-haiku-4-5-20251001 | 1 | 0.000013 |

Alice의 0.0398 USD는 거의 전부 Claude Code 호출 한 번입니다. Claude Code는 약 119 KB의 요청(시스템 프롬프트와 도구 정의 24개)을 보냈고, Anthropic은 프롬프트 캐시 쓰기 31,590토큰으로 보고했습니다. 사용자가 빈 행은 s6입니다. 앱 자신의 trace 안에서는 게이트웨이가 앱 span의 사용자를 그대로 두는데, 그 span에 사용자가 없었습니다. 같은 숫자가 **Organization settings → AI Gateway → Analytics**에도 나오며, 이 화면의 사용자별 차트는 서비스 계정 키를 뺍니다.

### 통제, 측정값

| 통제 | 시험 | 결과 |
|---|---|---|
| 허용 목록 | 자격 증명이 `claude-haiku-4-5-20251001`만 허용 | 모델 목록에 그 ID만 보임. `claude-haiku-4-5-20251001`과 `anthropic-lab:claude-haiku-4-5-20251001` → 200, `claude-sonnet-4-5-20250929` → **403** `permission_error: Model is not allowed for this provider connection`, 별칭 `claude-haiku-4-5`도 → **403**. *Enable all* 뒤에는 별칭 → 200 |
| 만료 | `expiresAt` = 생성 + 40초인 사용자 키 | 만료 전 200, `expiresAt` 뒤 첫 호출(0.1초 뒤)부터 **401** |
| 폐기 | 두 번 써서(조회가 캐시됨) 폐기 | 폐기 뒤 첫 호출부터 **401** |
| 역할 변경 | bob AI_GATEWAY → VIEWER → AI_GATEWAY | 다음 호출부터 401, 키 행이 **삭제됨**. 역할을 되돌린 뒤에도 옛 키는 401이고, 새로 발급한 키 → 200 |
| 기록 모드 | `USAGE`에서 호출 한 번 | 사용량과 비용은 기록, `input`과 `output`은 비어 있음, `langfuse.gateway.ingestion.mode = usage` |
| 역할 범위 | AI Gateway 역할 멤버가 `createConnection` 호출 | **403 FORBIDDEN** |
| 감사 로그 | EE 라이선스 없이와 있이 키 생성 + 폐기 | 없이는 기록 없음, 있으면 Postgres `audit_logs`에 `create`, `delete` |

만료, 폐기, 역할 변경은 60초 resolve 캐시를 기다리지 않았습니다. web이 폐기와 역할 변경 때 키를 캐시에서 지우고, 캐시된 조회를 키의 `expiresAt`까지로 자릅니다. 설정과 자격 증명을 바꿔도 그 조직의 캐시가 지워집니다. 역할 변경으로 키가 멈추는 것은 Langfuse가 키를 지우기 때문입니다.

### LiteLLM Proxy와 비교

같은 질문, 같은 Anthropic 키, 같은 사람과 키 metadata, 같은 Langfuse 프로젝트입니다. LiteLLM은 `langfuse_otel`(OTel v2, `llm_only`, 메시지 내용 포함)로 generation을 보냅니다. 2026-11-05 측정.

| 질문 | Langfuse AI Gateway 4.75.0 | LiteLLM Proxy v1.108.0 |
|---|---|---|
| 클라이언트 변경 | base URL + 키. SDK, 스트리밍, `claude -p` 동작 | 같음(`/v1/messages`) |
| 응답 본문 | 그대로 전달(`model: claude-haiku-4-5-20251001`) | 바뀜: `model`이 요청한 이름 `claude-haiku-4-5` |
| 공급자 키 위치 | Langfuse Postgres에 암호화. 게이트웨이에는 없음 | 프록시가 보관(여기서는 환경 변수. LiteLLM DB에 둘 수도 있으나 시험하지 않음) |
| 클라이언트 키 저장 | 해시 | 해시 |
| 호출의 주인 | Langfuse `user_id` = 키 주인. 헤더로 못 바꿈 | 키 주인(`user_api_key_user_id`)은 못 바꿈. 최종 사용자는 클라이언트가 정함(`x-litellm-end-user-id`). 둘 다 metadata에만 있고 Langfuse `user_id`는 27개 중 27개가 비어 있음 |
| Langfuse의 키·팀·태그 | 키 이름, 키 metadata, `langfuse-*` 헤더 | 키 별칭, 팀, 최종 사용자, `x-litellm-tags` |
| 세션 | 에이전트에서(`claude-code:<id>`) 또는 헤더 | Claude Code의 세션 ID. 그 밖에는 비어 있음 |
| 앱 span의 `traceparent` | 같은 trace, **앱 span의 자식** | 같은 trace, **부모 없음**(평평함) |
| 모델 제한 | 정확한 ID: 별칭은 `403` | 정확한 이름: 별칭은 `403 key_model_access_denied` |
| 만료, 폐기 | 다음 호출부터 `401` | 다음 호출부터 `401` |
| 사람이 떠날 때 | 역할 변경이 사용자 키를 지움 | 사용자 삭제가 키를 지움 |
| 예산 상한 | 없음 | `max_budget` 0.00006 USD: 6번째 호출이 0.000065에서 `422 budget_exceeded`(한 호출만큼 초과) |
| Rate limit | 셀프호스팅에는 없음 | `rpm_limit: 2`: `[200, 200, 429]` |
| 실패하는 모델 | 에러가 클라이언트로(`404`), fallback 설정 없음 | `fallbacks`: 다음 모델로 응답, `x-litellm-attempted-fallbacks: 1` |
| 공급자 | OpenAI, Anthropic | 문서상 100개 이상(여기서는 Anthropic만 실행) |
| 라이선스 없는 감사 로그 | 없음(Enterprise) | 없음(`LiteLLM_AuditLog` 0행, 문서상 Enterprise) |
| 지연 시간, 워밍업 뒤 5회 중앙값 | 526 ms | 547 ms(새 연결로 한 직접 호출: 610 ms) |
| 추가 인프라 | Langfuse 옆 상태 없는 컨테이너 하나 | 프록시와 전용 Postgres |
| Langfuse의 비용 | Langfuse 모델 가격표로 계산 | LiteLLM이 계산한 비용을 provided cost로 보냄 |

두 게이트웨이가 직접 호출보다 빨랐던 것은 upstream 연결을 재사용하기 때문입니다. 직접 호출 쪽은 매번 새 연결을 열었습니다. 한 호스트에서 5회라 두 게이트웨이 사이의 21 ms 차이는 오차 범위입니다.

**정리** (*권장, 측정 아님*):
- 예산 상한, rate limit, fallback, OpenAI·Anthropic 밖의 공급자가 필요하면: 지금은 LiteLLM에 있고 Langfuse 게이트웨이에는 없습니다.
- trace를 기록 그 자체로 쓰고 싶으면(사용자 칸, 앱 span 아래 중첩, 공급자 응답 그대로, 그 위의 평가): Langfuse 게이트웨이가 별도 작업 없이 줍니다.
- 둘 다, 즉 LiteLLM을 앞에 두고 `langfuse_otel`로 보내면: 상한·제한·fallback은 LiteLLM이, generation은 Langfuse가 갖습니다. 다만 사람 정보가 metadata에만 있고(`user_api_key_*`로 필터, Users 화면은 비어 있음) generation이 앱 span 아래에 들어가지 않습니다.
- LiteLLM은 버전이나 digest로 고정하고 cosign 서명을 확인하세요. 2026-10-21 릴리스 파이프라인이 뚫려, 자격 증명을 훔치는 악성 코드가 PyPI의 `litellm==1.107.0`으로 약 2시간, Docker 태그 `v1.107.0`, `latest`, `main-latest`, `main-stable`로 약 2.5시간 배포됐습니다(LiteLLM 사고 보고). 이 저장소는 2026년(2026-11-05까지) GitHub 보안 공지를 18건 냈고 그중 5건이 critical입니다. Langfuse 저장소는 2건입니다. 공지 건수는 보안 등급이 아니라 업그레이드를 얼마나 자주 계획해야 하는지를 말해 줍니다.

### LiteLLM을 게이트웨이 앞에 잇기

LiteLLM의 모델 `haiku-via-gateway`가 Anthropic 경로를 게이트웨이로 보냅니다(`api_base: http://ai-gateway:8080/anthropic`, LiteLLM이 `/v1/messages`를 붙임). 키는 게이트웨이의 서비스 계정 키 `litellm-upstream`이고, 클라이언트는 LiteLLM 가상 키를 그대로 씁니다. 2026-11-05 측정:

| 질문 | 결과 |
|---|---|
| 응답이 오나 | `200`. 응답의 `model`은 LiteLLM의 이름 `haiku-via-gateway` |
| LiteLLM 예산 상한 | 0.00004 USD 키의 두 번째 호출이 `422`. 막힌 호출은 게이트웨이까지 가지 않음 |
| Fallback `haiku-broken-chain` → `haiku-via-gateway` | `200`, `x-litellm-attempted-fallbacks: 1`, 게이트웨이가 기록 |
| 호출당 기록 | **두 개**. LiteLLM의 것과 게이트웨이의 것이 서로 다른 trace에 있음(LiteLLM이 위쪽으로 `traceparent`를 보내지 않음). 프로젝트 비용이 두 번 잡힘 |
| 게이트웨이가 보는 사람 | 모든 호출이 한 사람: 키 `litellm-upstream`(사용자 출처 `api_key_name`) |
| 클라이언트 헤더 | `langfuse-user-id`는 전달되지 않음(LiteLLM은 `x-` 헤더만 넘김). `x-pass-langfuse-user-id`, `x-pass-langfuse-tags`도 `/v1/messages`에서는 도착하지 않음 |
| 위쪽 키가 틀리면 | 첫 호출 `401`. 이후 LiteLLM이 그 배포를 쉬게 해서(cooldown) `429 No deployments available`(결함 실행) |

**정리** (*권장*): LiteLLM의 상한·fallback이 필요하면서 공급자 키도 LiteLLM 밖에 두고 싶을 때만 이으세요. 그때는 Langfuse로 보내는 쪽을 하나만 켜거나 서로 다른 프로젝트로 나누고, 사람별 분석은 LiteLLM의 metadata로 하세요. 게이트웨이에는 LiteLLM의 키 하나만 보입니다.

### Helm, TLS, replica 2개

지원하는 셀프호스팅 경로를 로컬 kind 클러스터에서 돌렸습니다. kind 0.33.0(노드 하나), cert-manager v1.20.2와 clickhouse-operator 0.0.8(차트의 ClickHouse는 operator 위에서 돌아감), TLS 앞단 Traefik 42.3.0(v3.7.17), langfuse 차트 2.2.3(Langfuse 4.75.0)과 [helm/values.yaml](helm/values.yaml): `langfuse.gateway.enabled: true`, `replicas: 2`, `gateway.127.0.0.1.nip.io`에 TLS Ingress. Langfuse 페이지는 ingress-nginx 어노테이션을 예로 들지만 ingress-nginx는 2026년 3월에 퇴역했으므로(Kubernetes 공지, 저장소는 archive 상태이고 마지막 push 2026-03-23) Traefik을 썼습니다. Traefik은 응답을 버퍼링하지 않고, 긴 타임아웃(`620s`)은 entrypoint에 둡니다. 2026-11-05, 지운 클러스터에서 처음부터 측정:

| 검사 | 결과 |
|---|---|
| 차트가 배포하는 것 | replica 2개인 게이트웨이 Deployment, Service, Ingress, PDB `maxUnavailable: 1`, `terminationGracePeriodSeconds: 350`. web에는 `LANGFUSE_AI_GATEWAY_DEPLOYED=true`와 공개 URL. 게이트웨이는 클러스터 안 Service로 web에 http로 접속(`LANGFUSE_AI_GATEWAY_ALLOW_HTTP_WEB_URL=true`) |
| TLS | 실습 CA로 `/health` `200`, CA 없이는 `CERTIFICATE_VERIFY_FAILED` |
| HTTPS 클라이언트 | CA를 준 Anthropic SDK(anthropic 1.12.1은 httpx2 위에서 돌아서 `anthropic.DefaultHttpxClient(verify=…)`로 넘겨야 하고 `httpx.Client`는 거부됨). `claude -p`는 `NODE_EXTRA_CA_CERTS` 없이는 실패, 있으면 동작 |
| 스트림을 처리하던 파드를 지움 | 스트림이 49.5초 더 이어져 끝까지 나옴(8,000토큰). 그 파드가 `gateway draining`을 기록. generation도 기록됨 |
| Rolling restart | 새 파드 준비 16.4초, 이전 파드가 모두 사라지기까지 28.9초 |
| 트래픽 중 파드 하나 삭제 | 20건 중 20건 `200` |
| replica 1개(결함 실행) | 하나뿐인 파드를 지우자 새 파드가 준비될 때까지 20건 중 14건 `503` |
| 첫 설치의 가격 계산 | worker가 Postgres보다 먼저 떠서 `Error upserting default model prices`를 남기고 다시 시도하지 않음: 모델 행 87개, `claude-haiku-4-5` 없음, 모든 비용 0. worker를 재시작하자 188개가 되고 비용이 붙음. 13-helm-up.sh가 이제 이 재시작을 함. 처음부터 설치한 두 번 모두 발생 |

짧은 스트림은 파드가 `SIGTERM`을 받기도 전에, 10초 `preStop` 대기 안에 끝납니다. 8,000토큰 스트림은 그보다 길어서 drain 단계가 받아 냈습니다.

### 이미지 서명(LiteLLM)

`ghcr.io/berriai/litellm@sha256:c560d317…`을 LiteLLM 커밋 `e82a3c6`의 `cosign.pub`로 `cosign verify`(cosign v3.1.4)했고, 검증됐습니다. 키 파일의 SHA-256은 LiteLLM 문서에 적힌 지문(`e3fe3e08…`)과 같습니다. 음성 대조: 10월 교체 전의 키(커밋 `0112e53`)로는 `no matching signatures`입니다.

### 한계

- **허용 목록은 모델이 아니라 문자열을 맞춥니다.** 공급자의 모델 목록은 오래된 모델에는 날짜가 붙은 ID(`claude-haiku-4-5-20251001`), 새 모델에는 날짜 없는 ID를 줍니다. 자격 증명에 명시적인 목록이 생기면 별칭을 보내는 클라이언트는 `403`을 받습니다. 클라이언트가 실제로 보내는 ID를 허용하거나, 목록에 있는 ID를 보내게 하세요.
- **게이트웨이 권한을 잃으면 키가 지워집니다.** VIEWER(또는 NONE)로 바꾸면 그 사람의 사용자 키가 바로 삭제되고, 역할을 되돌려도 복구되지 않습니다. 멤버십 변화에도 살아 있어야 하는 것은 서비스 계정 키로 쓰세요.
- **셀프호스팅에서 감사 기록에는 Enterprise 라이선스가 필요합니다**(`isAuditLogEnabled`: Cloud는 항상, 셀프호스팅은 `audit-logs` entitlement가 있을 때만). 없으면 키 생성과 폐기가 아무 흔적도 남기지 않습니다.
- **OpenAI 경로는 실행하지 않았습니다**(OpenAI 키 없음). Responses, Chat Completions, Codex, Copilot은 Langfuse 문서에 있지만 여기서 시험하지 않았습니다.
- **LiteLLM, 실행하지 않은 것:** Enterprise 기능(5명 넘는 SSO, 감사 로그, 키별 guardrail), Redis와 프록시 여러 대, DB에 저장한 자격 증명, 사용자·팀 예산, LiteLLM 쪽의 긴 스트림과 장애.
- **실행하지 않은 것:** 클라우드 클러스터의 Helm 차트, HPA, cert-manager가 발급한 인증서, 메모리 예산과 부하 시 `503`, Claude Desktop, Claude Code 턴 묶기(`CLAUDE_CODE_PROPAGATE_TRACEPARENT`), `NONE` 모드, Langfuse Cloud와 그 rate limit.
- **알려진 베타 비용 버그**(Langfuse 목록, 여기서 재현하지 않음): 실패하거나 취소된 OpenAI 호출의 추정 비용, OpenAI 캐시 쓰기 $0, Anthropic 1시간 캐시 쓰기를 5분 요율로 계산. 5 MiB가 넘는 입력은 저장되지 않고, 1 MiB가 넘는 출력은 기록에서 잘립니다.
- **Analytics는 지워진 키의 이름을 잃습니다.** 폐기되거나 역할 변경으로 지워진 키는 *Cost by gateway key*에 ID로만 나옵니다. 이름은 각 generation의 `langfuse.gateway.api_key.name`에 남아 있으므로 ClickHouse 쿼리에서는 보입니다.
- **키 metadata는 만들 때 정해집니다.** `team`이나 `cost_center`를 바꾸려면 새 키를 발급하고 옛 키를 폐기하세요.
- Claude Code는 기본적으로 **모델 호출 하나가 trace 하나**입니다(s7: 호출 하나, trace 하나, 세션 `claude-code:<id>`). 세션이나 턴 묶기를 쓰세요.
- **이름이 일반적입니다:** 모든 generation이 `anthropic.messages`입니다. 다른 이름이 필요하면 호출마다 `langfuse-trace-name`을 주세요.

### 출처(모두 2026-11-04 확인)

위 English 절의 목록과 같습니다: Helm과 TLS 앞단(langfuse 차트 2.2.3, Traefik 차트 42.3.0, Ingress NGINX 퇴역 공지와 archive된 저장소, LiteLLM 헤더 전달 문서; 2026-11-05 확인), LiteLLM 문서(가상 키, 예산·rate limit, 최종 사용자, fallback, Claude Code, OpenTelemetry v2, 감사 로그, 이미지 보안, 2026-10-21 사고 보고, 보안 공지, 릴리스; 2026-11-05 확인), Langfuse AI Gateway 문서(개요, 개념, 관리자 설정, 첫 요청, 키, 모델 관리, tracing, REST API, Analytics, 알려진 한계, 셀프호스팅, Claude Code), 릴리스 v4.75.0과 `langfuse/ai-gateway` 이미지, v4.75.0 소스 파일.
