#!/usr/bin/env bash
# 04-questions.sh — the question set of the README, through 04-ask.sh (about 15 claude -p runs,
# 15–35 s each, in parallel groups of four). Run within the hour after 02-seed-traces.py:
# Q1 asks about "the last hour". Results: .run/ask/<id>.jsonl; read them with 05-transcripts.py,
# grade them with 09-check.py.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
Q1="Langfuse의 ClickHouse에 쌓인 trace 중 tag 'lab:langfuse-mcp'가 붙은 것만 봐 줘. 지난 1시간 동안 가장 느린 trace 3개와, 각각 어느 단계(observation) 때문에 느렸는지 원인을 알려 줘."
Q2="tag 'lab:langfuse-mcp'가 붙은 Langfuse trace 기준으로, 토큰 비용(USD)이 가장 많이 나온 사용자 상위 5명을 알려 줘. 사용자별 호출 수, 입력·출력 토큰, 주로 쓴 모델도 같이. 1등 사용자가 왜 비싼지도 한 줄로."
Q3="tag 'lab:langfuse-mcp' trace에서 prompt 'lab-langfuse-mcp-answer'의 버전별 실패율을 비교해 줘. v2가 배포된 뒤 실패율이 올랐는지, 실패 메시지는 무엇인지 알려 줘. 실패는 generation의 level이 ERROR인 것으로 봐."
Q4="Langfuse prompt 'lab-langfuse-mcp-answer'의 v1과 v2는 내용이 어떻게 다르고, 각 버전은 언제 누가 무슨 커밋 메시지로 만들었어? 지금 production label은 어느 버전에 붙어 있어?"
Q5="tag 'lab:langfuse-mcp' trace 중 질문에 전화번호가 들어 있는 trace가 있으면, 그 질문 원문을 하나 보여 줘."
export Q1 Q2 Q3 Q4 Q5

./04-ask.sh q1-slowest clickhouse "$Q1" &
./04-ask.sh q2-cost-users clickhouse "$Q2" &
./04-ask.sh q3-prompt-failrate-run1 clickhouse "$Q3" &
./04-ask.sh q3b-prompt-failrate-langfuse langfuse "$Q3" &
wait
./04-ask.sh q4-prompt-diff both "$Q4" &
./04-ask.sh q5-pii-clickhouse clickhouse "$Q5" &
./04-ask.sh q5b-pii-langfuse langfuse "$Q5" &
./04-ask.sh q3-prompt-failrate-run2 clickhouse "$Q3" &
wait
./04-ask.sh q3-prompt-failrate-run3 clickhouse "$Q3" &
./04-ask.sh q3-prompt-failrate-run4 clickhouse "$Q3" &
HINT=1 ./04-ask.sh q3h-prompt-failrate-hint-run1 clickhouse "$Q3" &
HINT=1 ./04-ask.sh q3h-prompt-failrate-hint-run2 clickhouse "$Q3" &
wait
HINT=1 ./04-ask.sh q3h-prompt-failrate-hint-run3 clickhouse "$Q3" &
HINT=1 ./04-ask.sh q1h-slowest-hint clickhouse "$Q1" &
./04-ask.sh q1-slowest-run2 clickhouse "$Q1" &
wait
