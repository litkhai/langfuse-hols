#!/usr/bin/env python3
"""02-seed.py — Korean-language traces for one service, sent with the Langfuse Python SDK (offline, no LLM API).

    OTEL_SERVICE_NAME=<service> python 02-seed.py <service> <n_traces> <batch>

02-seed.sh starts one process per service in parallel. OTEL_SERVICE_NAME becomes the OpenTelemetry resource
attribute service.name, which Langfuse v4 stores in events_full.service_name. Every observation also carries the
trace tags svc:<service>, team:<team>, env:<env> and lab:langfuse-ch-mv (the MVs of this lab keep only rows with
that last tag), and about one trace in eight also gets review:needed (an error or a low self-check score); the
"copy" MV of 03 keeps those.

Token usage is simulated; Langfuse prices gpt-4o-mini, gpt-4o and claude-haiku-4-5 itself, so cost_details is
filled by the server. Reads LANGFUSE_HOST / LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY from the environment
(lib.sh exports them).
"""
import os
import random
import sys
import time

from langfuse import Langfuse, get_client, propagate_attributes

SERVICE, N, BATCH = sys.argv[1], int(sys.argv[2]), sys.argv[3]
if os.environ.get("OTEL_SERVICE_NAME") != SERVICE:
    sys.exit("set OTEL_SERVICE_NAME to the service name (02-seed.sh does)")

# A private RNG per service and batch: reproducible content, while OpenTelemetry's ids stay random.
rng = random.Random(f"{SERVICE}-{BATCH}")

SERVICES = {
    "support-chat": {
        "team": "cx", "trace_name": "상담-응답", "rag": True,
        "models": [("gpt-4o-mini", (400, 1400), (80, 300)), ("claude-haiku-4-5", (400, 1400), (80, 300))],
        "qa": [
            ("적금을 만기 전에 해지하면 이자는 어떻게 되나요?", "만기 전 해지 시에는 가입 기간에 따라 중도해지 이율이 적용됩니다."),
            ("체크카드 해외 결제가 안 되는데 확인해 주실 수 있나요?", "앱의 카드 관리 메뉴에서 해외 결제 설정이 켜져 있는지 먼저 확인해 주세요."),
            ("공인인증서 대신 쓸 수 있는 인증 방법이 있나요?", "간편 비밀번호, 생체 인증, 금융인증서로 로그인할 수 있습니다."),
            ("자동이체 날짜를 바꾸고 싶어요.", "이체 관리 메뉴에서 자동이체를 선택한 뒤 출금일을 변경하시면 됩니다."),
            ("영업점 방문 없이 계좌 한도를 올릴 수 있나요?", "비대면 서류 제출로 한도 상향을 신청할 수 있으며 심사 후 반영됩니다."),
        ],
    },
    "doc-summary": {
        "team": "ops", "trace_name": "문서-요약", "rag": False,
        "models": [("gpt-4o", (1500, 4000), (200, 600))],
        "qa": [
            ("다음 회의록을 세 줄로 요약해 주세요: 4분기 운영 점검 회의 …", "1) 장애 대응 절차 개정 2) 야간 배치 시간 조정 3) 다음 점검은 1월."),
            ("이 공지문의 핵심 변경 사항만 정리해 주세요: 전산 시스템 점검 안내 …", "점검 시간은 토요일 02시부터 06시까지이며 이 시간에는 이체가 제한됩니다."),
            ("보고서 초안을 임원 보고용으로 짧게 줄여 주세요: 비대면 채널 이용 현황 …", "비대면 채널 이용이 전년 대비 늘었고, 모바일 비중이 가장 큽니다."),
        ],
    },
    "policy-qa": {
        "team": "compliance", "trace_name": "규정-질의", "rag": True,
        "models": [("gpt-4o-mini", (600, 1800), (100, 400))],
        "qa": [
            ("고객 정보를 외부 클라우드에 저장할 때 필요한 승인 절차는?", "정보보호 부서의 사전 검토와 위탁 계약 체결이 필요합니다."),
            ("개인정보 보관 기간이 지난 데이터는 언제까지 파기해야 하나요?", "보관 기간이 끝난 날부터 지체 없이, 내부 기준으로는 5영업일 안에 파기합니다."),
            ("업무용 메신저로 고객 연락처를 보내도 되나요?", "고객 연락처는 승인된 업무 시스템 안에서만 전달할 수 있습니다."),
            ("LLM 서비스에 입력해도 되는 정보의 범위는?", "공개 정보와 비식별 처리된 정보만 입력할 수 있습니다."),
        ],
    },
    "voc-classify": {
        "team": "cx", "trace_name": "VOC-분류", "rag": False,
        "models": [("gpt-4o-mini", (150, 500), (5, 30))],
        "qa": [
            ("앱 업데이트 후 로그인이 계속 풀려요.", "분류: 앱 오류 / 긴급도: 중"),
            ("상담원 연결까지 너무 오래 걸립니다.", "분류: 상담 대기 / 긴급도: 하"),
            ("이체 수수료가 안내와 다르게 나갔어요.", "분류: 수수료 문의 / 긴급도: 상"),
            ("카드 분실 신고를 했는데 확인 문자가 오지 않았어요.", "분류: 분실 신고 / 긴급도: 상"),
        ],
    },
}
cfg = SERVICES[SERVICE]

