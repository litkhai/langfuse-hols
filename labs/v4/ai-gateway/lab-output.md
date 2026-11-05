# Run log — labs/v4/ai-gateway

Run on **2026-11-05** (KST; 2026-11-04 14:58–15:08 UTC) on macOS, Docker Desktop 29.9.2, Compose v5.6.1, Python 3.12.14 (`.venv-v4`: langfuse 4.17.0, anthropic 1.12.1, httpx 0.28.1), Claude Code 2.1.220.
Images: `langfuse/langfuse:4.75.0` · `langfuse/langfuse-worker:4.75.0` · `langfuse/ai-gateway:4.75.0` (`sha256:30ab3d77…`) · `clickhouse/clickhouse-server:26.8.22.13` · `postgres:17.11` · `redis:7.2.16` · MinIO by digest (the `_base/` pins).
Real calls to the Anthropic API with Claude Haiku 4.5. The run's 16 gateway generations cost **0.04006 USD** as Langfuse priced them (one Claude Code call 0.0397 of it: 31,590 prompt-cache write tokens); an earlier development run on since-deleted volumes made 16 more short calls without Claude Code.

Key prefixes and IDs below are from a local lab instance (ports on 127.0.0.1 only); secret keys are never printed, and the last four characters of the provider key that Langfuse shows are redacted here.

## 01–05 from deleted volumes

The first `02-setup.py` stopped at sign-up: the generated password had no non-alphanumeric character, which the sign-up policy requires. Fixed in `02-setup.py`; nothing had been created, so the run went on from 02 on the same fresh stack.

```text
$ 99-down.sh --purge
 Volume lf-gateway-lab_langfuse_minio_data Removed 
 Volume lf-gateway-lab_langfuse_postgres_data Removed 
$ 01-up.sh
▶ generated gateway service key and JWT signing key in <clone>/labs/v4/ai-gateway/.run
▶ Starting lf-gateway-lab (Langfuse 4.75.0 web · worker · ai-gateway + backends)…
▶ Waiting for web (first boot runs the Postgres and ClickHouse migrations)…
  web healthy after ~21 s
  gateway /health → {"status":"ok"}
  gateway /ready → {"status":"ready"}
  versions: web docker.io/langfuse/langfuse:4.75.0 · gateway image docker.io/langfuse/ai-gateway:4.75.0
✅ UI http://localhost:13000 · gateway http://localhost:18480 — next: 02-setup.py
$ 02-setup.py
$ 02-setup.py
✓ alice@example.com added with org role AI_GATEWAY
✓ bob@example.com added with org role AI_GATEWAY
✓ gateway config: project llm-observability · mode FULL
✓ provider credential anthropic-lab created: status ENABLED, shown as sk-ant...<last 4, redacted in this log>
✓ key alice-laptop (user, by alice) sk-lf-40b0… metadata {'team': 'platform', 'cost_center': '1001'}
✓ key bob-laptop (user, by bob) sk-lf-a3eb… metadata {'team': 'data', 'cost_center': '2002'}
✓ key checkout-service (serviceAccount, by owner) sk-lf-3b03… metadata {'team': 'payments', 'cost_center': '3003'}
✓ GET /anthropic/v1/models with alice's key: HTTP 200, 14 models, e.g. ['anthropic-lab:claude-fable-5', 'anthropic-lab:claude-fable-5-1', 'anthropic-lab:claude-haiku-4-5-20251001', 'anthropic-lab:claude-haiku-5-5']
$ 03-calls.py
✓ s1-sdk-basic         HTTP 200 claude-haiku-4-5-20251001 {'input': 15, 'output': 5} trace f9401fd9571d19b5975a916853231bba 'pong'
✓ s2-sdk-stream        HTTP 200 claude-haiku-4-5-20251001 {'input': 15, 'output': 5} trace 6b6b436cf444ded0b012d334ca808fdd 'pong'
✓ s3-user-key-override HTTP 200 claude-haiku-4-5-20251001 {'input': 15, 'output': 5} trace 413702f27d3cfa579c141997390c2015 'pong'
✓ s4-service-end-user  HTTP 200 claude-haiku-4-5-20251001 {'input': 15, 'output': 5} trace 36056b5b93876213e28a348a6bc0dcd4 'pong'
✓ s5-service-default   HTTP 200 claude-haiku-4-5-20251001 {'input': 15, 'output': 5} trace 4830e6dd59865b02f59c74faa9b93156 'pong'
✓ s6-sdk-traceparent   HTTP 200 claude-haiku-4-5-20251001 {'input': 15, 'output': 5} trace b0367b15c165cdb01c9bca7439862624 'pong'
✓ s7-claude-code      exit 0 (2.1.220 (Claude Code)) 'hello gateway'
→ run 7cc74603 recorded in .run/state.json — next: 04-controls.py, then 05-check.py
$ 04-controls.py
A allowlist   listed ['anthropic-lab:claude-haiku-4-5-20251001'] · dated 200 · alias 403 · prefixed 200 · other 403 · after reset 200
B expiry      before 200 · 401 reached True 0.1 s after expiresAt (1 calls)
C revocation  before [200, 200] · 401 reached True 0.0 s after revoke (1 calls)
D role change before 200 · VIEWER → 401 after 0.0 s · key rows left 0 · back to AI_GATEWAY: old key 401 · new key 200
E USAGE mode  HTTP 200 trace 05ab64a7d977746522f300f3049f389b (mode back to FULL)
· AI Gateway role → createConnection: {'allowed': False, 'status': 403, 'code': 'FORBIDDEN'}
→ recorded in .run/state.json — next: 05-check.py
```

