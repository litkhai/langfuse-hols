#!/usr/bin/env python3
"""
02-seed-traces.py — Korean-language traces for the MCP questions of this lab.

Simulates a Korean customer-support RAG assistant over the last 50 minutes (offline: no
model is called, tokens and latencies are drawn from a fixed RNG). Every trace carries the
tag `lab:langfuse-mcp`, so the questions and the checks can filter to this lab's rows on a
stack other labs share.

    support-chat                 (root span: user_id, session_id, tags, the question)
    ├── retrieve-context         (span: vector search)
    │   └── retrieve-retry       (span: only when the first search timed out)
    └── answer-generation        (generation: model, tokens, linked prompt version)

What is planted, so the answers can be checked (04-check.py):
  * prompt `lab-langfuse-mcp-answer` v1, then v2 from 25 minutes ago (the rollout);
    v2 asks for JSON output and 1 in 5 of its generations fails with level ERROR
    "응답 JSON 파싱 실패", against 1 in 25 timeouts under v1
  * 3 slow traces: the vector search times out after 8 s and is retried (WARNING)
  * 1 slow generation: 14 s on gpt-4o with a very long answer
  * user u-007 sends long contracts (8–12k input tokens) to gpt-4o: the top-cost user
  * fake personal data (a made-up phone number and name) in some questions — input is
    hidden from the MCP user, see 01-ro-user.sh

Start times are set explicitly (the SDK's tracer is given a start_time; end() takes an
end_time), so the 50-minute history is written in a few seconds.

Usage: .venv-v4/bin/python labs/v4/langfuse-mcp/02-seed-traces.py
Writes .run/seed.json (run id, trace counts, the planted ids) for 04-check.py.
"""
import json
import os
import random
import sys
import time
import uuid

LAB_DIR = os.path.dirname(os.path.abspath(__file__))
BASE_DIR = os.path.normpath(os.path.join(LAB_DIR, "..", "..", "..", "_base"))
RUN_DIR = os.path.join(LAB_DIR, ".run")


def _load_dotenv(path: str) -> None:
    if not os.path.exists(path):
        return
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key, val = key.strip(), val.split(" #", 1)[0].strip().strip('"').strip("'")
            os.environ.setdefault(key, val)


_load_dotenv(os.environ.get("LF_ENV_FILE") or os.path.join(BASE_DIR, ".env"))

from langfuse import Langfuse, propagate_attributes  # noqa: E402

TAG = "lab:langfuse-mcp"
PROMPT_NAME = "lab-langfuse-mcp-answer"
N_TRACES = 120
WINDOW_MIN = 50          # history length
ROLLOUT_MIN_AGO = 25     # v2 goes live this many minutes before the end of the run
rng = random.Random(20261123)   # private RNG; OpenTelemetry ids stay random (see _base/v4/seed_traces.py)

QUESTIONS = [
    ("card", "해외 결제가 갑자기 거절됐어요. 이유가 뭘까요?"),
    ("card", "카드 분실 신고는 어떻게 하나요?"),
    ("loan", "중도상환 수수료가 얼마인지 알려 주세요."),
    ("loan", "대출 금리가 지난달보다 오른 이유가 궁금합니다."),
    ("account", "자동이체 날짜를 바꾸고 싶어요."),
    ("account", "비대면으로 계좌를 해지할 수 있나요?"),
    ("app", "앱 로그인할 때 인증서 오류가 납니다."),
    ("app", "알림이 두 번씩 와요."),
]
PII_QUESTION = "저는 홍길동이고 연락처는 010-0000-1234입니다. 카드 한도를 올려 주세요."
CONTRACT_QUESTION = "첨부한 대출 약정서 전문을 검토해서 불리한 조항을 모두 찾아 주세요."
ANSWER_V1 = "확인해 보니 해외 결제 차단 설정이 켜져 있습니다. 앱 > 카드 > 해외 결제에서 해제할 수 있습니다."
ANSWER_V2 = '{"answer": "앱 > 카드 > 해외 결제에서 차단을 해제할 수 있습니다.", "sources": ["kb-214"]}'

