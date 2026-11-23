# langfuse-ch-vector — run log

Run of 2026-11-23 (UTC start 10:51:50), from a clean state: `99-cleanup.py --traces --cache` first (240 lab traces deleted through the Langfuse API; all gone from `events_full` 41 s later, their scores too).
Langfuse v4.56.0 / SDK 4.17.0 / CH 26.8.22.13 (shared v4 stack), nlpai-lab/KURE-v1 @ 444abe2a0ef1d6fd226b31de0b94133430b4de8e, sentence-transformers 6.3.0, torch 2.15.0 (MPS), Python 3.12.14, Docker 29.9.3, Apple M4 Pro, macOS 26.7.3.
Other sessions' lab containers were running on the same Docker VM (12 CPUs, 15.6 GiB). Model and library warnings are filtered out of the output below.

## 01-setup.py

```text
ClickHouse 26.8.22.13
   ┌─name────────────────────────────────┬─value─┬─tier───────┐
1. │ enable_vector_similarity_index      │ 1     │ Obsolete   │
2. │ hnsw_candidate_list_size_for_search │ 256   │ Production │
3. │ max_limit_for_vector_search_queries │ 1000  │ Production │
4. │ vector_search_filter_strategy       │ auto  │ Production │
5. │ vector_search_with_rescoring        │ 0     │ Production │
   └─────────────────────────────────────┴───────┴────────────┘

   ┌─name───────┬─engine─────────────┬─total_rows─┐
1. │ embeddings │ MergeTree          │          0 │
2. │ queries    │ ReplacingMergeTree │          0 │
3. │ topics     │ MergeTree          │          0 │
4. │ watermark  │ ReplacingMergeTree │          0 │
   └────────────┴────────────────────┴────────────┘

model nlpai-lab/KURE-v1@444abe2 dim=1024 device=mps:0
```

## 02-seed-traces.py

```text
sent 240 traces (28 with level ERROR), tag lab:langfuse-ch-vector
```

## 03-embed.py

```text
watermark 1970-01-01 00:00:00.000000 -> 2026-11-23 10:52:12.766000; embedded 480 texts of 240 traces (read 0.02s, model load 11.25s, embed 2.39s, insert 0.26s); removed 0 rows of deleted traces
   ┌─kind───┬─level───┬─rows─┬─traces─┐
1. │ input  │ DEFAULT │  212 │    212 │
2. │ input  │ ERROR   │   28 │     28 │
3. │ output │ DEFAULT │  212 │    212 │
4. │ output │ ERROR   │   28 │     28 │
   └────────┴─────────┴──────┴────────┘

```

## 04-similar.py

