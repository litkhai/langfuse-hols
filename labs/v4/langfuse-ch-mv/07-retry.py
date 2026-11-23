#!/usr/bin/env python3
"""07-retry.py — one trace exported twice with the same span ids, as an OTLP exporter does when it retries.

An exporter that gets no answer (a timeout, a reset connection) sends the same batch again. Langfuse accepts both
requests; this script reproduces that with the OpenTelemetry SDK alone: it records two spans (a root span and a
generation) in memory, then sends that one batch to Langfuse's OTLP endpoint twice, 15 s apart, so that the
worker writes them in separate inserts. The attributes are the ones the Langfuse SDK sets
(langfuse/_client/attributes.py of SDK 4.17.0). Prints the trace id.
"""
import base64
import json
import os
import time

from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

host, pk, sk = os.environ["LANGFUSE_HOST"], os.environ["LANGFUSE_PUBLIC_KEY"], os.environ["LANGFUSE_SECRET_KEY"]
memory = InMemorySpanExporter()
provider = TracerProvider(resource=Resource.create({"service.name": "support-chat"}))
provider.add_span_processor(SimpleSpanProcessor(memory))
tracer = provider.get_tracer("langfuse-sdk", "4.17.0", attributes={"public_key": pk})

trace_attrs = {
    "langfuse.trace.name": "상담-응답",
    "user.id": "emp-retry",
    "session.id": "support-chat-retry",
    "langfuse.trace.tags": ["svc:support-chat", "team:cx", "env:production", "lab:langfuse-ch-mv", "review:needed"],
    "langfuse.trace.metadata.batch": "retry",
}
with tracer.start_as_current_span("상담-응답", attributes={
        **trace_attrs, "langfuse.observation.type": "span",
        "langfuse.observation.input": json.dumps({"질문": "재전송된 요청도 한 번만 집계되나요?"}, ensure_ascii=False)}) as root:
    with tracer.start_as_current_span("답변-생성", attributes={
            **trace_attrs, "langfuse.observation.type": "generation",
            "langfuse.observation.model.name": "gpt-4o-mini",
            "langfuse.observation.usage_details": json.dumps({"input": 1000, "output": 200}),
            "langfuse.observation.output": "같은 span id로 두 번 기록됩니다."}):
        time.sleep(0.2)
    trace_id = format(root.get_span_context().trace_id, "032x")
spans = memory.get_finished_spans()

auth = base64.b64encode(f"{pk}:{sk}".encode()).decode()
exporter = OTLPSpanExporter(endpoint=f"{host}/api/public/otel/v1/traces",
                            headers={"Authorization": f"Basic {auth}", "x-langfuse-public-key": pk})
for attempt in (1, 2):
    result = exporter.export(spans)
    print(f"export {attempt}: {result.name} ({len(spans)} spans)", flush=True)
    if attempt == 1:
        time.sleep(15)
print(trace_id)