PROMPTS = {
    1: "당신은 은행 고객센터 상담 도우미입니다. 참고 문서만 근거로 한국어로 짧게 답하세요.\n\n참고 문서:\n{{context}}\n\n질문: {{question}}",
    2: "당신은 은행 고객센터 상담 도우미입니다. 참고 문서만 근거로 답하고, 반드시 JSON 한 개로만 출력하세요: "
       '{"answer": string, "sources": string[]}.\n\n참고 문서:\n{{context}}\n\n질문: {{question}}',
}


class Clock:
    """Feeds explicit start times to the SDK's OpenTelemetry tracer."""

    def __init__(self, lf: Langfuse):
        self.ns = time.time_ns()
        tracer = lf._otel_tracer
        orig = tracer.start_span

        def start_span(*args, **kwargs):
            kwargs.setdefault("start_time", self.ns)
            return orig(*args, **kwargs)

        tracer.start_span = start_span

    def at(self, ns: int) -> int:
        self.ns = ns
        return ns


def ensure_prompts(lf: Langfuse):
    """Create v1 and v2 of the prompt once; re-runs reuse them."""
    have = {}
    for v in (1, 2):
        try:
            have[v] = lf.get_prompt(PROMPT_NAME, version=v, cache_ttl_seconds=0)
        except Exception:
            pass
    if 1 not in have:
        have[1] = lf.create_prompt(name=PROMPT_NAME, prompt=PROMPTS[1], type="text",
                                   labels=[], tags=[TAG], commit_message="첫 버전")
    if 2 not in have:
        have[2] = lf.create_prompt(name=PROMPT_NAME, prompt=PROMPTS[2], type="text",
                                   labels=["production"], tags=[TAG],
                                   commit_message="JSON 출력 형식으로 변경")
    assert have[1].version == 1 and have[2].version == 2, (have[1].version, have[2].version)
    return have