```text
sent 1 traces (1 with level ERROR), tag lab:langfuse-ch-vector
failing trace id 72be9f5bb1721422f205126536446565
watermark 2026-11-23 10:52:12.766000 -> 2026-11-23 10:52:30.864000; embedded 2 texts of 1 traces (read 0.01s, model load 10.83s, embed 0.64s, insert 0.08s); removed 0 rows of deleted traces
   ┌─kind───┬─level───┬─rows─┬─traces─┐
1. │ input  │ DEFAULT │  212 │    212 │
2. │ input  │ ERROR   │   29 │     29 │
3. │ output │ DEFAULT │  212 │    212 │
4. │ output │ ERROR   │   29 │     29 │
   └────────┴─────────┴──────┴────────┘

failing trace 72be9f5bb1721422f205126536446565
  question: 어제 앱 업데이트했더니 로그인하자마자 튕겨요
  ERROR: tool error: account-service timeout after 30s

    ┌─distance─┬─question──────────────────────────────┬─level───┬─status_message────────────────────────────────┬─answer────────────────────────────────────────────────────────────────┬─trace_id─────────────────────────┐
 1. │    0.243 │ 로그인 누르면 앱이 멈춰요             │ DEFAULT │                                               │ 앱을 최신 버전으로 업데이트한 뒤 휴대폰을 재부팅해 보세요. 계속되면 [ │ fbcfc3dfd5a1ff9397f5ac6e9361aa5e │
 2. │    0.243 │ 로그인 누르면 앱이 멈춰요             │ ERROR   │ tool error: account-service timeout after 30s │ tool error: account-service timeout afte                              │ 67f26fcfc176d3a96756da9bf2b1779f │
 3. │    0.266 │ 업데이트 후에 앱이 계속 꺼져요        │ ERROR   │ tool error: account-service timeout after 30s │ tool error: account-service timeout afte                              │ 4ef411fa16594a0cd14f0e6862168149 │
 4. │    0.266 │ 업데이트 후에 앱이 계속 꺼져요        │ DEFAULT │                                               │ 앱을 최신 버전으로 업데이트한 뒤 휴대폰을 재부팅해 보세요. 계속되면 [ │ a4a9820ea92052caec0d1e3fe2af80db │
 5. │    0.283 │ 앱 업데이트하고 나서 계속 꺼져요      │ ERROR   │ tool error: account-service timeout after 30s │ tool error: account-service timeout afte                              │ f276fde5fe7a74c23ee2c2b3c3f1061a │
 6. │    0.283 │ 앱 업데이트하고 나서 계속 꺼져요      │ ERROR   │ tool error: account-service timeout after 30s │ tool error: account-service timeout afte                              │ 936e76f0390d2fc69f6aba398c581192 │
 7. │    0.303 │ 앱 접속이 너무 느려요                 │ DEFAULT │                                               │ 앱을 최신 버전으로 업데이트한 뒤 휴대폰을 재부팅해 보세요. 계속되면 [ │ b26eea63d56dde54e3736bba77d329e7 │
 8. │    0.303 │ 앱 접속이 너무 느려요                 │ DEFAULT │                                               │ 앱을 최신 버전으로 업데이트한 뒤 휴대폰을 재부팅해 보세요. 계속되면 [ │ aeecf1c3e319176597e73bcbe5d89d07 │
 9. │    0.315 │ 앱을 지웠다가 다시 깔았는데도 안 돼요 │ ERROR   │ tool error: account-service timeout after 30s │ tool error: account-service timeout afte                              │ 64683d8095788cc32e3ac865500658be │
10. │    0.315 │ 앱을 지웠다가 다시 깔았는데도 안 돼요 │ DEFAULT │                                               │ 앱을 최신 버전으로 업데이트한 뒤 휴대폰을 재부팅해 보세요. 계속되면 [ │ 0d0b23510cfbe3020110c1da816015bf │
    └──────────┴───────────────────────────────────────┴─────────┴───────────────────────────────────────────────┴───────────────────────────────────────────────────────────────────────┴──────────────────────────────────┘

query 19 ms (client side)
error rate of all lab traces 0.117, of the 10 nearest 0.5; most common status among them: tool error: account-service timeout after 30s

free-text search: 유로로 환전하면 수수료가 얼마나 나와요?
   ┌─────d─┬─text───────────────────────────┐
1. │ 0.165 │ 엔화 환전 수수료 얼마예요      │
2. │ 0.165 │ 엔화 환전 수수료 얼마예요      │
3. │   0.2 │ 해외 송금 수수료가 얼마인가요? │
4. │   0.2 │ 해외 송금 수수료가 얼마인가요? │
5. │ 0.202 │ 해외송금 수수료 얼마예요       │
   └───────┴────────────────────────────────┘

top-10 with WHERE kind = 'input', through the vector index and exact:
  index, default settings                            rows  9  farthest distance 0.62
  index, vector_search_index_fetch_multiplier = 4    rows 10  farthest distance 0.333
  vector_search_filter_strategy = 'prefilter'        rows 10  farthest distance 0.333
  exact (use_skip_indexes = 0)                       rows 10  farthest distance 0.333
```

## 05-topics.py --scores

