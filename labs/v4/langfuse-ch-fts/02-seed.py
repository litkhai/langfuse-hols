#!/usr/bin/env python3
"""02-seed.py — Korean-language support-chat traces into the shared v4 Langfuse, offline.

Each trace is one customer question and the assistant's answer:

    support-chat          (root span: input {"question"}, output {"answer"})
    ├── retrieve-context  (span: input {"query"}, output {"docs": [knowledge-base passages]})
    └── answer-generation (generation: input [system, user] messages, output the answer)

The texts are assembled from the templates below (no model calls, no network beyond Langfuse).
They are written so that the search terms of 04-tokenizers.py show up in the forms Korean
actually uses: with a particle (대출을, 대출이), inside a compound (주택담보대출, 신용대출),
mixed with Latin script (OTP가, API), and one sentence that splits 환불요청 into pieces.

Every trace carries the tags `lab:langfuse-ch-fts`, `topic:<topic>` and `batch:<name>`.

Usage (from the repository root, with the v4 venv):
    .venv-v4/bin/python labs/v4/langfuse-ch-fts/02-seed.py            # 3000 traces, batch "base"
    .venv-v4/bin/python labs/v4/langfuse-ch-fts/02-seed.py 20 live    # 20 more, batch "live" (05-mv-live.py)
"""
import os
import random
import zlib
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lablib  # noqa: E402  (loads _base/.env, or $LF_ENV_FILE)

from langfuse import Langfuse, propagate_attributes  # noqa: E402

N = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
BATCH = sys.argv[2] if len(sys.argv) > 2 else "base"
SEED = zlib.crc32(BATCH.encode())

SYSTEM_PROMPT = (
    "당신은 고객센터 상담 도우미입니다. 고객의 질문에 한국어로 짧고 정확하게 답하고, "
    "확인이 필요한 내용은 상담원 연결을 안내하세요."
)

QUESTIONS = {
    "loan": [
        "주택담보대출 금리가 지난달보다 올랐는데 이유가 뭔가요?",
        "신용대출 한도를 늘리려면 어떤 서류가 필요한가요?",
        "대출을 중도에 갚으면 수수료가 얼마인가요?",
        "대출이 승인됐는지 앱에서 어떻게 확인하나요?",
        "대출 상환일을 {day}일로 바꿀 수 있나요?",
        "전세자금대출 연장은 언제부터 신청할 수 있나요?",
    ],
    "card": [
        "체크카드를 분실했어요. 바로 정지할 수 있나요?",
        "신용카드 결제일을 {day}일로 바꾸고 싶어요.",
        "카드가 해외에서 결제가 안 돼요.",
        "카드 결제 내역에 모르는 승인 건이 {amount}원 있어요.",
        "카드사 포인트를 현금으로 바꿀 수 있나요?",
    ],
    "refund": [
        "어제 결제한 {amount}원을 환불을 요청했는데 아직 안 들어왔어요.",
        "부분환불은 며칠 걸리나요?",
        "환불요청을 취소하고 싶어요.",
        "환불이 카드로 되나요, 계좌로 되나요?",
    ],
    "auth": [
        "비밀번호를 다섯 번 틀려서 잠겼어요.",
        "비밀번호 재설정 메일이 오지 않아요.",
        "OTP가 시간이 안 맞는다고 나와요.",
        "OTP를 새 휴대폰으로 옮기려면 어떻게 하나요?",
        "로그인할 때 인증서 오류가 떠요.",
    ],
    "app": [
        "앱이 업데이트 후에 계속 꺼져요.",
        "모바일앱에서 알림이 안 와요.",
        "앱을 다시 설치해도 화면이 하얗게 나와요.",
        "API 호출이 timeout으로 실패합니다. 오류 코드는 E{code}입니다.",
    ],
    "transfer": [
        "해외송금 수수료가 얼마인가요?",
        "이체 한도를 {amount}원까지 올리고 싶어요.",
        "잘못 이체한 돈을 돌려받을 수 있나요?",
        "자동이체가 두 번 출금됐어요.",
    ],
}

