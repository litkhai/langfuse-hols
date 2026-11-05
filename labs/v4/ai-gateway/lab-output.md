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