```text
241 traces, 1024 dimensions
  k= 6 silhouette=0.198
  k= 7 silhouette=0.225
  k= 8 silhouette=0.251
  k= 9 silhouette=0.258
  k=10 silhouette=0.281
  k=11 silhouette=0.314
  k=12 silhouette=0.322
  k=13 silhouette=0.319
  k=14 silhouette=0.322
  k=15 silhouette=0.320
  k=16 silhouette=0.302
  k=17 silhouette=0.320
  k=18 silhouette=0.302
  k=19 silhouette=0.313
  k=20 silhouette=0.287
chosen k=14 (silhouette 0.322)
wrote 241 rows to lab_langfuse_ch_vector.topics, run_id 20261123T105258Z

    ┌─topic─┬─topic_label───────────────────────────────────┬─traces─┬─error_rate─┬─top_status───────────────────────────────────────┐
 1. │     4 │ 업데이트 후에 앱이 계속 꺼져요                │     19 │       0.58 │ tool error: account-service timeout after 30s    │
 2. │     5 │ 인증서를 새 휴대폰으로 옮기고 싶어요          │      8 │       0.38 │ tool error: cert-service 503 Service Unavailable │
 3. │     9 │ 비밀번호 변경했는데 계속 틀렸다고 나와요      │     26 │       0.31 │ guardrail: identity verification required        │
 4. │    12 │ 달러 환전할 때 우대 받을 수 있나요            │     16 │       0.19 │ tool error: fx-rate API timeout after 10s        │
 5. │    10 │ 공동인증서 유효기간 끝나서 재발급 받고 싶어요 │     12 │       0.17 │ tool error: cert-service 503 Service Unavailable │
 6. │     3 │ 해외 송금 수수료가 얼마인가요?                │     18 │       0.06 │ tool error: fx-rate API timeout after 10s        │
 7. │     7 │ 이체 한도를 늘리고 싶어요. 어떻게 하나요?     │     22 │       0.05 │ tool error: fx-rate API timeout after 10s        │
 8. │     1 │ 잔액증명서 발급하고 싶어요                    │     22 │          0 │                                                  │
 9. │     2 │ 체크카드 분실 신고하고 싶어요                 │     20 │          0 │                                                  │
10. │     6 │ 금리인하요구권 신청하고 싶어요                │     20 │          0 │                                                  │
11. │    11 │ 자동이체 신청 방법 알려주세요                 │     20 │          0 │                                                  │
12. │     8 │ 정기예금 중간에 해지하면 이자 어떻게 돼요     │     18 │          0 │                                                  │
13. │     0 │ OTP 배터리 나가서 교체하고 싶어요             │     10 │          0 │                                                  │
14. │    13 │ 보안카드 대신 OTP 쓰려면 어떻게 해요          │     10 │          0 │                                                  │
    └───────┴───────────────────────────────────────────────┴────────┴────────────┴──────────────────────────────────────────────────┘

against the seed intents (12): adjusted Rand index 0.851, purity 0.950
wrote 241 `topic` scores to Langfuse
```

## 06-bench-up.sh

```text
bench ClickHouse 26.8.22.13 on 127.0.0.1:28123 (container lf-ch-vector-bench)
```

## 06-bench-embed.py

```text
108000 distinct sentences; model nlpai-lab/KURE-v1@444abe2
  4096/108000  17s
  8192/108000  34s
  12288/108000  52s
  16384/108000  69s
  20480/108000  87s
  24576/108000  106s
  28672/108000  123s
  32768/108000  141s
  36864/108000  160s
  40960/108000  182s
  45056/108000  204s
  49152/108000  227s
  53248/108000  251s
  57344/108000  276s
  61440/108000  302s
  65536/108000  327s
  69632/108000  352s
  73728/108000  378s
  77824/108000  403s
  81920/108000  429s
  86016/108000  454s
  90112/108000  479s
  94208/108000  504s
  98304/108000  528s
  102400/108000  553s
  106496/108000  576s
  108000/108000  585s
embedded 108000 in 601s (180/s), device mps:0 -> labs/v4/langfuse-ch-vector/.run/bench.npz
```

## 07-bench.py