ANSWERS = {
    "loan": [
        "대출 금리는 기준금리와 가산금리를 더해 정해지며, 변동금리 상품은 매달 {day}일에 다시 계산됩니다.",
        "신용대출 한도 상향은 소득을 증빙하는 서류(근로소득원천징수영수증 등)를 제출하시면 심사 후 안내드립니다.",
        "중도상환수수료는 대출 실행 후 3년 이내 상환 시 상환 금액의 최대 1.2%입니다.",
        "대출 승인 여부는 앱의 대출 메뉴에서 진행 상태로 확인하실 수 있습니다.",
        "주택담보대출은 담보 평가가 끝난 뒤 영업일 기준 {days}일 안에 결과를 알려드립니다.",
        "전세자금대출 연장은 만기 2개월 전부터 신청하실 수 있습니다.",
    ],
    "card": [
        "분실 신고는 앱의 카드 관리 메뉴에서 즉시 하실 수 있고, 신고 시점부터 결제가 정지됩니다.",
        "결제일 변경은 월 1회 가능하며 다음 청구분부터 적용됩니다.",
        "해외 결제가 막혀 있다면 카드 설정에서 해외 결제 허용을 켜 주세요.",
        "모르는 승인 건은 이의 제기를 접수하시면 카드사에서 가맹점에 확인합니다.",
        "포인트는 1포인트당 1원으로 결제 대금에서 차감할 수 있습니다.",
    ],
    "refund": [
        "환불은 결제 수단으로 되돌아가며, 카드 결제는 취소 후 영업일 기준 {days}일 안에 반영됩니다.",
        "부분환불은 남은 금액을 다시 승인하는 방식이라 원래 승인 건과 새 승인 건이 함께 보일 수 있습니다.",
        "환불 처리는 따로 신청이 불요합니다. 요청하신 건은 자동으로 접수되었습니다.",
        "환불요청 취소는 처리가 시작되기 전까지만 가능합니다.",
    ],
    "auth": [
        "비밀번호를 5회 잘못 입력하면 보호를 위해 로그인이 잠기며, 본인 인증 후 재설정하실 수 있습니다.",
        "비밀번호 재설정 메일이 보이지 않으면 스팸함을 확인하시고, 그래도 없으면 다시 요청해 주세요.",
        "OTP 시간 오류는 휴대폰의 시간 자동 설정을 켜면 대부분 해결됩니다.",
        "OTP를 새 기기로 옮기려면 기존 기기에서 해지한 뒤 새 기기에서 다시 등록해야 합니다.",
        "인증서 오류는 인증서 유효기간이 지났거나 저장 위치가 바뀐 경우에 주로 나타납니다.",
    ],
    "app": [
        "앱이 꺼지는 문제는 최신 버전({ver})에서 수정되었습니다. 업데이트 후 다시 시도해 주세요.",
        "알림이 오지 않으면 휴대폰 설정에서 앱 알림 권한을 확인해 주세요.",
        "화면이 하얗게 나오면 앱 캐시를 지운 뒤 다시 실행해 주세요.",
        "API timeout 오류(E{code})는 요청이 몰리는 시간에 발생할 수 있어 재시도를 권장합니다.",
    ],
    "transfer": [
        "해외송금 수수료는 건당 {amount}원이며, 중개은행 수수료가 따로 붙을 수 있습니다.",
        "이체 한도 상향은 보안매체 등록 후 앱에서 신청하실 수 있습니다.",
        "착오송금은 반환 청구를 접수하시면 받는 분께 연락해 반환을 요청합니다.",
        "자동이체가 두 번 출금되었다면 출금 내역을 확인한 뒤 한 건을 돌려드립니다.",
    ],
}

CLOSINGS = [
    "더 궁금한 점이 있으면 말씀해 주세요.",
    "추가 확인이 필요하면 상담원을 연결해 드리겠습니다.",
    "도움이 되셨길 바랍니다.",
]

KB = {topic: [f"[{topic}-{i:02d}] " + a for i, a in enumerate(ans)] for topic, ans in ANSWERS.items()}


def fill(rng, s):
    return s.format(
        day=rng.choice([5, 10, 15, 20, 25]),
        days=rng.choice([2, 3, 5, 7]),
        amount=f"{rng.choice([3, 5, 12, 30, 49, 120]) * 1000:,}",
        code=rng.randint(1000, 1099),
        ver=f"5.{rng.randint(10, 19)}.{rng.randint(0, 9)}",
    )


def main():
    rng = random.Random(SEED)
    lf = Langfuse()
    topics = list(QUESTIONS)
    for t in range(N):
        topic = rng.choice(topics)
        question = fill(rng, rng.choice(QUESTIONS[topic]))
        k = rng.randint(1, 3)
        answer = " ".join([fill(rng, s) for s in rng.sample(ANSWERS[topic], k)] + [rng.choice(CLOSINGS)])
        docs = rng.sample(KB[topic], min(3, len(KB[topic])))
        with lf.start_as_current_observation(as_type="span", name="support-chat",
                                             input={"question": question}) as root:
            with propagate_attributes(
                trace_name="support-chat",
                user_id=f"user-{rng.randint(1, 400):03d}",
                session_id=f"fts-{BATCH}-{t // 4}",
                tags=[lablib.LAB_TAG, f"topic:{topic}", f"batch:{BATCH}"],
                metadata={"channel": rng.choice(["app", "web"]), "topic": topic},
            ):
                with lf.start_as_current_observation(as_type="span", name="retrieve-context",
                                                     input={"query": question}) as ret:
                    ret.update(output={"docs": [fill(rng, d) for d in docs]})
                with lf.start_as_current_observation(
                        as_type="generation", name="answer-generation", model="gpt-4o-mini",
                        input=[{"role": "system", "content": SYSTEM_PROMPT},
                               {"role": "user", "content": question}]) as gen:
                    gen.update(output=answer,
                               usage_details={"input": rng.randint(180, 420), "output": rng.randint(40, 160)})
            root.update(output={"answer": answer})
        if (t + 1) % 100 == 0:
            # The OTel batch processor queue holds 2048 spans by default and drops the rest
            # silently; flushing every 100 traces (300 spans) keeps every span (seen 2026-11-23:
            # without it, 3000 traces landed as 1708 in ClickHouse).
            lf.flush()
        if (t + 1) % 500 == 0:
            print(f"  …{t + 1}/{N} traces")
    lf.flush()
    print(f"✓ {N} traces, batch {BATCH}, tag {lablib.LAB_TAG}")


if __name__ == "__main__":
    main()
