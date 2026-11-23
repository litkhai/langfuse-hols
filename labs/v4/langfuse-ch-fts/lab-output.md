# lab-output — verified run of 2026-11-23

Full output of the end-to-end run behind the Verified line of [README.md](README.md): from an empty lab database and no traces tagged `lab:langfuse-ch-fts` (removed first with `99-down.sh --traces`), on the shared v4 stack (Langfuse v4.56.0, SDK 4.17.0, ClickHouse 26.8.22.13) and the lab's own ClickHouse 26.10.10.3, then 26.8.22.13 for the second benchmark. The steps ran in the order of the README's Run section (the wait between 02 and 03 polled `events_full` until 9,000 rows were there). Timestamps are UTC; the host load average printed by 06-bench.py shows how busy the shared laptop was.

```text
2026-11-23T10:57:40Z

$ bash labs/v4/langfuse-ch-fts/01-up.sh
• shared stack ClickHouse 26.8.22.13
• lab ClickHouse 26.10.10.3 on 127.0.0.1:38123 (container lf-ch-fts-ch, 3 GiB cap)

$ .venv-v4/bin/python labs/v4/langfuse-ch-fts/02-seed.py
  …500/3000 traces
  …1000/3000 traces
  …1500/3000 traces
  …2000/3000 traces
  …2500/3000 traces
  …3000/3000 traces
✓ 3000 traces, batch base, tag lab:langfuse-ch-fts
(waiting until events_full has 9000 lab rows)

$ python3 labs/v4/langfuse-ch-fts/lablib.py LF labs/v4/langfuse-ch-fts/03-copy-mv.sql
  [LF] CREATE DATABASE IF NOT EXISTS lab_langfuse_ch_fts
  [LF] DROP VIEW IF EXISTS lab_langfuse_ch_fts.events_text_mv
  [LF] DROP TABLE IF EXISTS lab_langfuse_ch_fts.events_text
  [LF] CREATE TABLE lab_langfuse_ch_fts.events_text
  [LF] CREATE MATERIALIZED VIEW lab_langfuse_ch_fts.events_text_mv TO lab_langfuse_ch_fts.events_text AS
  [LF] INSERT INTO lab_langfuse_ch_fts.events_text
  [LF] OPTIMIZE TABLE lab_langfuse_ch_fts.events_text FINAL
  [LF] SELECT count() AS rows, uniqExact(trace_id) AS traces, countIf(input_text LIKE '%대출%') AS input_with
   ┌─rows─┬─traces─┬─input_with_daechul─┐
1. │ 9000 │   3000 │               1572 │
   └──────┴────────┴────────────────────┘

$ python3 labs/v4/langfuse-ch-fts/04-tokenizers.py
── 1. tokens() of one sentence
   주택담보대출을 OTP가 API timeout으로
   splitByNonAlpha  ['주택담보대출을','OTP가','API','timeout으로']
   icu('ko')        ['주택담보대출을','OTP','가','API','timeout','으로']
   asciiCJK         ['주','택','담','보','대','출','을','OTP','가','API','timeout','으','로']
   ngrams(2)        ['주택','택담','담보','보대','대출','출을','을 ',' O','OT','TP','P가','가 ',' A','AP','PI','I ',' t','ti','im','me','eo','ou','ut','t으','으로']
   ngrams(3)        ['주택담','택담보','담보대','보대출','대출을','출을 ','을 O',' OT','OTP','TP가','P가 ','가 A',' AP','API','PI ','I t',' ti','tim','ime','meo','eou','out','ut으','t으로']
   sparseGrams      ['주택담','택담보','담보대','보대출','담보대출','대출을','담보대출을','출을 ','을 O',' OT','OTP',' OTP','TP가','P가 ','TP가 ','가 A','TP가 A',' OTP가 A','을 OTP가 A',' AP','API','PI ','API ',' API ','I t',' ti','tim',' tim','ime',' time','meo',' timeo','eou','out','eout','ut으','eout으',' timeout으','I timeout으',' API timeout으','t으로']
── 2. JSON decode used by the copy (03-copy-mv.sql)
   LF: [{"role":"user","content":"대출을 갚으면"}]
   FTS: [{"role":"user","content":"대출을 갚으면"}]
── 3. index per tokenizer, 9000 rows, every term through the index function
   splitByNonAlpha
     대출         truth  1572  needle ['대출']                                   hasAllTokens: found 1322, missed 250, false+ 0 | hasPhrase: found 1322, missed 250, false+ 0 | hasToken: found 1322, missed 250, false+ 0
     주택담보대출     truth   782  needle ['주택담보대출']                               hasAllTokens: found 261, missed 521, false+ 0 | hasPhrase: found 261, missed 521, false+ 0 | hasToken: found 261, missed 521, false+ 0
     담보대출       truth   782  needle ['담보대출']                                 hasAllTokens: found 0, missed 782, false+ 0 | hasPhrase: found 0, missed 782, false+ 0 | hasToken: found 0, missed 782, false+ 0
     비밀번호 재설정   truth   836  needle ['비밀번호','재설정']                           hasAllTokens: found 836, missed 0, false+ 0 | hasPhrase: found 836, missed 0, false+ 0 | hasToken: FTS: Code: 277. DB::Exception: Index `idx` is not used and setting 'force_data_skipping_indices' contains it. (INDEX_NOT_USED) (version 26.10.10.3 (official build))
     환불요청       truth  1073  needle ['환불요청']                                 hasAllTokens: found 903, missed 170, false+ 0 | hasPhrase: found 903, missed 170, false+ 0 | hasToken: found 903, missed 170, false+ 0
     OTP        truth  1182  needle ['otp']                                  hasAllTokens: found 665, missed 517, false+ 0 | hasPhrase: found 665, missed 517, false+ 0 | hasToken: found 665, missed 517, false+ 0
     앱          truth  3767  needle ['앱']                                    hasAllTokens: found 1289, missed 2478, false+ 0 | hasPhrase: found 1289, missed 2478, false+ 0 | hasToken: found 1289, missed 2478, false+ 0
     timeout    truth  1069  needle ['timeout']                              hasAllTokens: found 933, missed 136, false+ 0 | hasPhrase: found 933, missed 136, false+ 0 | hasToken: found 933, missed 136, false+ 0
   icu('ko')
     대출         truth  1572  needle ['대출']                                   hasAllTokens: found 1322, missed 250, false+ 0
     주택담보대출     truth   782  needle ['주택담보대출']                               hasAllTokens: found 261, missed 521, false+ 0
     담보대출       truth   782  needle ['담보대출']                                 hasAllTokens: found 0, missed 782, false+ 0
     비밀번호 재설정   truth   836  needle ['비밀번호','재설정']                           hasAllTokens: found 836, missed 0, false+ 0
     환불요청       truth  1073  needle ['환불요청']                                 hasAllTokens: found 903, missed 170, false+ 0
     OTP        truth  1182  needle ['otp']                                  hasAllTokens: found 1182, missed 0, false+ 0
     앱          truth  3767  needle ['앱']                                    hasAllTokens: found 1289, missed 2478, false+ 0
     timeout    truth  1069  needle ['timeout']                              hasAllTokens: found 1069, missed 0, false+ 0
   asciiCJK
     대출         truth  1572  needle ['대','출']                                hasAllTokens: found 1792, missed 0, false+ 220 | hasPhrase: found 1572, missed 0, false+ 0
     주택담보대출     truth   782  needle ['주','택','담','보','대','출']                hasAllTokens: found 782, missed 0, false+ 0 | hasPhrase: found 782, missed 0, false+ 0
     담보대출       truth   782  needle ['담','보','대','출']                        hasAllTokens: found 782, missed 0, false+ 0 | hasPhrase: found 782, missed 0, false+ 0
     비밀번호 재설정   truth   836  needle ['비','밀','번','호','재','설','정']            hasAllTokens: found 1147, missed 0, false+ 311 | hasPhrase: found 836, missed 0, false+ 0
     환불요청       truth  1073  needle ['환','불','요','청']                        hasAllTokens: found 1462, missed 0, false+ 389 | hasPhrase: found 1073, missed 0, false+ 0
     OTP        truth  1182  needle ['otp']                                  hasAllTokens: found 1182, missed 0, false+ 0 | hasPhrase: found 1182, missed 0, false+ 0
     앱          truth  3767  needle ['앱']                                    hasAllTokens: found 3767, missed 0, false+ 0 | hasPhrase: found 3767, missed 0, false+ 0
     timeout    truth  1069  needle ['timeout']                              hasAllTokens: found 1069, missed 0, false+ 0 | hasPhrase: found 1069, missed 0, false+ 0
   ngrams(2)
     대출         truth  1572  needle ['대출']                                   hasAllTokens: found 1572, missed 0, false+ 0 | hasPhrase: found 1572, missed 0, false+ 0
     주택담보대출     truth   782  needle ['주택','택담','담보','보대','대출']               hasAllTokens: found 782, missed 0, false+ 0 | hasPhrase: found 782, missed 0, false+ 0
     담보대출       truth   782  needle ['담보','보대','대출']                         hasAllTokens: found 782, missed 0, false+ 0 | hasPhrase: found 782, missed 0, false+ 0
     비밀번호 재설정   truth   836  needle ['비밀','밀번','번호','호 ',' 재','재설','설정']     hasAllTokens: found 836, missed 0, false+ 0 | hasPhrase: found 836, missed 0, false+ 0
     환불요청       truth  1073  needle ['환불','불요','요청']                         hasAllTokens: found 1390, missed 0, false+ 317 | hasPhrase: found 1073, missed 0, false+ 0
     OTP        truth  1182  needle ['ot','tp']                              hasAllTokens: found 1182, missed 0, false+ 0 | hasPhrase: found 1182, missed 0, false+ 0
     앱          truth  3767  needle []                                       hasAllTokens: found 0, missed 3767, false+ 0 | hasPhrase: found 0, missed 3767, false+ 0
     timeout    truth  1069  needle ['ti','im','me','eo','ou','ut']          hasAllTokens: found 1069, missed 0, false+ 0 | hasPhrase: found 1069, missed 0, false+ 0
   ngrams(3)
     대출         truth  1572  needle []                                       hasAllTokens: found 0, missed 1572, false+ 0
     주택담보대출     truth   782  needle ['주택담','택담보','담보대','보대출']                hasAllTokens: found 782, missed 0, false+ 0
     담보대출       truth   782  needle ['담보대','보대출']                            hasAllTokens: found 782, missed 0, false+ 0
     비밀번호 재설정   truth   836  needle ['비밀번','밀번호','번호 ','호 재',' 재설','재설정']    hasAllTokens: found 836, missed 0, false+ 0
     환불요청       truth  1073  needle ['환불요','불요청']                            hasAllTokens: found 1073, missed 0, false+ 0
     OTP        truth  1182  needle ['otp']                                  hasAllTokens: found 1182, missed 0, false+ 0
     앱          truth  3767  needle []                                       hasAllTokens: found 0, missed 3767, false+ 0
     timeout    truth  1069  needle ['tim','ime','meo','eou','out']          hasAllTokens: found 1069, missed 0, false+ 0
   sparseGrams
     대출         truth  1572  needle []                                       hasAllTokens: found 0, missed 1572, false+ 0
     주택담보대출     truth   782  needle ['주택담','택담보','담보대','보대출','담보대출']         hasAllTokens: found 782, missed 0, false+ 0
     담보대출       truth   782  needle ['담보대','보대출','담보대출']                     hasAllTokens: found 782, missed 0, false+ 0
     비밀번호 재설정   truth   836  needle ['비밀번','밀번호','번호 ','밀번호 ','호 재',' 재설','호 재설','재설정'] hasAllTokens: found 836, missed 0, false+ 0
     환불요청       truth  1073  needle ['환불요','불요청']                            hasAllTokens: found 1073, missed 0, false+ 0
     OTP        truth  1182  needle ['otp']                                  hasAllTokens: found 1182, missed 0, false+ 0
     앱          truth  3767  needle []                                       hasAllTokens: found 0, missed 3767, false+ 0
     timeout    truth  1069  needle ['tim','ime','meo','eou','out','eout']   hasAllTokens: found 1069, missed 0, false+ 0
── 4. Langfuse's own search predicate on events_full (stack's server, read only)
   중도상환수수료  answer-generation 0/188  retrieve-context 283/283  support-chat 188/188
   주택담보대출   answer-generation 87/233  retrieve-context 316/316  support-chat 233/233
   OTP      answer-generation 283/370  retrieve-context 442/442  support-chat 370/370
   대출       answer-generation 524/524  retrieve-context 524/524  support-chat 524/524
✓ .run/tokenizers.json (9000 rows, 6 tokenizers, 8 terms)

$ python3 labs/v4/langfuse-ch-fts/05-mv-live.py
── 1. seed 20 traces (batch live) — events_full has 0 live rows, the copy 0
✓ 20 traces, batch live, tag lab:langfuse-ch-fts
   events_full 60 rows, copy 60 rows, missing in copy 0; '대출' through the ngrams(2) index 6 (truth 6); 2.1 s until visible
── 2. delete trace 569351ac53d868d37f825f24c6242ff4 through the public API
   {"message":"Traces deleted successfully"}
   gone from events_full after 67.5 s (statement kind: Delete); still in the copy: 3 rows
── 3. reconcile the copy
   copy rows for the deleted trace after the reconcile DELETE: 0
✓ .run/mv-live.json

$ python3 labs/v4/langfuse-ch-fts/06-bench.py
── lab ClickHouse 26.10.10.3, 220 copies of the seed, 5 runs per query
  b_none  built in 17.2 s (inserts + OPTIMIZE FINAL)
  b_word  built in 32.3 s (inserts + OPTIMIZE FINAL)
  b_ng2   built in 50.8 s (inserts + OPTIMIZE FINAL)
  b_cjk   built in 37.3 s (inserts + OPTIMIZE FINAL)
  대출  (truth 347160)
    LIKE, no index                         347160     309 ms  rows read   1992540  marks   244/245
    ILIKE, no index                        347160     386 ms  rows read   1992540  marks   244/245
    hasToken, splitByNonAlpha              292160      56 ms  rows read   1835008  marks   224/245
    Langfuse UI form, splitByNonAlpha      292160     599 ms  rows read   1835008  marks   224/245
    lower LIKE, ngrams(2)                  347160     482 ms  rows read   1835008  marks   224/245
    hasAllTokens, ngrams(2)                347160      93 ms  rows read   1835008  marks   224/245
    hasPhrase, ngrams(2)                   347160     608 ms  rows read   1835008  marks   224/245
    hasPhrase, asciiCJK                    347160    1559 ms  rows read   1908736  marks   233/245
  중도상환수수료  (truth 145860)
    LIKE, no index                         145860     446 ms  rows read   1992540  marks   244/245
    ILIKE, no index                        145860     541 ms  rows read   1992540  marks   244/245
    hasToken, splitByNonAlpha                   0       6 ms  rows read         0  marks     0/245
    Langfuse UI form, splitByNonAlpha           0       6 ms  rows read         0  marks     0/245
    lower LIKE, ngrams(2)                  145860     494 ms  rows read   1622016  marks   198/245
    hasAllTokens, ngrams(2)                145860      47 ms  rows read   1622016  marks   198/245
    hasPhrase, ngrams(2)                   145860     295 ms  rows read   1622016  marks   198/245
    hasPhrase, asciiCJK                    145860     362 ms  rows read   1884160  marks   230/245
  비밀번호 재설정  (truth 184800)
    LIKE, no index                         184800     252 ms  rows read   1992540  marks   244/245
    ILIKE, no index                        184800     467 ms  rows read   1992540  marks   244/245
    Langfuse UI form, splitByNonAlpha      184800     392 ms  rows read   1695744  marks   207/245
    lower LIKE, ngrams(2)                  184800     371 ms  rows read   1695744  marks   207/245
    hasAllTokens, ngrams(2)                184800      77 ms  rows read   1695744  marks   207/245
    hasPhrase, ngrams(2)                   184800     352 ms  rows read   1695744  marks   207/245
    hasPhrase, asciiCJK                    184800     631 ms  rows read   1810432  marks   221/245
  timeout  (truth 236500)
    LIKE, no index                         236500     335 ms  rows read   1992540  marks   244/245
    ILIKE, no index                        236500     780 ms  rows read   1992540  marks   244/245
    hasToken, splitByNonAlpha              206580     426 ms  rows read   1761280  marks   215/245
    Langfuse UI form, splitByNonAlpha      206580     322 ms  rows read   1761280  marks   215/245
    lower LIKE, ngrams(2)                  236500     535 ms  rows read   1777664  marks   217/245
    hasAllTokens, ngrams(2)                236500      97 ms  rows read   1777664  marks   217/245
    hasPhrase, ngrams(2)                   236500     357 ms  rows read   1777664  marks   217/245
    hasPhrase, asciiCJK                    236500     321 ms  rows read   1777664  marks   217/245
  E1371066  (truth 28)
    LIKE, no index                             28      66 ms  rows read   1992540  marks   244/245
    ILIKE, no index                            28     122 ms  rows read   1992540  marks   244/245
    hasToken, splitByNonAlpha                  19       4 ms  rows read     98304  marks    12/245
    Langfuse UI form, splitByNonAlpha          19      12 ms  rows read     98304  marks    12/245
    lower LIKE, ngrams(2)                      28       9 ms  rows read    122880  marks    15/245
    hasAllTokens, ngrams(2)                    28       3 ms  rows read    122880  marks    15/245
    hasPhrase, ngrams(2)                       28      10 ms  rows read    122880  marks    15/245
    hasPhrase, asciiCJK                        28       9 ms  rows read    122880  marks    15/245
  sizes:
    b_none  rows 1992540  content 869 MiB raw, 2.4 MiB compressed  index 0.0 MiB
    b_word  rows 1992540  content 869 MiB raw, 2.4 MiB compressed  index 61.5 MiB
    b_cjk   rows 1992540  content 869 MiB raw, 2.4 MiB compressed  index 58.6 MiB
    b_ng2   rows 1992540  content 869 MiB raw, 2.4 MiB compressed  index 167.1 MiB
  host load average (1 min): 16.1 at start, 34.1 at end
✓ .run/bench-26.10.10.3.json

$ bash labs/v4/langfuse-ch-fts/01-up.sh
• shared stack ClickHouse 26.8.22.13
• lab ClickHouse 26.8.22.13 on 127.0.0.1:38123 (container lf-ch-fts-ch, 3 GiB cap)

$ python3 labs/v4/langfuse-ch-fts/06-bench.py
── lab ClickHouse 26.8.22.13, 220 copies of the seed, 5 runs per query
  b_none  built in 7.5 s (inserts + OPTIMIZE FINAL)
  b_word  built in 18.7 s (inserts + OPTIMIZE FINAL)
  b_ng2   built in 33.8 s (inserts + OPTIMIZE FINAL)
  b_cjk   built in 24.5 s (inserts + OPTIMIZE FINAL)
  대출  (truth 347160)
    LIKE, no index                         347160     565 ms  rows read   1992540  marks   244/245
    ILIKE, no index                        347160     702 ms  rows read   1992540  marks   244/245
    hasToken, splitByNonAlpha              292160     125 ms  rows read   1835008  marks   224/245
    Langfuse UI form, splitByNonAlpha      292160     553 ms  rows read   1835008  marks   224/245
    lower LIKE, ngrams(2)                  347160     714 ms  rows read   1835008  marks   224/245
    hasAllTokens, ngrams(2)                347160     112 ms  rows read   1835008  marks   224/245
    hasPhrase, ngrams(2)                   347160     582 ms  rows read   1835008  marks   224/245
    hasPhrase, asciiCJK                    347160     585 ms  rows read   1908736  marks   233/245
  중도상환수수료  (truth 145860)
    LIKE, no index                         145860     266 ms  rows read   1992540  marks   244/245
    ILIKE, no index                        145860     236 ms  rows read   1992540  marks   244/245
    hasToken, splitByNonAlpha                   0       2 ms  rows read         0  marks     0/245
    Langfuse UI form, splitByNonAlpha           0       3 ms  rows read         0  marks     0/245
    lower LIKE, ngrams(2)                  145860     209 ms  rows read   1622016  marks   198/245
    hasAllTokens, ngrams(2)                145860      74 ms  rows read   1622016  marks   198/245
    hasPhrase, ngrams(2)                   145860     228 ms  rows read   1622016  marks   198/245
    hasPhrase, asciiCJK                    145860     332 ms  rows read   1884160  marks   230/245
  비밀번호 재설정  (truth 184800)
    LIKE, no index                         184800     253 ms  rows read   1992540  marks   244/245
    ILIKE, no index                        184800     213 ms  rows read   1992540  marks   244/245
    Langfuse UI form, splitByNonAlpha      184800     218 ms  rows read   1695744  marks   207/245
    lower LIKE, ngrams(2)                  184800     140 ms  rows read   1695744  marks   207/245
    hasAllTokens, ngrams(2)                184800      44 ms  rows read   1695744  marks   207/245
    hasPhrase, ngrams(2)                   184800     255 ms  rows read   1695744  marks   207/245
    hasPhrase, asciiCJK                    184800     348 ms  rows read   1810432  marks   221/245
  timeout  (truth 236500)
    LIKE, no index                         236500     626 ms  rows read   1992540  marks   244/245
    ILIKE, no index                        236500     326 ms  rows read   1992540  marks   244/245
    hasToken, splitByNonAlpha              206580      91 ms  rows read   1761280  marks   215/245
    Langfuse UI form, splitByNonAlpha      206580     361 ms  rows read   1761280  marks   215/245
    lower LIKE, ngrams(2)                  236500     383 ms  rows read   1777664  marks   217/245
    hasAllTokens, ngrams(2)                236500      52 ms  rows read   1777664  marks   217/245
    hasPhrase, ngrams(2)                   236500     257 ms  rows read   1777664  marks   217/245
    hasPhrase, asciiCJK                    236500     318 ms  rows read   1777664  marks   217/245
  E1371066  (truth 28)
    LIKE, no index                             28     317 ms  rows read   1992540  marks   244/245
    ILIKE, no index                            28     261 ms  rows read   1992540  marks   244/245
    hasToken, splitByNonAlpha                  19      12 ms  rows read     98304  marks    12/245
    Langfuse UI form, splitByNonAlpha          19      29 ms  rows read     98304  marks    12/245
    lower LIKE, ngrams(2)                      28      73 ms  rows read    122880  marks    15/245
    hasAllTokens, ngrams(2)                    28      10 ms  rows read    122880  marks    15/245
    hasPhrase, ngrams(2)                       28      31 ms  rows read    122880  marks    15/245
    hasPhrase, asciiCJK                        28      15 ms  rows read    122880  marks    15/245
  sizes:
    b_none  rows 1992540  content 869 MiB raw, 2.4 MiB compressed  index 0.0 MiB
    b_word  rows 1992540  content 869 MiB raw, 2.4 MiB compressed  index 61.5 MiB
    b_cjk   rows 1992540  content 869 MiB raw, 2.4 MiB compressed  index 58.4 MiB
    b_ng2   rows 1992540  content 869 MiB raw, 2.4 MiB compressed  index 167.0 MiB
  host load average (1 min): 34.9 at start, 36.6 at end
✓ .run/bench-26.8.22.13.json

$ python3 labs/v4/langfuse-ch-fts/07-check.py
── Langfuse's own table (read only)
  ✓ events_full.input holds Korean as \uXXXX escapes: LIKE '%대출%' finds 0 inputs
  ✓ … and the escaped form \ub300\ucd9c finds them (positive control)
  ✓ … while a plain-string output stays Hangul: LIKE '%대출%' on answer-generation output > 0
  ✓ events_full carries Langfuse's own text index lower(input) … splitByNonAlpha
── the copy and its materialized view
  ✓ copy rows (FINAL) = events_full rows with the lab tag (9057 = 9057)
  ✓ copy input_text has Hangul: LIKE '%대출%' > 0
  ✓ copy holds only lab rows
  ✓ MV: every new live row reached the copy
  ✓ MV: new rows are searchable through the ngrams(2) index (index count = truth)
  ✓ delete through the API removed the trace from events_full but not from the copy
  ✓ reconcile DELETE removed it from the copy
── tokenizers (.run/tokenizers.json)
  ✓ splitByNonAlpha finds none of 담보대출 (inside 주택담보대출)
  ✓ splitByNonAlpha misses the particle forms of 대출
  ✓ ngrams(2) hasAllTokens misses nothing (all terms but the one-syllable 앱)
  ✓ ngrams(2) hasAllTokens has false positives on 환불요청
  ✓ ngrams(2) finds nothing for a one-syllable term (empty needle)
  ✓ asciiCJK hasPhrase is exact on every term
  ✓ Langfuse UI predicate: 0 answer-generation rows (plain-string output) for 중도상환수수료
  ✓ Langfuse UI predicate: every support-chat row (JSON-escaped output) for 중도상환수수료
  ✓ the JSON decode gives Hangul on both servers
── benchmark (.run/bench-*.json)
  ✓ [26.10.10.3] LIKE, ILIKE and hasPhrase return the true count for every term
  ✓ [26.10.10.3] the Langfuse UI search form finds 0 of 145860 rows for 중도상환수수료
  ✓ [26.10.10.3] rare term: LIKE without index reads every row (1992540)
  ✓ [26.10.10.3] rare term: ngrams(2) hasAllTokens reads < 10% of the rows (122880)
  ✓ [26.8.22.13] LIKE, ILIKE and hasPhrase return the true count for every term
  ✓ [26.8.22.13] the Langfuse UI search form finds 0 of 145860 rows for 중도상환수수료
  ✓ [26.8.22.13] rare term: LIKE without index reads every row (1992540)
  ✓ [26.8.22.13] rare term: ngrams(2) hasAllTokens reads < 10% of the rows (122880)
28/28 checks passed

$ python3 labs/v4/langfuse-ch-fts/07-check.py --fault
── Langfuse's own table (read only)
  ✓ events_full.input holds Korean as \uXXXX escapes: LIKE '%대출%' finds 0 inputs
  ✓ … and the escaped form \ub300\ucd9c finds them (positive control)
  ✓ … while a plain-string output stays Hangul: LIKE '%대출%' on answer-generation output > 0
  ✓ events_full carries Langfuse's own text index lower(input) … splitByNonAlpha
── the copy and its materialized view
  ✓ copy rows (FINAL) = events_full rows with the lab tag (9057 = 9057)
  ✓ copy input_text has Hangul: LIKE '%대출%' > 0
  ✓ copy holds only lab rows
  ✓ MV: every new live row reached the copy
  ✓ MV: new rows are searchable through the ngrams(2) index (index count = truth)
  ✓ delete through the API removed the trace from events_full but not from the copy
  ✓ reconcile DELETE removed it from the copy
── tokenizers (.run/tokenizers.json)
  ✗ splitByNonAlpha finds none of 담보대출 (inside 주택담보대출)
  ✓ splitByNonAlpha misses the particle forms of 대출
  ✓ ngrams(2) hasAllTokens misses nothing (all terms but the one-syllable 앱)
  ✓ ngrams(2) hasAllTokens has false positives on 환불요청
  ✓ ngrams(2) finds nothing for a one-syllable term (empty needle)
  ✓ asciiCJK hasPhrase is exact on every term
  ✓ Langfuse UI predicate: 0 answer-generation rows (plain-string output) for 중도상환수수료
  ✓ Langfuse UI predicate: every support-chat row (JSON-escaped output) for 중도상환수수료
  ✓ the JSON decode gives Hangul on both servers
── benchmark (.run/bench-*.json)
  ✓ [26.10.10.3] LIKE, ILIKE and hasPhrase return the true count for every term
  ✗ [26.10.10.3] the Langfuse UI search form finds 0 of 145860 rows for 중도상환수수료
  ✓ [26.10.10.3] rare term: LIKE without index reads every row (1992540)
  ✓ [26.10.10.3] rare term: ngrams(2) hasAllTokens reads < 10% of the rows (122880)
  ✓ [26.8.22.13] LIKE, ILIKE and hasPhrase return the true count for every term
  ✗ [26.8.22.13] the Langfuse UI search form finds 0 of 145860 rows for 중도상환수수료
  ✓ [26.8.22.13] rare term: LIKE without index reads every row (1992540)
  ✓ [26.8.22.13] rare term: ngrams(2) hasAllTokens reads < 10% of the rows (122880)
25/28 checks passed (--fault)
(--fault failed as it must)
2026-11-23T11:06:21Z
```