`05-check.py` first reported 33 PASS · 1 FAIL: the Claude Code check counted every `alice-laptop` call after s7 started, including those of `04-controls.py`. The check now counts only calls up to the end of `03-calls.py` with a `claude-cli/` user agent. Re-run on the same data, without new model calls:

```text
$ 05-check.py
── run 7cc74603 · Langfuse 4.75.0
PASS  s1 Anthropic SDK through the gateway answers like Anthropic  — HTTP 200, 'pong', provider header anthropic, Anthropic request-id req_011Cgi68utynPTs3TwDE4DAK
PASS  s1 response header langfuse-trace-id points at a stored generation  — trace f9401fd9571d19b5975a916853231bba
PASS  s1 generation: API format as name, the provider's dated model  — anthropic.messages · claude-haiku-4-5-20251001 (requested claude-haiku-4-5)
PASS  s1 usage and cost recorded  — usage {'cache_read_input_tokens': 0, 'input_tokens': 15, 'output_tokens': 5, 'input_cache_creation_5m': 0, 'input_cache_creation_1h': 0, 'total': 20} · cost total 4e-05 USD
PASS  s1 FULL mode stores input and output  — input {"messages":[{"role":"user","content":"Reply with exactly one word: po…
PASS  s1 user key → trace user is the key owner  — user alice@example.com · source api_key_owner
PASS  s1 key name and key metadata on the generation  — key alice-laptop · team platform · cost_center 1001
PASS  s2 streamed call: output and time to first token recorded  — start 2026-11-04 15:01:36.419000 · first token 2026-11-04 15:01:36.839000
PASS  s3 user key ignores langfuse-user-id: mallory@example.com  — user bob@example.com
PASS  s4 service account key + langfuse-user-id → end user  — user end-user-42 · source client
PASS  s4 session, environment, tags and trace name from headers  — checkout-7cc74603 · production · ['checkout', 'beta'] · checkout-summary
PASS  s4 request metadata next to the key's own metadata  — order A-1001 · region kr · cost_center 3003
PASS  s5 service account key without headers → key name as user  — user checkout-service
PASS  s6 gateway reuses the app's trace ID from traceparent  — gateway b0367b15c165cdb01c9bca7439862624 · app b0367b15c165cdb01c9bca7439862624
PASS  s6 generation is a child of the app's span  — parent 87918382f5f647cd · app span 87918382f5f647cd
PASS  s6 the app's own span is in the same trace  — {'name': 'checkout-request', 'service_name': 'checkout-app'}
PASS  s7 claude -p through the gateway  — 2.1.220 (Claude Code) · exit 0 · 'hello gateway'
PASS  s7 Claude Code calls: session claude-code:<id>, agent.name claude-code, user = key owner  — 1 generations · 1 traces · 1 session · models ['claude-haiku-4-5-20251001'] · input tokens [10] · claude-cli/2.1.220 (external, sdk-cli)
PASS  cost per user, key and model from events_full (one GROUP BY)  — 7 groups
        alice@example.com      alice-laptop     platform  claude-haiku-4-5-20251001      7 calls  0.039835 USD
        bob@example.com        bob-laptop       data      claude-haiku-4-5-20251001      3 calls  0.000066 USD
                               checkout-service payments  claude-haiku-4-5-20251001      1 calls  0.000040 USD
        checkout-service       checkout-service payments  claude-haiku-4-5-20251001      1 calls  0.000040 USD
        end-user-42            checkout-service payments  claude-haiku-4-5-20251001      1 calls  0.000040 USD
        bob@example.com        bob-temp         data      claude-haiku-4-5-20251001      2 calls  0.000026 USD
        alice@example.com      alice-short      platform  claude-haiku-4-5-20251001      1 calls  0.000013 USD
PASS  provider key is stored encrypted in Postgres (gateway_ai_connections)  — shown as sk-ant...<last 4, redacted in this log>
PASS  gateway keys are not stored in plain text (pg_dump of api_keys)  — 40 lines searched
PASS  gateway container has no provider key in its environment  — 7 variables
PASS  allowlist: the model list shows only the allowed model  — ['anthropic-lab:claude-haiku-4-5-20251001']
PASS  allowlist: allowed dated ID passes, with and without prefix  — 200 / 200
PASS  allowlist: another model is refused before the provider  — HTTP 403 permission_error Model is not allowed for this provider connection
INFO  allowlist: the alias of the allowed model (claude-haiku-4-5)  — HTTP 403 permission_error Model is not allowed for this provider connection
PASS  allowlist reset to all models: alias works again  — HTTP 200
PASS  expiry: key works, then 401 within 10 s of expiresAt  — 401 after 0.1 s, 1 calls
PASS  revocation: the first call after revoke gets 401  — 401 after 0.0 s on call 1
PASS  role change to VIEWER: the user key stops on the next call  — 401 after 0.0 s
PASS  role change to VIEWER deletes the user's gateway keys  — api_keys rows left: 0
PASS  role back to AI_GATEWAY: the old key stays dead, a new key works  — old 401 · new 200
PASS  USAGE mode: usage and cost without input or output  — input '' · output '' · cost 1.3e-05
PASS  AI Gateway role cannot add a provider credential  — HTTP 403 FORBIDDEN
INFO  audit log entries for gateway keys (OSS, no licence)  — Postgres audit_logs 0 · ClickHouse audit_logs 0
PASS  v2 observations API returns the s1 generation  — HTTP 200 · [('GENERATION', 'anthropic.messages', '75654f1304209c11')]
── 34 PASS · 0 FAIL · 2 INFO
```