def main():
    lf = Langfuse(
        base_url=os.environ.get("LANGFUSE_HOST", "http://localhost:3000"),
        public_key=os.environ["LANGFUSE_PUBLIC_KEY"],
        secret_key=os.environ["LANGFUSE_SECRET_KEY"],
    )
    if not lf.auth_check():
        sys.exit("✗ Langfuse auth check failed: is the v4 stack up and LF_ENV_FILE right?")
    prompts = ensure_prompts(lf)
    clock = Clock(lf)

    run_id = uuid.uuid4().hex[:8]
    end_ns = time.time_ns() - 60 * 10**9          # last trace starts a minute ago
    start_ns = end_ns - WINDOW_MIN * 60 * 10**9
    rollout_ns = end_ns - ROLLOUT_MIN_AGO * 60 * 10**9
    users = [f"u-{i:03d}" for i in range(1, 11)]
    slow_retrieval = set(rng.sample(range(N_TRACES), 3))
    slow_generation = rng.choice([i for i in range(N_TRACES) if i not in slow_retrieval and i > 70])
    planted = {"run_id": run_id, "rollout_ns": rollout_ns, "slow_retrieval": [], "slow_generation": None,
               "errors": {"1": 0, "2": 0}, "generations": {"1": 0, "2": 0}, "pii_traces": 0}

    for t in range(N_TRACES):
        t0 = start_ns + int((end_ns - start_ns) * t / (N_TRACES - 1)) + rng.randint(0, 5 * 10**9)
        version = 2 if t0 >= rollout_ns else 1
        user = rng.choice(users)
        heavy = user == "u-007" and rng.random() < 0.8
        if heavy:
            feature, question, model = "loan", CONTRACT_QUESTION, "gpt-4o"
            ptok, ctok = rng.randint(8000, 12000), rng.randint(600, 1200)
        else:
            feature, question = rng.choice(QUESTIONS)
            model = "gpt-4o" if rng.random() < 0.2 else "gpt-4o-mini"
            ptok, ctok = rng.randint(400, 1400), rng.randint(60, 300)
        if rng.random() < 0.08:
            question = PII_QUESTION
            planted["pii_traces"] += 1
        fail = rng.random() < (0.20 if version == 2 else 0.04)
        is_slow_ret = t in slow_retrieval
        is_slow_gen = t == slow_generation
        if is_slow_gen:
            model, ctok = "gpt-4o", 3800

        clock.at(t0)
        # propagate_attributes applies to spans created inside it, so the root goes inside too
        with propagate_attributes(trace_name="support-chat", user_id=user,
                                  session_id=f"s-{user}-{t // 6}",
                                  tags=[TAG, f"feature:{feature}"],
                                  metadata={"run": run_id, "channel": "app"}):
            root = lf.start_observation(as_type="span", name="support-chat",
                                        input={"question": question, "channel": "app"})
            # retrieval
            cur = t0 + 2 * 10**6
            clock.at(cur)
            ret = root.start_observation(as_type="span", name="retrieve-context",
                                         input={"query": question, "top_k": 4})
            if is_slow_ret:
                ret.update(level="WARNING", status_message="벡터 검색 8초 타임아웃 후 재시도",
                           metadata={"index": "kb-ko", "attempts": "2"})
                ret_end = cur + 8_000 * 10**6
                clock.at(ret_end)
                retry = ret.start_observation(as_type="span", name="retrieve-retry",
                                              input={"query": question, "top_k": 4})
                retry.update(output={"doc_ids": ["kb-214", "kb-031"]})
                retry_end = ret_end + rng.randint(900, 1600) * 10**6
                retry.end(end_time=retry_end)
                ret.update(output={"doc_ids": ["kb-214", "kb-031"]})
                ret.end(end_time=retry_end)
                cur = retry_end
                planted["slow_retrieval"].append(root.trace_id)
            else:
                ret.update(output={"doc_ids": [f"kb-{rng.randint(100, 999)}" for _ in range(4)]},
                           metadata={"index": "kb-ko", "attempts": "1"})
                cur += rng.randint(60, 220) * 10**6
                ret.end(end_time=cur)

            # generation
            cur += 1 * 10**6
            clock.at(cur)
            gen = root.start_observation(
                as_type="generation", name="answer-generation", model=model,
                prompt=prompts[version],
                input=[{"role": "user", "content": prompts[version].compile(context="kb-214, kb-031", question=question)}],
                model_parameters={"temperature": 0.2},
            )
            planted["generations"][str(version)] += 1
            if is_slow_gen:
                dur_ms = 14_000
                planted["slow_generation"] = root.trace_id
            elif heavy:
                dur_ms = rng.randint(3500, 6500)
            else:
                dur_ms = rng.randint(400, 1800) if model == "gpt-4o-mini" else rng.randint(900, 2600)
            if fail:
                planted["errors"][str(version)] += 1
                if version == 2:
                    gen.update(level="ERROR", status_message="응답 JSON 파싱 실패: Expecting ',' delimiter",
                               output='{"answer": "앱 > 카드 > 해외 결제에서 차단을 해제할 수 있습니다." "sources": [',
                               usage_details={"input": ptok, "output": ctok})
                else:
                    dur_ms = rng.randint(2000, 3000)
                    gen.update(level="ERROR", status_message="upstream model timeout",
                               usage_details={"input": ptok, "output": 0})
            else:
                gen.update(output=ANSWER_V2 if version == 2 else ANSWER_V1,
                           usage_details={"input": ptok, "output": ctok})
            cur += dur_ms * 10**6
            gen.end(end_time=cur)

            root.update(output={"answer": None if fail else (ANSWER_V2 if version == 2 else ANSWER_V1),
                                "prompt_version": version})
            root.end(end_time=cur + 3 * 10**6)
        trace_id = root.trace_id
        lf.create_score(name="user-feedback", trace_id=trace_id, data_type="BOOLEAN",
                        value=0 if fail or is_slow_ret or is_slow_gen else (1 if rng.random() < 0.85 else 0))

    lf.flush()
    os.makedirs(RUN_DIR, exist_ok=True)
    with open(os.path.join(RUN_DIR, "seed.json"), "w") as fh:
        json.dump(planted, fh, ensure_ascii=False, indent=2)
    print(f"✓ {N_TRACES} traces, run {run_id}, tag {TAG}")
    print(f"  prompt {PROMPT_NAME}: v1 {planted['generations']['1']} generations / {planted['errors']['1']} errors,"
          f" v2 {planted['generations']['2']} / {planted['errors']['2']}")
    print(f"  slow retrieval: {len(planted['slow_retrieval'])} traces, slow generation: 1, PII questions: {planted['pii_traces']}")


if __name__ == "__main__":
    main()