```text
bench vectors: 107800 corpus + 200 queries, dim 1024, model nlpai-lab/KURE-v1@444abe2a0ef1d6fd226b31de0b94133430b4de8e

2026-11-23T11:08:51+00:00, ClickHouse 26.8.22.13, 200 queries, top-10

| N | quant. | build s | index MB | mode | recall@10 | same intent | server p50 / p95 ms | client p50 ms |
|---|---|---|---|---|---|---|---|---|
| 10,000 | bf16 | 1.1 | 21 | exact | 1.000 | 0.998 | 13.0 / 22.0 | 16.5 |
| 10,000 | bf16 | 1.1 | 21 | ef16 | 0.990 | 0.998 | 3.0 / 7.0 | 5.9 |
| 10,000 | bf16 | 1.1 | 21 | ef64 | 0.997 | 0.998 | 3.0 / 7.0 | 7.8 |
| 10,000 | bf16 | 1.1 | 21 | ef256 | 0.997 | 0.998 | 4.0 / 10.0 | 8.2 |
| 50,000 | bf16 | 8.0 | 106 | exact | 1.000 | 1.000 | 59.0 / 114.1 | 63.1 |
| 50,000 | bf16 | 8.0 | 106 | ef16 | 0.984 | 1.000 | 4.0 / 11.0 | 7.3 |
| 50,000 | bf16 | 8.0 | 106 | ef64 | 0.998 | 1.000 | 6.0 / 13.0 | 11.3 |
| 50,000 | bf16 | 8.0 | 106 | ef256 | 0.998 | 1.000 | 5.0 / 13.0 | 10.8 |
| 100,000 | bf16 | 25.8 | 212 | exact | 1.000 | 1.000 | 102.5 / 327.7 | 112.2 |
| 100,000 | bf16 | 25.8 | 212 | ef16 | 0.975 | 0.990 | 9.0 / 37.1 | 14.1 |
| 100,000 | bf16 | 25.8 | 212 | ef64 | 0.993 | 0.995 | 3.0 / 9.0 | 6.2 |
| 100,000 | bf16 | 25.8 | 212 | ef256 | 0.998 | 1.000 | 4.0 / 9.0 | 7.6 |
| 100,000 | bf16 | 25.8 | 212 | findex | 0.018 | nan | 4.0 / 28.1 | 8.1 | rows 0.2
| 100,000 | bf16 | 25.8 | 212 | findex_mult10 | 0.177 | nan | 6.0 / 14.0 | 10.6 | rows 1.8
| 100,000 | bf16 | 25.8 | 212 | findex_mult100 | 1.000 | nan | 15.0 / 45.0 | 22.6 | rows 10.0
| 100,000 | bf16 | 25.8 | 212 | fprefilter | 1.000 | nan | 41.0 / 61.0 | 44.4 | rows 10.0
| 100,000 | bf16 | 25.8 | 212 | fexact | 1.000 | nan | 68.0 / 188.1 | None | rows 10.0
| 100,000 | f32 | 12.4 | 417 | exact | 1.000 | 1.000 | 58.0 / 83.0 | 61.0 |
| 100,000 | f32 | 12.4 | 417 | ef16 | 0.978 | 0.985 | 4.0 / 10.0 | 6.5 |
| 100,000 | f32 | 12.4 | 417 | ef64 | 1.000 | 1.000 | 5.0 / 11.0 | 8.6 |
| 100,000 | f32 | 12.4 | 417 | ef256 | 1.000 | 1.000 | 4.0 / 9.0 | 6.1 |
| 100,000 | i8 | 7.7 | 105 | exact | 1.000 | 1.000 | 69.0 / 92.0 | 72.3 |
| 100,000 | i8 | 7.7 | 105 | ef16 | 0.957 | 1.000 | 2.0 / 4.0 | 5.1 |
| 100,000 | i8 | 7.7 | 105 | ef64 | 0.962 | 1.000 | 2.0 / 4.0 | 4.8 |
| 100,000 | i8 | 7.7 | 105 | ef256 | 0.962 | 1.000 | 3.0 / 7.0 | 6.2 |
| 100,000 | i8 | 7.7 | 105 | rescore4 | 0.999 | 1.000 | 56.0 / 156.2 | 60.1 |
| 100,000 | b1 | 4.0 | 20 | exact | 1.000 | 1.000 | 67.0 / 95.1 | 70.1 |
| 100,000 | b1 | 4.0 | 20 | ef16 | 0.835 | 0.990 | 2.0 / 3.0 | 4.1 |
| 100,000 | b1 | 4.0 | 20 | ef64 | 0.846 | 1.000 | 2.0 / 3.0 | 4.1 |
| 100,000 | b1 | 4.0 | 20 | ef256 | 0.850 | 1.000 | 2.0 / 3.0 | 4.1 |
| 100,000 | b1 | 4.0 | 20 | rescore4 | 0.998 | 1.000 | 48.0 / 72.0 | 52.4 |

written labs/v4/langfuse-ch-vector/results/bench-2026-11-23.json
```