## Injected fault

`.run/state.json` was copied aside, `03-calls.py` was run with `FAULT=1` (s4 without `langfuse-user-id`, s6 without `traceparent`) and without Claude Code, `05-check.py` was run, and the copy was put back.

```text
$ FAULT=1 SKIP_CLAUDE_CODE=1 03-calls.py
✓ s1-sdk-basic         HTTP 200 claude-haiku-4-5-20251001 {'input': 15, 'output': 5} trace 0df302826a001b21a51436bcbd2a3c47 'pong'
✓ s2-sdk-stream        HTTP 200 claude-haiku-4-5-20251001 {'input': 15, 'output': 5} trace 21658353152fd2d0f95a4a0ebdefec32 'pong'
✓ s3-user-key-override HTTP 200 claude-haiku-4-5-20251001 {'input': 15, 'output': 5} trace 7cb8dda46307c6584c12413d0438a28d 'pong'
✓ s4-service-end-user  HTTP 200 claude-haiku-4-5-20251001 {'input': 15, 'output': 5} trace 2625ae559034d13027d64b65f5c629c1 'pong'
✓ s5-service-default   HTTP 200 claude-haiku-4-5-20251001 {'input': 15, 'output': 5} trace ed6a84eb13fd48d04cc88e0db7822842 'pong'
✓ s6-sdk-traceparent   HTTP 200 claude-haiku-4-5-20251001 {'input': 15, 'output': 5} trace 96fd2823409193cd572b9cfbb14c6c7b 'pong'
· s7-claude-code skipped
→ run 0707384e (FAULT) recorded in .run/state.json — next: 04-controls.py, then 05-check.py
$ 05-check.py
── run 0707384e (FAULT) · Langfuse 4.75.0
PASS  s1 Anthropic SDK through the gateway answers like Anthropic  — HTTP 200, 'pong', provider header anthropic, Anthropic request-id req_011Cgi6HiT98rX1DH1DHNgpm
PASS  s1 response header langfuse-trace-id points at a stored generation  — trace 0df302826a001b21a51436bcbd2a3c47
PASS  s1 generation: API format as name, the provider's dated model  — anthropic.messages · claude-haiku-4-5-20251001 (requested claude-haiku-4-5)
PASS  s1 usage and cost recorded  — usage {'cache_read_input_tokens': 0, 'input_tokens': 15, 'output_tokens': 5, 'input_cache_creation_5m': 0, 'input_cache_creation_1h': 0, 'total': 20} · cost total 4e-05 USD
PASS  s1 FULL mode stores input and output  — input {"messages":[{"role":"user","content":"Reply with exactly one word: po…
PASS  s1 user key → trace user is the key owner  — user alice@example.com · source api_key_owner
PASS  s1 key name and key metadata on the generation  — key alice-laptop · team platform · cost_center 1001
PASS  s2 streamed call: output and time to first token recorded  — start 2026-11-04 15:03:35.833000 · first token 2026-11-04 15:03:36.242000
PASS  s3 user key ignores langfuse-user-id: mallory@example.com  — user bob@example.com
FAIL  s4 service account key + langfuse-user-id → end user  — user checkout-service · source api_key_name
PASS  s4 session, environment, tags and trace name from headers  — checkout-0707384e · production · ['checkout', 'beta'] · checkout-summary
PASS  s4 request metadata next to the key's own metadata  — order A-1001 · region kr · cost_center 3003
PASS  s5 service account key without headers → key name as user  — user checkout-service
FAIL  s6 gateway reuses the app's trace ID from traceparent  — gateway 96fd2823409193cd572b9cfbb14c6c7b · app f836554f74ebf1ac1c83c132a387b5d0
FAIL  s6 generation is a child of the app's span  — parent  · app span 078c6c366db48b96
PASS  s6 the app's own span is in the same trace  — {'name': 'checkout-request', 'service_name': 'checkout-app'}
INFO  s7 Claude Code not run (SKIP_CLAUDE_CODE=1 or no claude on PATH)
PASS  cost per user, key and model from events_full (one GROUP BY)  — 7 groups
        alice@example.com      alice-laptop     platform  claude-haiku-4-5-20251001      9 calls  0.039915 USD
        checkout-service       checkout-service payments  claude-haiku-4-5-20251001      4 calls  0.000160 USD
        bob@example.com        bob-laptop       data      claude-haiku-4-5-20251001      4 calls  0.000106 USD
                               checkout-service payments  claude-haiku-4-5-20251001      1 calls  0.000040 USD
        end-user-42            checkout-service payments  claude-haiku-4-5-20251001      1 calls  0.000040 USD
        bob@example.com        bob-temp         data      claude-haiku-4-5-20251001      2 calls  0.000026 USD
        alice@example.com      alice-short      platform  claude-haiku-4-5-20251001      1 calls  0.000013 USD
PASS  provider key is stored encrypted in Postgres (gateway_ai_connections)  — shown as sk-ant...<last 4, redacted in this log>
PASS  gateway keys are not stored in plain text (pg_dump of api_keys)  — 40 lines searched
PASS  gateway container has no provider key in its environment  — 7 variables
PASS  allowlist: the model list shows only the allowed model  — ['anthropic-lab:claude-haiku-4-5-20251001']
PASS  allowlist: allowed dated ID passes, with and without prefix  — 200 / 200
PASS  allowlist: another model is refused before the provider  — HTTP 403 permission_error Model is not allowed for this provider connection
INFO  allowlist: the alias of the allowed model (claude-haiku-4-5)  — HTTP 403 permission_error Model is not allowed for this provider connection
PASS  allowlist reset to all models: alias works again  — HTTP 200
PASS  expiry: key works, then 401 within 10 s of expiresAt  — 401 after 0.1 s, 1 calls
PASS  revocation: the first call after revoke gets 401  — 401 after 0.0 s on call 1
PASS  role change to VIEWER: the user key stops on the next call  — 401 after 0.0 s
PASS  role change to VIEWER deletes the user's gateway keys  — api_keys rows left: 0
PASS  role back to AI_GATEWAY: the old key stays dead, a new key works  — old 401 · new 200
PASS  USAGE mode: usage and cost without input or output  — input '' · output '' · cost 1.3e-05
PASS  AI Gateway role cannot add a provider credential  — HTTP 403 FORBIDDEN
INFO  audit log entries for gateway keys (OSS, no licence)  — Postgres audit_logs 0 · ClickHouse audit_logs 0
PASS  v2 observations API returns the s1 generation  — HTTP 200 · [('GENERATION', 'anthropic.messages', 'e508359eb108fdb5')]
── 29 PASS · 3 FAIL · 3 INFO
exit 1
```