Langfuse(base_url=os.environ["LANGFUSE_HOST"], public_key=os.environ["LANGFUSE_PUBLIC_KEY"],
         secret_key=os.environ["LANGFUSE_SECRET_KEY"])
lf = get_client()
if not lf.auth_check():
    sys.exit("✗ Langfuse auth check failed: is the v4 stack up and are the keys right?")

users = [f"emp-{i:03d}" for i in range(1, 21)]
review = 0
for t in range(N):
    question, answer = rng.choice(cfg["qa"])
    model, ptok_r, ctok_r = rng.choice(cfg["models"])
    env = "staging" if rng.random() < 0.2 else "production"
    user_id = rng.choice(users)
    will_error = rng.random() < 0.05
    check_score = round(rng.uniform(0.4, 1.0), 2)
    needs_review = will_error or check_score < 0.45
    review += needs_review
    tags = [f"svc:{SERVICE}", f"team:{cfg['team']}", f"env:{env}", "lab:langfuse-ch-mv"]
    if needs_review:
        tags.append("review:needed")

    with lf.start_as_current_observation(as_type="span", name=cfg["trace_name"], input={"질문": question}) as root:
        with propagate_attributes(trace_name=cfg["trace_name"], user_id=user_id,
                                  session_id=f"{SERVICE}-{user_id}-{BATCH}-{t // 4}", tags=tags,
                                  metadata={"batch": BATCH, "team": cfg["team"], "channel": "internal"}):
            trace_id = lf.get_current_trace_id()
            if cfg["rag"]:
                with lf.start_as_current_observation(as_type="span", name="문서-검색") as ret:
                    time.sleep(rng.uniform(0.01, 0.06))
                    ret.update(input={"query": question, "top_k": 4},
                               output={"doc_ids": [f"kb-{rng.randint(100, 999)}" for _ in range(4)]})
            with lf.start_as_current_observation(as_type="generation", name="답변-생성", model=model,
                                                 input=[{"role": "user", "content": question}]) as gen:
                time.sleep(rng.uniform(0.05, 0.4))
                if will_error:
                    gen.update(level="ERROR", status_message="upstream model timeout")
                    answer = None
                else:
                    gen.update(output=answer,
                               usage_details={"input": rng.randint(*ptok_r), "output": rng.randint(*ctok_r)})
            if not will_error and cfg["rag"]:
                with lf.start_as_current_observation(as_type="generation", name="근거-확인", model="gpt-4o-mini",
                                                     input={"answer": answer}) as chk:
                    time.sleep(rng.uniform(0.01, 0.05))
                    chk.update(output={"score": check_score},
                               usage_details={"input": rng.randint(80, 300), "output": 5})
        root.update(output={"답변": answer, "errored": will_error})
    if not will_error:
        lf.create_score(name="근거-점수", trace_id=trace_id, value=check_score, data_type="NUMERIC")

lf.flush()
print(f"✓ {SERVICE}: {N} traces (batch {BATCH}, {review} tagged review:needed)")