## 08-check.py

```text
PASS  every root input/output of the lab's traces is embedded exactly once  (events_full 482, embeddings 482, distinct 482)
PASS  re-running 03-embed.py embeds 0 texts  (watermark 2026-11-23 10:52:30.864000 -> 2026-11-23 10:52:30.864000; embedded 0 texts of 0 traces (read 0.02s, model load 0.00s, embed 0.00s, insert 0.00s); removed 0 rows of deleted traces)
PASS  vectors have 1024 dimensions and L2 norm 1 (±0.001)  ({"dmin": 1024, "dmax": 1024, "nmin": 1, "nmax": 1})
PASS  failing trace: at least 8 of its 10 nearest traces are 'app_error'  (10/10, trace 72be9f5bb1721422f205126536446565)
PASS  negative control: an exchange question has no 'app_error' trace among its 10 nearest  (0/10)
PASS  index + WHERE kind = 'input': post-filtering returns < 10 rows, pre-filtering 10  (post 9, pre 10)
PASS  topics of the latest 05-topics.py run: adjusted Rand index >= 0.7  (run 20261123T105258Z, ARI 0.851)
PASS  bench: EXPLAIN shows the vector index for index queries, not for exact ones  (bench-2026-11-23.json)
PASS  bench: recall@10 >= 0.95 with bf16 at the default ef_search 256, every size  (min 0.997)
PASS  bench: every table was searched as one part

10 passed, 0 failed
```

## 08-check.py --fault

```text
PASS  every root input/output of the lab's traces is embedded exactly once  (events_full 482, embeddings 482, distinct 482)
PASS  re-running 03-embed.py embeds 0 texts  (watermark 2026-11-23 10:52:30.864000 -> 2026-11-23 10:52:30.864000; embedded 0 texts of 0 traces (read 0.03s, model load 0.00s, embed 0.00s, insert 0.00s); removed 0 rows of deleted traces)
PASS  vectors have 1024 dimensions and L2 norm 1 (±0.001)  ({"dmin": 1024, "dmax": 1024, "nmin": 1, "nmax": 1})
FAIL  failing trace: at least 8 of its 10 nearest traces are 'fx'  (0/10, trace 72be9f5bb1721422f205126536446565)
FAIL  negative control: an exchange question has no 'fx' trace among its 10 nearest  (6/10)
PASS  index + WHERE kind = 'input': post-filtering returns < 10 rows, pre-filtering 10  (post 9, pre 10)
PASS  topics of the latest 05-topics.py run: adjusted Rand index >= 0.7  (run 20261123T105258Z, ARI 0.851)
PASS  bench: EXPLAIN shows the vector index for index queries, not for exact ones  (bench-2026-11-23.json)
PASS  bench: recall@10 >= 0.95 with bf16 at the default ef_search 256, every size  (min 0.997)
PASS  bench: every table was searched as one part

8 passed, 2 failed
```

The full per-table results of 07-bench.py (JSON lines above the table) are in [results/bench-2026-11-23.json](results/bench-2026-11-23.json).
