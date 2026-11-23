#!/usr/bin/env python3
"""02 — seed 14 KST days of Korean-language traces for four services of three teams, plus scores.

Offline: no model is called. Spans go to Langfuse's OTLP endpoint (/api/public/otel/v1/traces) with the
attributes the Python SDK writes (langfuse.observation.*, langfuse.trace.*, user.id, session.id), sent
through the OpenTelemetry SDK directly because the Langfuse SDK has no start_time argument and these
traces are back-dated. Each service has its own TracerProvider, so `service.name` (the service_name
column) differs per service. Langfuse computes cost from its model price table, as for real traffic.

Every observation carries environment `lab-ch-dashboard` and tag `lab:langfuse-ch-dashboard`.
Scores (user-feedback BOOLEAN, judge-faithfulness NUMERIC) go through /api/public/ingestion with their
own timestamps. IDs come from a seeded generator. If ClickHouse already holds traces of this lab in
the window, nothing is sent: a second send of the same spans would sit in Langfuse's ReplacingMergeTree
tables twice until a merge, and the panels (no FINAL) would count them twice. --force sends anyway.

  python 02-seed.py [--end YYYY-MM-DD] [--days 14] [--scale 1.0] [--force]

--end is the last KST day of the window (default: yesterday in KST).
"""

from __future__ import annotations

import argparse
import base64
import json
import math
import random
import sys
import time
from datetime import date, datetime, timedelta, timezone

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.trace.id_generator import IdGenerator

from lablib import ENVIRONMENT, HOST, PK, SK, TAG, api, ch

KST = timezone(timedelta(hours=9))
rng = random.Random(20261123)

# Share of a weekday's traffic per KST hour (00..23): quiet nights, peaks at 10-11 and 14-16.
HOURLY = [1, 0.6, 0.4, 0.3, 0.3, 0.5, 1, 2, 4, 7, 9, 9, 6, 7, 9, 9, 8, 6, 4, 3, 3, 2.5, 2, 1.5]

# service -> team, model, traces per weekday, (input tokens), (output tokens), ms per output token,
# prompt versions by day index (version from that day on), base failure rate per prompt version.
SERVICES = {
    "loan-advisor": dict(team="retail-ai", model="gpt-4.1-mini", per_day=140, tin=(1200, 2500),
                         tout=(150, 400), ms_tok=12, versions={0: 1, 5: 2, 10: 3},
                         fail={1: 0.02, 2: 0.02, 3: 0.09}, users="cust", n_users=220, channels=["app", "web"]),
    "card-faq": dict(team="card-ai", model="claude-haiku-4-5-20251001", per_day=110, tin=(600, 1200),
                     tout=(80, 200), ms_tok=8, versions={0: 1, 7: 2}, fail={1: 0.03, 2: 0.015},
                     users="cust", n_users=260, channels=["app", "web"]),
    "doc-summary": dict(team="ops-ai", model="gpt-4o", per_day=30, tin=(6000, 15000), tout=(400, 900),
                        ms_tok=20, versions={0: 1}, fail={1: 0.03}, users="emp", n_users=40,
                        channels=["intranet"]),
    "policy-search": dict(team="ops-ai", model="claude-sonnet-4-5-20250929", per_day=50, tin=(2000, 4000),
                          tout=(200, 500), ms_tok=18, versions={0: 1, 3: 2}, fail={1: 0.02, 2: 0.02},
                          users="emp", n_users=60, channels=["intranet"]),
}