## 06 — audit log, OSS and EE

```text
$ 06-ee-audit.sh
▶ OSS mode: create and revoke a key
  oss: key cmw28ynuu0014o23zr7j4215b · audit records Postgres [] · ClickHouse []
▶ restarting web and worker with the EE overlay
▶ EE mode: create and revoke a key
  ee: key cmw28zg7n0003ln3t79rxg1sj · audit records Postgres [create,delete] · ClickHouse []
▶ back to OSS mode
PASS  OSS (no licence): no audit records for a created and revoked gateway key
PASS  EE licence: create and delete are recorded — Postgres [create,delete] · ClickHouse []
exit 0
```

The ClickHouse `audit_logs` table stays empty on a self-hosted instance in this run; in 4.75.0 its staging relay is described as the Langfuse Cloud path (`LANGFUSE_AUDIT_LOG_STAGING_ENABLED` in `web/src/env.mjs`). The Postgres `audit_logs` row is the record.

## UI after the run

**Organization settings → AI Gateway → Gateway keys** lists `alice-laptop`, `checkout-service` (Service account), `alice-short` (Expired) and the new `bob-laptop`. **Analytics** shows cost by user (Alice, Bob; service keys excluded), by gateway key and by model. Keys that were revoked (`bob-temp`) or deleted by the role change (the first `bob-laptop`) appear there as IDs (`cmw28wvvm…`, `cmw28vowa…`), because their rows are gone; each generation still carries the key name in `langfuse.gateway.api_key.name`.

---

# Second run, with LiteLLM Proxy (#89)

Run on **2026-11-05** (KST; model calls 2026-11-05 03:15–03:21 UTC), from deleted volumes, same host and tools as above. Images as above plus `ghcr.io/berriai/litellm:v1.108.0` (`sha256:c560d317136880ea92d62334d4367ab10955b1af189dd3ea24f6551290b1d6c1`, cosign signature not verified: cosign not installed) and `postgres:17.11` for LiteLLM's database. The first `07-litellm-up.sh` start crash-looped: the config bind mount was relative and Compose resolved it against `_base/`, so Docker mounted an empty directory (`IsADirectoryError: '/app/config.yaml'`). Fixed in `docker-compose.litellm.yml`, stray directory removed, LiteLLM restarted; nothing had reached it.

Model calls of this run as Langfuse priced them: gateway 23 generations 0.04015 USD, LiteLLM 27 generations 0.01369 USD (the fault run added 6 more, 0.01393 USD in all); plus 6 direct calls to Anthropic for the latency sample, which Langfuse does not see.

