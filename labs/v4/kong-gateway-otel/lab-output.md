# kong-gateway-otel — execution log

Captured on 2026-11-04 from a torn-down lab (`99-down.sh` first), Kong Gateway OSS 3.9.4 and
`kong/kong-gateway` 3.14.0.16 (no licence) against Langfuse v4.56.0 / SDK 4.17.0 /
ClickHouse 26.8.22.13, Docker 29.9.2, Compose v5.6.1, Python 3.12.14, mock model only.
Default `KONG_TRACING_INSTRUMENTATIONS=request,balancer`. Trace IDs differ on every run.

## Run 1 — steps 01–05 and 99, default settings

```text
run started 2026-11-04T08:42:14Z
$ ./01-up.sh
admin :18001  Kong 3.9.4
admin :18101  Kong 3.9.4
$ ./02-model-gateway.sh
/raw  trace a23b75024ca12de267506d6b0584c844  answer: mock reply to: hello through /raw
/chat  trace 4a62e08594a1b0d82e9c1a84fc30a0db  answer: mock reply to: hello through /chat
$ .venv-v4/bin/python 03-agent-through-gateways.py
agent  trace 3fb03f4a202d3c311e6109afccd4875f  answer: mock reply to: Can I get a refund?
$ .venv-v4/bin/python 04-check.py
PASS  raw: Kong OSS spans arrive  (2 spans, root 'kong')
PASS  raw: no generation without the bridge
PASS  raw: no user/session without the bridge
PASS  raw: no model, usage or prompt on any span
PASS  chat: exactly one generation  (chat mock-gpt)
PASS  chat: model from ai-proxy  (mock-gpt)
PASS  chat: usage input/output/total  ({'input': 14, 'output': 6, 'total': 20})
PASS  chat: prompt and response bodies
PASS  chat: header metadata on the generation  ({'agent_id': 'none', 'project_id': 'demo-project', 'gateway': 'model'})
PASS  chat: user and session on every span  (3 spans)
PASS  agent: both gateways and the SDK in one trace  (kong-agent-gateway, kong-model-gateway, support-agent)
PASS  agent: one root, the agent gateway's span  (1 root(s))
PASS  agent: SDK agent span is a child of the agent gateway  (kong.balancer)
PASS  agent: model gateway's span is a child of the SDK agent span
PASS  agent: generation under the model gateway
PASS  agent: user and session on all spans of all three producers  (7 spans)
PASS  api: same observation count as events_full  (api 7, events_full 7)
PASS  api: generation with model and usage  (mock-gpt {'input': 16, 'output': 8, 'total': 24})

trace tree (agent scenario, 7 observations; kong.* internal spans not shown):
  kong  [SPAN, kong-agent-gateway]
    support-agent  [AGENT, support-agent]
      lookup-policy  [TOOL, support-agent]
      kong  [SPAN, kong-model-gateway]
        chat mock-gpt  [GENERATION, kong-model-gateway]

all checks passed
(exit 0)
$ ./05-ee-compare.sh
ee /raw  trace 3c8e06359216d9e3dd60e5496c9c2451  (Kong 3.14.0.16)
Row 1:
──────
name:                chat mock-gpt
type:                GENERATION
user_id:             
provided_model_name: mock-gpt
usage_details:       {'input':16,'output':8,'total':24}
input:               ["{\"kvlistValue\":{\"values\":[{\"key\":\"role\",\"value\":{\"stringValue\":\"user\"}},{\"key\":\"parts\",\"value\":{\"arrayValue\":{\"values\":[{\"kvlistValue\":{\"values\":[{\"key\":\"type\",\"value\":{\"stringValue\":\"text\"}},{\"key\":\"content\",\"value\":{\"stringValue\":\"hello through the enterprise image\"}}]}}]}}}]}}"]
output:              ["{\"kvlistValue\":{\"values\":[{\"key\":\"parts\",\"value\":{\"arrayValue\":{\"values\":[{\"kvlistValue\":{\"values\":[{\"key\":\"type\",\"value\":{\"stringValue\":\"text\"}},{\"key\":\"content\",\"value\":{\"stringValue\":\"mock reply to: hello through the enterprise image\"}}]}}]}}},{\"key\":\"finish_reason\",\"value\":{\"stringValue\":\"stop\"}},{\"key\":\"role\",\"value\":{\"stringValue\":\"assistant\"}}]}}"]
gen_ai_attributes:   ['attributes.gen_ai.response.finish_reasons','attributes.gen_ai.response.id','attributes.gen_ai.response.model','attributes.gen_ai.provider.name','attributes.gen_ai.request.model','attributes.gen_ai.operation.name','attributes.gen_ai.usage.output_tokens','attributes.gen_ai.output.type','attributes.gen_ai.usage.input_tokens']
$ ./99-down.sh
down
```

## Run 2 — `KONG_TRACING_INSTRUMENTATIONS=all` (same day, same files)

Steps 01–04 again with the containers recreated; only the lines that change are shown.

```text
PASS  raw: Kong OSS spans arrive  (8 spans, root 'kong.router')
PASS  chat: user and session on every span  (11 spans)
PASS  agent: user and session on all spans of all three producers  (21 spans)
trace tree (agent scenario, 21 observations; kong.* internal spans not shown):
all checks passed
```

## Run 3 — injected fault: the agent does not extract `traceparent`

A copy of step 03 with `propagate.extract(incoming)` replaced by the current (empty) context,
then step 04. The checks that depend on propagation fail, the others pass; the copy was deleted afterwards.

```text
FAIL  agent: both gateways and the SDK in one trace  (kong-agent-gateway)
FAIL  agent: SDK agent span is a child of the agent gateway
FAIL  agent: model gateway's span is a child of the SDK agent span
FAIL  agent: generation under the model gateway
FAIL  api: generation with model and usage
5 check(s) failed
```

Run 3 was repeated with the final scripts after run 1 (the lab brought up again, step 02, the
fault copy, step 04, `99-down.sh`); the lines above are from that repeat. Step 04 exited 1.