QUESTIONS = {
    "loan-advisor": ["전세자금대출 한도가 어떻게 되나요?", "신용대출 금리를 낮추려면 무엇을 준비해야 하나요?",
                     "중도상환수수료 면제 조건이 있나요?", "주택담보대출 갈아타기 절차를 알려 주세요.",
                     "사업자 대출에 필요한 서류는 무엇인가요?", "대출 만기 연장은 언제부터 신청할 수 있나요?",
                     "청년 전용 대출 상품이 있나요?", "금리인하요구권은 어떻게 신청하나요?"],
    "card-faq": ["해외 결제 수수료는 얼마인가요?", "카드 분실 신고는 어디서 하나요?", "연회비는 언제 청구되나요?",
                 "포인트 유효기간이 지나면 어떻게 되나요?", "결제일을 바꿀 수 있나요?", "할부 수수료율을 알려 주세요.",
                 "교통카드 기능은 어떻게 켜나요?", "가족카드를 추가로 발급할 수 있나요?"],
    "doc-summary": ["3분기 리스크관리위원회 회의록을 요약해 주세요.", "신규 여신 심사 기준 변경안 요약 부탁합니다.",
                    "IT 운영 장애 보고서를 다섯 줄로 정리해 주세요.", "내부통제 점검 결과 보고서를 요약해 주세요.",
                    "디지털 채널 고객 불만 분석 자료를 요약해 주세요."],
    "policy-search": ["재택근무 신청 기준이 어떻게 되나요?", "출장비 정산 기한은 언제까지인가요?",
                      "개인정보 취급자 교육 주기는?", "외부 메일 첨부파일 반출 규정을 알려 주세요.",
                      "연차 이월 규정이 있나요?", "고객정보 조회 권한 신청 절차는?"],
}
ANSWERS = {
    "loan-advisor": "상품 설명서 기준으로 안내드립니다. 한도와 금리는 신용평점과 소득에 따라 달라지며, 자세한 조건은 영업점이나 앱에서 확인하실 수 있습니다.",
    "card-faq": "약관 제12조에 따라 안내드립니다. 앱의 카드 관리 메뉴에서 바로 처리하실 수 있습니다.",
    "doc-summary": "1) 주요 결정 사항 2) 수치 변화 3) 후속 조치 4) 담당 부서 5) 다음 점검 일정 순으로 요약했습니다.",
    "policy-search": "사내 규정 제4장 제18조에 해당합니다. 시행일은 2026-07-01이며 직전 개정은 2025-12-15입니다.",
}
ERRORS = ["upstream model timeout", "응답 JSON 파싱 실패", "가드레일 차단: 개인정보 포함 응답"]


class SeededIds(IdGenerator):
    def generate_span_id(self) -> int:
        return rng.getrandbits(64) or 1

    def generate_trace_id(self) -> int:
        return rng.getrandbits(128) or 1


def ns(dt: datetime) -> int:
    return int(dt.timestamp() * 1_000_000_000)