```text
$ 01-up.sh
▶ generated gateway service key and JWT signing key in <clone>/labs/v4/ai-gateway/.run
▶ Starting lf-gateway-lab (Langfuse 4.75.0 web · worker · ai-gateway + backends)…
▶ Waiting for web (first boot runs the Postgres and ClickHouse migrations)…
  web healthy after ~15 s
  gateway /health → {"status":"ok"}
  gateway /ready → {"status":"ready"}
  versions: web docker.io/langfuse/langfuse:4.75.0 · gateway image docker.io/langfuse/ai-gateway:4.75.0
✅ UI http://localhost:13000 · gateway http://localhost:18480 — next: 02-setup.py
$ 07-litellm-up.sh
▶ generated LiteLLM master key and salt key in <clone>/labs/v4/ai-gateway/.run
▶ Starting LiteLLM v1.108.0 and its Postgres…
  LiteLLM live after ~78 s
  image: ghcr.io/berriai/litellm:v1.108.0
✅ LiteLLM http://localhost:18440 (UI /ui, user admin, password = .run/litellm-master-key) — next: 08-litellm-setup.py
$ 02-setup.py
✓ alice@example.com added with org role AI_GATEWAY
✓ bob@example.com added with org role AI_GATEWAY
✓ gateway config: project llm-observability · mode FULL
✓ provider credential anthropic-lab created: status ENABLED, shown in the UI as sk-ant...<last 4>
✓ key alice-laptop (user, by alice) sk-lf-3daa… metadata {'team': 'platform', 'cost_center': '1001'}
✓ key bob-laptop (user, by bob) sk-lf-0a52… metadata {'team': 'data', 'cost_center': '2002'}
✓ key checkout-service (serviceAccount, by owner) sk-lf-f52f… metadata {'team': 'payments', 'cost_center': '3003'}
✓ GET /anthropic/v1/models with alice's key: HTTP 200, 14 models, e.g. ['anthropic-lab:claude-fable-5', 'anthropic-lab:claude-fable-5-1', 'anthropic-lab:claude-haiku-4-5-20251001', 'anthropic-lab:claude-haiku-5-5']
$ 08-litellm-setup.py
✓ internal user alice (alice@example.com)
✓ internal user bob (bob@example.com)
✓ team payments
✓ key alice-laptop via /key/generate: user_id alice · team_id None · sk-Lr7D…
✓ key bob-laptop via /key/generate: user_id bob · team_id None · sk-fKU1…
✓ key checkout-service via /key/service-account/generate: user_id None · team_id payments · sk-FVp8…
✓ /v1/models: ['claude-haiku-4-5', 'claude-haiku-4-5-20251001', 'haiku-broken']
$ 03-calls.py
✓ s1-sdk-basic         HTTP 200 claude-haiku-4-5-20251001 {'input': 15, 'output': 5} trace 9882bacdcf1013c698eb8523136883f1 'pong'
✓ s2-sdk-stream        HTTP 200 claude-haiku-4-5-20251001 {'input': 15, 'output': 5} trace 644bcc8eec248e7a1aa2b270cd7da3a0 'pong'
✓ s3-user-key-override HTTP 200 claude-haiku-4-5-20251001 {'input': 15, 'output': 5} trace 946dd6f52f2214be21a78c3379e6dcd2 'pong'
✓ s4-service-end-user  HTTP 200 claude-haiku-4-5-20251001 {'input': 15, 'output': 5} trace aeae37622ea93a3eb999c14f8d5107ca 'pong'
✓ s5-service-default   HTTP 200 claude-haiku-4-5-20251001 {'input': 15, 'output': 5} trace b6e6ac3420cd947912f8ca15fbef1de0 'pong'
✓ s6-sdk-traceparent   HTTP 200 claude-haiku-4-5-20251001 {'input': 15, 'output': 5} trace 2b9a27e3a64d01f642b189abdc4e1aac 'pong'
✓ s7-claude-code      exit 0 (2.1.220 (Claude Code)) 'hello gateway'
→ run 79c4ea04 recorded in .run/state.json — next: 04-controls.py, then 05-check.py
$ 04-controls.py
A allowlist   listed ['anthropic-lab:claude-haiku-4-5-20251001'] · dated 200 · alias 403 · prefixed 200 · other 403 · after reset 200
B expiry      before 200 · 401 reached True 0.1 s after expiresAt (1 calls)
C revocation  before [200, 200] · 401 reached True 0.0 s after revoke (1 calls)
D role change before 200 · VIEWER → 401 after 0.0 s · key rows left 0 · back to AI_GATEWAY: old key 401 · new key 200
E USAGE mode  HTTP 200 trace cfdebcb8bd6e8469d6a332e6fee683a1 (mode back to FULL)
· AI Gateway role → createConnection: {'allowed': False, 'status': 403, 'code': 'FORBIDDEN'}
→ recorded in .run/state.json — next: 05-check.py
$ 05-check.py
── run 79c4ea04 · Langfuse 4.75.0
PASS  s1 Anthropic SDK through the gateway answers like Anthropic  — HTTP 200, 'pong', provider header anthropic, Anthropic request-id req_011Cgj472xqHx62jAJYiFmPY
PASS  s1 response header langfuse-trace-id points at a stored generation  — trace 9882bacdcf1013c698eb8523136883f1
PASS  s1 generation: API format as name, the provider's dated model  — anthropic.messages · claude-haiku-4-5-20251001 (requested claude-haiku-4-5)
PASS  s1 usage and cost recorded  — usage {'cache_read_input_tokens': 0, 'input_tokens': 15, 'output_tokens': 5, 'input_cache_creation_5m': 0, 'input_cache_creation_1h': 0, 'total': 20} · cost total 4e-05 USD
PASS  s1 FULL mode stores input and output  — input {"messages":[{"role":"user","content":"Reply with exactly one word: po…
PASS  s1 user key → trace user is the key owner  — user alice@example.com · source api_key_owner
PASS  s1 key name and key metadata on the generation  — key alice-laptop · team platform · cost_center 1001
PASS  s2 streamed call: output and time to first token recorded  — start 2026-11-05 03:15:33.134000 · first token 2026-11-05 03:15:33.638000
PASS  s3 user key ignores langfuse-user-id: mallory@example.com  — user bob@example.com
PASS  s4 service account key + langfuse-user-id → end user  — user end-user-42 · source client
PASS  s4 session, environment, tags and trace name from headers  — checkout-79c4ea04 · production · ['checkout', 'beta'] · checkout-summary
PASS  s4 request metadata next to the key's own metadata  — order A-1001 · region kr · cost_center 3003
PASS  s5 service account key without headers → key name as user  — user checkout-service
PASS  s6 gateway reuses the app's trace ID from traceparent  — gateway 2b9a27e3a64d01f642b189abdc4e1aac · app 2b9a27e3a64d01f642b189abdc4e1aac
PASS  s6 generation is a child of the app's span  — parent 3d141d9377e117d9 · app span 3d141d9377e117d9
PASS  s6 the app's own span is in the same trace  — {'name': 'checkout-request', 'service_name': 'checkout-app'}
PASS  s7 claude -p through the gateway  — 2.1.220 (Claude Code) · exit 0 · 'hello gateway'
PASS  s7 Claude Code calls: session claude-code:<id>, agent.name claude-code, user = key owner  — 1 generations · 1 traces · 1 session · models ['claude-haiku-4-5-20251001'] · input tokens [10] · claude-cli/2.1.220 (external, sdk-cli)
PASS  cost per user, key and model from events_full (one GROUP BY)  — 7 groups
        alice@example.com      alice-laptop     platform  claude-haiku-4-5-20251001      7 calls  0.039846 USD
        bob@example.com        bob-laptop       data      claude-haiku-4-5-20251001      3 calls  0.000066 USD
                               checkout-service payments  claude-haiku-4-5-20251001      1 calls  0.000040 USD
        checkout-service       checkout-service payments  claude-haiku-4-5-20251001      1 calls  0.000040 USD
        end-user-42            checkout-service payments  claude-haiku-4-5-20251001      1 calls  0.000040 USD
        bob@example.com        bob-temp         data      claude-haiku-4-5-20251001      2 calls  0.000026 USD
        alice@example.com      alice-short      platform  claude-haiku-4-5-20251001      1 calls  0.000013 USD
PASS  provider key is stored encrypted in Postgres (gateway_ai_connections)  — UI shows sk-ant...<last 4> · stored value 274 chars
PASS  gateway keys are not stored in plain text (pg_dump of api_keys)  — 40 lines searched
PASS  gateway container has no provider key in its environment  — 7 variables
PASS  allowlist: the model list shows only the allowed model  — ['anthropic-lab:claude-haiku-4-5-20251001']
PASS  allowlist: allowed dated ID passes, with and without prefix  — 200 / 200
PASS  allowlist: another model is refused before the provider  — HTTP 403 permission_error Model is not allowed for this provider connection
INFO  allowlist: the alias of the allowed model (claude-haiku-4-5)  — HTTP 403 permission_error Model is not allowed for this provider connection
PASS  allowlist reset to all models: alias works again  — HTTP 200
PASS  expiry: key works, then 401 within 10 s of expiresAt  — 401 after 0.1 s, 1 calls
PASS  revocation: the first call after revoke gets 401  — 401 after 0.0 s on call 1
PASS  role change to VIEWER: the user key stops on the next call  — 401 after 0.0 s
PASS  role change to VIEWER deletes the user's gateway keys  — api_keys rows left: 0
PASS  role back to AI_GATEWAY: the old key stays dead, a new key works  — old 401 · new 200
PASS  USAGE mode: usage and cost without input or output  — input '' · output '' · cost 1.3e-05
PASS  AI Gateway role cannot add a provider credential  — HTTP 403 FORBIDDEN
INFO  audit log entries for gateway keys (OSS, no licence)  — Postgres audit_logs 0 · ClickHouse audit_logs 0
PASS  v2 observations API returns the s1 generation  — HTTP 200 · [('GENERATION', 'anthropic.messages', '703e2c5d0fbd81a0')]
── 34 PASS · 0 FAIL · 2 INFO
05 exit 0
$ 09-litellm-calls.py
✓ l1-sdk-basic         HTTP 200 claude-haiku-4-5 {'input': 15, 'output': 5} call 3b0a9de7-ceca-4a9c-8430-0db033daebbf cost 3.9999999999999996e-05 'pong'
✓ l2-sdk-stream        HTTP 200 claude-haiku-4-5 {'input': 15, 'output': 5} call 5758a276-9e33-4fc3-bdc8-11ab7249f501 cost None 'pong'
✓ l3-user-override     HTTP 200 claude-haiku-4-5 {'input': 15, 'output': 5} call 5af03200-a002-4772-aab4-c346102ed01d cost 3.9999999999999996e-05 'pong'
✓ l4-service-end-user  HTTP 200 claude-haiku-4-5 {'input': 15, 'output': 5} call 745df5d4-6ce2-4de0-9b2b-9d682e959d47 cost 3.9999999999999996e-05 'pong'
✓ l5-service-default   HTTP 200 claude-haiku-4-5 {'input': 15, 'output': 5} call bd51ae83-bd06-47d3-aabf-63768b66d6df cost 3.9999999999999996e-05 'pong'
✓ l6-sdk-traceparent   HTTP 200 claude-haiku-4-5 {'input': 15, 'output': 6} call 9bea10f4-4724-4234-b12b-e03e08deebdb cost 4.5e-05 'Pong'
✓ l7-claude-code       exit 0 'hello gateway' 
A models      dated 200 · alias 403 key_model_access_denied The requested model 'claude-haiku-4-5' is not available for this A
B expiry      before 200 · 401 reached True 0.1 s after expiry (1 calls)
C revocation  before [200, 200] · 401 reached True 0.0 s after delete (1 calls)
D user delete before 200 · 401 reached True 0.0 s after user delete (1 calls) · key/info 404
E spend cap   [(1, 200, '1.3000000000000001e-05'), (2, 200, '1.3000000000000001e-05'), (3, 200, '1.3000000000000001e-05'), (4, 200, '1.3000000000000001e-05'), (5, 200, '1.3000000000000001e-05'), (6, 422, None)] · budget_exceeded Budget has been exceeded! Key=alice-budget (sk-...i_Qw) Current cost: 6.500000000000
F rate limit  rpm 2 → [200, 200, 429]
G fallback    LiteLLM haiku-broken → 200 (attempted fallbacks 1) · gateway unknown model → 404 not_found_error model: claude-haiku-4-5-does-not-exist
H latency     direct median 610 ms [610, 676, 623, 586, 607] · langfuse_gateway median 526 ms [545, 526, 530, 526, 518] · litellm median 547 ms [527, 548, 531, 550, 547]
→ run 58056950 recorded in .run/state.json — next: 10-compare-check.py
09 exit 0
$ 10-compare-check.py
── LiteLLM run 58056950 · LiteLLM ghcr.io/berriai/litellm:v1.108.0
PASS  l1 Anthropic SDK through LiteLLM; generation exported to Langfuse  — HTTP 200 'pong' · chat claude-haiku-4-5
PASS  l1 key alias, key owner, cost, input and output on the generation  — alias alice-laptop · owner alice · cost 3.9999999e-05 · input [{"role": "user", "content": "Reply with exactly o
INFO  l1 model in the response LiteLLM returns vs Anthropic's  — client got 'claude-haiku-4-5' · Anthropic answered 'claude-haiku-4-5-20251001'
PASS  l2 streamed call exported with output  — [{"content": "pong", "role": "assistant", "tool_calls": null
PASS  l3 key owner stays bob; x-litellm-end-user-id is recorded as a separate end user  — owner bob · end user mallory@example.com
PASS  l4 service account key: end user, team and tags  — end user end-user-42 · team payments · tags ['checkout', 'beta']
PASS  l5 service account key without headers: key alias only  — alias checkout-service
INFO  Langfuse user field on LiteLLM generations (identity is in metadata)  — 0 of 27 generations have user_id
PASS  l6 LiteLLM generation lands in the app's trace (traceparent)  — generation trace c30ef3c26e655e252b59228888341797 · app c30ef3c26e655e252b59228888341797
INFO  l6 parent of the LiteLLM generation  — parent '' · app span d8723ad9634c526c
PASS  l7 claude -p through LiteLLM; generations carry Claude Code's session  — 1 generations · sessions ['8550a4df'] · cost [0.0132]
PASS  model restriction by exact name: dated ID allowed, alias refused  — dated 200 · alias 403 key_model_access_denied The requested model 'claude-haiku-4-5' is not 
PASS  expiry: 401 within 10 s of the 40 s duration  — 0.1 s, 1 calls
PASS  key delete: the first call after it gets 401  — 0.0 s
PASS  user delete: the user's key stops and is gone  — 401 after 0.0 s · key/info 404
PASS  spend cap: a call over max_budget is refused  — max_budget 6e-05 · call 6 → 422 budget_exceeded Budget has been exceeded! Key=alice-budget (sk-...i_Qw) Current cost: 6.50
PASS  rate limit: rpm_limit 2, third call in the minute gets 429  — [200, 200, 429]
PASS  fallback: haiku-broken fails, LiteLLM answers from claude-haiku-4-5  — HTTP 200 · attempted fallbacks 1
PASS  gateway with a failing model: the error goes to the client (no fallback setting)  — HTTP 404 not_found_error model: claude-haiku-4-5-does-not-exist
INFO  latency, 5 calls each after one warm-up (client-side ms, same host)  — direct 610 · langfuse_gateway 526 · litellm 547
PASS  LiteLLM stores virtual keys hashed (pg_dump of its database)  — 1182 lines searched
INFO  provider key in the LiteLLM container's environment (as this lab configures it)  — present: True
INFO  LiteLLM audit log without a licence  — LiteLLM_AuditLog rows: 0
INFO  generations and cost per gateway in this Langfuse project  — langfuse-ai-gateway 23 calls 0.04015 USD · litellm 27 calls 0.01369 USD
── 17 PASS · 0 FAIL · 7 INFO
```

The first `10-compare-check.py` run stopped on a Python `and` chain returning a string instead of a boolean; fixed in `check()`, re-run on the same data, output above.

## Injected fault, LiteLLM side

`.run/state.json` copied aside; `09-litellm-calls.py` with `FAULT=1` (l4 without `x-litellm-end-user-id`, l6 without `traceparent`; controls skipped, their last results kept) and without Claude Code; `10-compare-check.py`; the copy put back. Before this run, `09-litellm-calls.py` was changed so that `FAULT=1` skips the controls (the controls block indented under `if not FAULT`, no other change).

```text
$ FAULT=1 SKIP_CLAUDE_CODE=1 09-litellm-calls.py
✓ l1-sdk-basic         HTTP 200 claude-haiku-4-5 {'input': 15, 'output': 5} call 5a9004c4-9610-4181-9338-840da31909a3 cost 3.9999999999999996e-05 'pong'
✓ l2-sdk-stream        HTTP 200 claude-haiku-4-5 {'input': 15, 'output': 5} call c5ace6ba-ba4a-4fbc-8505-52d640c1128f cost None 'pong'
✓ l3-user-override     HTTP 200 claude-haiku-4-5 {'input': 15, 'output': 5} call e4c566a8-4bd9-49d8-b1b8-e41ea3a2044a cost 3.9999999999999996e-05 'pong'
✓ l4-service-end-user  HTTP 200 claude-haiku-4-5 {'input': 15, 'output': 5} call 85c7a24c-42c0-47d6-8b1a-30f89549bf7f cost 3.9999999999999996e-05 'pong'
✓ l5-service-default   HTTP 200 claude-haiku-4-5 {'input': 15, 'output': 5} call 97a6f110-c174-4ca2-8227-89f8a1a9bc75 cost 3.9999999999999996e-05 'pong'
✓ l6-sdk-traceparent   HTTP 200 claude-haiku-4-5 {'input': 15, 'output': 5} call 396d6c63-1a7b-4b56-a5bd-11b837d3631b cost 3.9999999999999996e-05 'pong'
→ run 7d041fc3 (FAULT) recorded in .run/state.json — next: 10-compare-check.py
$ 10-compare-check.py
── LiteLLM run 7d041fc3 (FAULT) · LiteLLM ghcr.io/berriai/litellm:v1.108.0
PASS  l1 Anthropic SDK through LiteLLM; generation exported to Langfuse  — HTTP 200 'pong' · chat claude-haiku-4-5
PASS  l1 key alias, key owner, cost, input and output on the generation  — alias alice-laptop · owner alice · cost 3.9999999e-05 · input [{"role": "user", "content": "Reply with exactly o
INFO  l1 model in the response LiteLLM returns vs Anthropic's  — client got 'claude-haiku-4-5' · Anthropic answered 'claude-haiku-4-5-20251001'
PASS  l2 streamed call exported with output  — [{"content": "pong", "role": "assistant", "tool_calls": null
PASS  l3 key owner stays bob; x-litellm-end-user-id is recorded as a separate end user  — owner bob · end user mallory@example.com
FAIL  l4 service account key: end user, team and tags  — end user  · team payments · tags ['checkout', 'beta']
PASS  l5 service account key without headers: key alias only  — alias checkout-service
INFO  Langfuse user field on LiteLLM generations (identity is in metadata)  — 0 of 33 generations have user_id
FAIL  l6 LiteLLM generation lands in the app's trace (traceparent)  — generation trace 2020c6c5c48af5e35980594109dfb43f · app 9db6298eceb755d5bfc2d1c760ad9472
INFO  l6 parent of the LiteLLM generation  — parent '' · app span 0bdbdfbe1f7d3a7e
INFO  l7 Claude Code not run
PASS  model restriction by exact name: dated ID allowed, alias refused  — dated 200 · alias 403 key_model_access_denied The requested model 'claude-haiku-4-5' is not 
PASS  expiry: 401 within 10 s of the 40 s duration  — 0.1 s, 1 calls
PASS  key delete: the first call after it gets 401  — 0.0 s
PASS  user delete: the user's key stops and is gone  — 401 after 0.0 s · key/info 404
PASS  spend cap: a call over max_budget is refused  — max_budget 6e-05 · call 6 → 422 budget_exceeded Budget has been exceeded! Key=alice-budget (sk-...i_Qw) Current cost: 6.50
PASS  rate limit: rpm_limit 2, third call in the minute gets 429  — [200, 200, 429]
PASS  fallback: haiku-broken fails, LiteLLM answers from claude-haiku-4-5  — HTTP 200 · attempted fallbacks 1
PASS  gateway with a failing model: the error goes to the client (no fallback setting)  — HTTP 404 not_found_error model: claude-haiku-4-5-does-not-exist
INFO  latency, 5 calls each after one warm-up (client-side ms, same host)  — direct 610 · langfuse_gateway 526 · litellm 547
PASS  LiteLLM stores virtual keys hashed (pg_dump of its database)  — 1187 lines searched
INFO  provider key in the LiteLLM container's environment (as this lab configures it)  — present: True
INFO  LiteLLM audit log without a licence  — LiteLLM_AuditLog rows: 0
INFO  generations and cost per gateway in this Langfuse project  — langfuse-ai-gateway 23 calls 0.04015 USD · litellm 33 calls 0.01393 USD
── 14 PASS · 2 FAIL · 8 INFO
exit 1
```

After restoring the state, `10-compare-check.py` again: 17 PASS · 0 FAIL · 7 INFO (the cost row now includes the fault run's 6 calls).

After the run, for the pre-commit guard: the LiteLLM database credentials in `docker-compose.litellm.yml` became variables whose defaults are the values the run used (`docker compose config` resolves to the same `DATABASE_URL`, user and password; LiteLLM was not restarted), and one f-string in `10-compare-check.py` was rewritten for Python 3.9. `10-compare-check.py` re-run on the same data: 17 PASS · 0 FAIL · 7 INFO.