def version_on(svc: dict, day_idx: int) -> int:
    return [v for d, v in sorted(svc["versions"].items()) if d <= day_idx][-1]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--end", help="last KST day of the window, YYYY-MM-DD (default: yesterday KST)")
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--scale", type=float, default=1.0, help="multiplies traces per day")
    ap.add_argument("--force", action="store_true", help="send even if the window is already seeded")
    a = ap.parse_args()
    end = date.fromisoformat(a.end) if a.end else (datetime.now(KST).date() - timedelta(days=1))
    start = end - timedelta(days=a.days - 1)
    window = (f"environment = '{ENVIRONMENT}' AND parent_span_id = '' "
              f"AND start_time >= toDateTime64('{start} 00:00:00', 6, 'Asia/Seoul') "
              f"AND start_time < toDateTime64('{end + timedelta(days=1)} 00:00:00', 6, 'Asia/Seoul')")
    have = int(ch(f"SELECT uniqExact(trace_id) AS n FROM default.events_core WHERE {window}")[0]["n"])
    if have and not a.force:
        print(f"✓ already seeded: {have} traces in {start} … {end} KST (--force sends again)")
        return 0

    auth = "Basic " + base64.b64encode(f"{PK}:{SK}".encode()).decode()
    ids = SeededIds()
    providers, tracers = [], {}
    for name in SERVICES:
        exp = OTLPSpanExporter(endpoint=f"{HOST}/api/public/otel/v1/traces",
                               headers={"Authorization": auth, "x-langfuse-public-key": PK})
        tp = TracerProvider(resource=Resource.create({"service.name": name, "service.version": "2026.11"}),
                            id_generator=ids)
        tp.add_span_processor(BatchSpanProcessor(exp, max_queue_size=50000, max_export_batch_size=500,
                                                 schedule_delay_millis=500))
        providers.append(tp)
        tracers[name] = tp.get_tracer("langfuse-sdk", "4.17.0")

    scores: list[dict] = []
    n_traces = n_err = 0
    for day_idx in range(a.days):
        day = start + timedelta(days=day_idx)
        weekend = day.weekday() >= 5
        for name, svc in SERVICES.items():
            tr = tracers[name]
            ver = version_on(svc, day_idx)
            mean = svc["per_day"] * a.scale * (0.35 if weekend else 1.0)
            n = max(0, int(rng.gauss(mean, math.sqrt(mean))))
            hours = rng.choices(range(24), weights=HOURLY, k=n)
            for h in sorted(hours):
                t0 = datetime(day.year, day.month, day.day, h, rng.randrange(60), rng.randrange(60),
                              rng.randrange(1_000_000), tzinfo=KST)
                uid = f"{svc['users']}-{rng.randrange(svc['n_users']):04d}"
                q = rng.choice(QUESTIONS[name])
                fail = rng.random() < svc["fail"][ver]
                err = rng.choice(ERRORS) if fail else ""
                common = {
                    "langfuse.environment": ENVIRONMENT,
                    "langfuse.trace.name": name,
                    "langfuse.trace.tags": [TAG, f"team:{svc['team']}"],
                    "langfuse.trace.metadata.team": svc["team"],
                    "langfuse.trace.metadata.channel": rng.choice(svc["channels"]),
                    "user.id": uid,
                    "session.id": f"{uid}-{day.isoformat()}",
                }
                root = tr.start_span(name, start_time=ns(t0), attributes={
                    **common, "langfuse.observation.type": "span",
                    "langfuse.observation.input": json.dumps({"question": q}, ensure_ascii=False)})
                ctx = trace.set_span_in_context(root)
                # retrieval
                r_ms = rng.uniform(40, 200) * (2.5 if name == "doc-summary" else 1)
                rs = tr.start_span("retrieve", context=ctx, start_time=ns(t0 + timedelta(milliseconds=5)),
                                   attributes={**common, "langfuse.observation.type": "retriever",
                                               "langfuse.observation.input": json.dumps({"query": q}, ensure_ascii=False)})
                rs.end(end_time=ns(t0 + timedelta(milliseconds=5 + r_ms)))
                # generation
                g0 = t0 + timedelta(milliseconds=10 + r_ms)
                tin = rng.randint(*svc["tin"])
                tout = rng.randint(*svc["tout"])
                if name == "loan-advisor" and ver == 3:
                    tout = int(tout * 1.6)          # v3 asks for a comparison table: longer answers
                ttft = rng.uniform(300, 900)
                g_ms = (ttft + tout * svc["ms_tok"]) * rng.lognormvariate(0, 0.25)
                if fail and err == "upstream model timeout":
                    g_ms = 30_000 + rng.uniform(0, 500)
                attrs = {**common, "langfuse.observation.type": "generation",
                         "langfuse.observation.model.name": svc["model"],
                         "langfuse.observation.prompt.name": f"ch-dash-{name}",
                         "langfuse.observation.prompt.version": ver,
                         "langfuse.observation.input": json.dumps(
                             [{"role": "user", "content": q}], ensure_ascii=False),
                         "langfuse.observation.completion_start_time": json.dumps(
                             (g0 + timedelta(milliseconds=ttft)).astimezone(timezone.utc).isoformat()),
                         "langfuse.observation.usage_details": json.dumps(
                             {"input": tin, "output": 0 if fail else tout})}
                if fail:
                    attrs.update({"langfuse.observation.level": "ERROR",
                                  "langfuse.observation.status_message": err})
                else:
                    attrs["langfuse.observation.output"] = json.dumps(
                        {"role": "assistant", "content": ANSWERS[name]}, ensure_ascii=False)
                gs = tr.start_span("answer", context=ctx, start_time=ns(g0), attributes=attrs)
                g1 = g0 + timedelta(milliseconds=g_ms)
                gs.end(end_time=ns(g1))
                root.set_attribute("langfuse.observation.output", json.dumps(
                    {"answer": "" if fail else ANSWERS[name]}, ensure_ascii=False))
                if fail:
                    root.set_attribute("langfuse.observation.level", "ERROR")
                    root.set_attribute("langfuse.observation.status_message", err)
                t1 = g1 + timedelta(milliseconds=rng.uniform(3, 20))
                root.end(end_time=ns(t1))
                tid = format(root.get_span_context().trace_id, "032x")
                n_traces += 1
                n_err += fail

                # scores: user feedback on ~22% of customer traces, judge on ~35% of all traces
                if svc["users"] == "cust" and rng.random() < 0.22:
                    p_up = 0.86 - (0.45 if fail else 0) - (0.12 if name == "loan-advisor" and ver == 3 else 0)
                    scores.append(dict(id=f"chd-fb-{tid}", traceId=tid, name="user-feedback", dataType="BOOLEAN",
                                       value=1 if rng.random() < p_up else 0,
                                       ts=t1 + timedelta(seconds=rng.uniform(5, 240))))
                if rng.random() < 0.35:
                    mu = 0.88
                    if name == "loan-advisor" and ver == 3:
                        mu = 0.74
                    if name == "card-faq" and ver == 2:
                        mu = 0.91
                    if fail:
                        mu = 0.3
                    v = min(1.0, max(0.0, rng.gauss(mu, 0.08)))
                    scores.append(dict(id=f"chd-judge-{tid}", traceId=tid, name="judge-faithfulness",
                                       dataType="NUMERIC", value=round(v, 3),
                                       ts=t1 + timedelta(minutes=rng.uniform(2, 15))))
        print(f"  {day} {'(weekend)' if weekend else ''} … {n_traces} traces so far", flush=True)

    for tp in providers:
        tp.force_flush(timeout_millis=120_000)
        tp.shutdown()
    print(f"✓ spans sent: {n_traces} traces ({n_err} failed), window {start} … {end} KST")

    ok = 0
    for i in range(0, len(scores), 200):
        batch = []
        for s in scores[i:i + 200]:
            ts = s["ts"].astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
            batch.append({"id": f"ev-{s['id']}", "type": "score-create", "timestamp": ts,
                          "body": {"id": s["id"], "traceId": s["traceId"], "name": s["name"],
                                   "value": s["value"], "dataType": s["dataType"],
                                   "environment": ENVIRONMENT, "timestamp": ts}})
        r = api("POST", "/api/public/ingestion", json={"batch": batch})
        r.raise_for_status()
        body = r.json()
        ok += len(body.get("successes", []))
        if body.get("errors"):
            print("  ✗ score errors:", body["errors"][:3], file=sys.stderr)
    print(f"✓ scores sent: {ok}/{len(scores)}")

    # Wait until the worker has written the traces to ClickHouse.
    t_start = time.time()
    while time.time() - t_start < 600:
        got = ch(f"SELECT uniqExact(trace_id) AS n FROM default.events_core WHERE {window}")[0]["n"]
        print(f"  in ClickHouse: {got}/{n_traces} traces", flush=True)
        if int(got) >= n_traces:
            break
        time.sleep(10)
    else:
        print("✗ not all traces arrived within 10 min; check the worker logs", file=sys.stderr)
        return 1
    print("✓ all traces in ClickHouse")
    return 0


if __name__ == "__main__":
    sys.exit(main())
