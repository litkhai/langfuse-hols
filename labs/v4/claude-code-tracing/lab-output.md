# claude-code-tracing — execution log

Final run on 2026-11-13, 2026-11-13T14:39:30Z to 2026-11-13T14:40:34Z, from purged volumes
(`99-down.sh --purge` first). Langfuse v4.56.0 (`events_only`), langfuse SDK 4.17.0 in the hook venv,
ClickHouse 26.8.22.13, Claude Code 2.1.220 (`claude -p --model haiku`, `claude-haiku-4-5-20251001`),
Docker 29.9.3, Compose v5.7.0, Python 3.12.14. Session ids and the fake values differ on every run;
the fake values are not in this file (`.run/fakes.json`, gitignored). The home directory is written as `~`.

## `./01-up.sh`

```text
$ ./01-up.sh
✓ Langfuse {"status":"OK","version":"4.56.0"} on http://localhost:13000
```

## `./02-install-hook.sh`

```text
$ ./02-install-hook.sh
✓ published hook script matches the pin (6dfb65d9c910…)
✓ hook installed in labs/v4/claude-code-tracing/.run/hook (langfuse 4.17.0)
```

## `python3 03-runs.py`

```text
$ python3 03-runs.py
  masked   allowed  session a3365358  answer '8'  0.015089749999999999 USD
  prompts  allowed  session 225f1592  answer '8 lines.'  0.009297550000000002 USD
  none     allowed  session df062960  answer '8 lines.'  0.007598800000000001 USD
  full     allowed  session 919c555d  answer '8 lines'  0.008691300000000002 USD
  masked   denied   session d2617066  answer '8 lines'  0.0136685 USD
  hook log: 4 uploads finished (4 expected)
```

## `python3 04-check.py`

```text
$ python3 04-check.py
PASS  denied repository: nothing stored  (0 rows)
PASS  masked: trace stored, tagged allowed-lab, Tool: Read kept  (4 observations)
PASS  prompts: trace stored, tagged allowed-lab, Tool: Read kept  (4 observations)
PASS  none: trace stored, tagged allowed-lab, Tool: Read kept  (4 observations)
PASS  full: trace stored, tagged allowed-lab, Tool: Read kept  (4 observations)
PASS  masked: no fake value stored in ClickHouse  (0 of 6)
PASS  prompts: no fake value stored in ClickHouse  (0 of 6)
PASS  none: no fake value stored in ClickHouse  (0 of 6)
PASS  full: all 6 fake values stored (positive control)  (6 found)
PASS  masked: prompt text kept, secret replaced
PASS  masked: tool output kept, secrets replaced
PASS  prompts: prompt replaced by its length
PASS  prompts: tool output kept, secrets replaced
PASS  none: prompt and tool output hidden
PASS  masked: no home directory path stored  (0 rows)
PASS  prompts: no home directory path stored  (0 rows)
PASS  none: no home directory path stored  (0 rows)
PASS  full: home directory path stored (positive control)  (1 rows)
PASS  none: model and token counts kept  (56205 tokens)
PASS  masked: no fake value in its raw event file  (1 files)
PASS  prompts: no fake value in its raw event file  (1 files)
PASS  none: no fake value in its raw event file  (1 files)
PASS  full: fake values in its raw event file (positive control)  (1 files, 6 values)
PASS  denied repository: no raw event file
{
 "observations_per_turn": [
  {
   "session_id": "225f1592-fb05-4725-ad6c-474e259151a4",
   "n": 4,
   "gens": 2,
   "tools": 1
  },
  {
   "session_id": "919c555d-f624-4a7a-a59a-d9735d1df2ec",
   "n": 4,
   "gens": 2,
   "tools": 1
  },
  {
   "session_id": "a3365358-f2f5-4f6f-9b75-a0388969b95c",
   "n": 4,
   "gens": 2,
   "tools": 1
  },
  {
   "session_id": "df062960-fba5-4153-9408-c9f4928322ac",
   "n": 4,
   "gens": 2,
   "tools": 1
  }
 ],
 "tokens_by_repo": [
  {
   "repo": "allowed-lab",
   "sessions": 4,
   "input": 72,
   "output": 1978,
   "cache_read": 216204,
   "cache_write": 7276,
   "langfuse_cost_usd": 0.040677
  }
 ],
 "hook_upload_seconds": {
  "min": 0.04,
  "max": 0.44,
  "n": 4
 },
 "stop_sh_return_ms": 72,
 "claude_cost_usd": {
  "masked/allowed": 0.015089749999999999,
  "prompts/allowed": 0.009297550000000002,
  "none/allowed": 0.007598800000000001,
  "full/allowed": 0.008691300000000002,
  "masked/denied": 0.0136685
 }
}

24 PASS, 0 FAIL
04 exit=0
```

## `python3 04-check.py --fault`

```text
$ python3 04-check.py --fault
PASS  denied repository: nothing stored  (0 rows)
PASS  masked: trace stored, tagged allowed-lab, Tool: Read kept  (4 observations)
PASS  prompts: trace stored, tagged allowed-lab, Tool: Read kept  (4 observations)
PASS  none: trace stored, tagged allowed-lab, Tool: Read kept  (4 observations)
PASS  full: trace stored, tagged allowed-lab, Tool: Read kept  (4 observations)
FAIL  masked: all 6 fake values stored (positive control)  (0 found)
PASS  prompts: no fake value stored in ClickHouse  (0 of 6)
PASS  none: no fake value stored in ClickHouse  (0 of 6)
FAIL  full: no fake value stored in ClickHouse  (aws_key_id, aws_secret, db_password, url_password, lf_secret, prompt_password)
PASS  masked: prompt text kept, secret replaced
PASS  masked: tool output kept, secrets replaced
PASS  prompts: prompt replaced by its length
PASS  prompts: tool output kept, secrets replaced
PASS  none: prompt and tool output hidden
PASS  masked: no home directory path stored  (0 rows)
PASS  prompts: no home directory path stored  (0 rows)
PASS  none: no home directory path stored  (0 rows)
PASS  full: home directory path stored (positive control)  (1 rows)
PASS  none: model and token counts kept  (56205 tokens)
FAIL  masked: fake values in its raw event file (positive control)  (1 files, 0 values)
PASS  prompts: no fake value in its raw event file  (1 files)
PASS  none: no fake value in its raw event file  (1 files)
FAIL  full: no fake value in its raw event file  (1 files)
PASS  denied repository: no raw event file
{
 "observations_per_turn": [
  {
   "session_id": "225f1592-fb05-4725-ad6c-474e259151a4",
   "n": 4,
   "gens": 2,
   "tools": 1
  },
  {
   "session_id": "919c555d-f624-4a7a-a59a-d9735d1df2ec",
   "n": 4,
   "gens": 2,
   "tools": 1
  },
  {
   "session_id": "a3365358-f2f5-4f6f-9b75-a0388969b95c",
   "n": 4,
   "gens": 2,
   "tools": 1
  },
  {
   "session_id": "df062960-fba5-4153-9408-c9f4928322ac",
   "n": 4,
   "gens": 2,
   "tools": 1
  }
 ],
 "tokens_by_repo": [
  {
   "repo": "allowed-lab",
   "sessions": 4,
   "input": 72,
   "output": 1978,
   "cache_read": 216204,
   "cache_write": 7276,
   "langfuse_cost_usd": 0.040677
  }
 ],
 "hook_upload_seconds": {
  "min": 0.04,
  "max": 0.44,
  "n": 4
 },
 "stop_sh_return_ms": 69,
 "claude_cost_usd": {
  "masked/allowed": 0.015089749999999999,
  "prompts/allowed": 0.009297550000000002,
  "none/allowed": 0.007598800000000001,
  "full/allowed": 0.008691300000000002,
  "masked/denied": 0.0136685
 }
}

20 PASS, 4 FAIL  (--fault: failures expected)
04 --fault exit=1
```

## What the runs stored

Read from `events_full` after the run, on the same stack.

### `masked`

```text
turn input : {"role": "user", "content": "Read config.env and answer with the number of lines only. Ticket note, ignore it: DB_PASSWORD=[REDACTED:secret]"}
turn output: {"role": "assistant", "content": "8"}
Tool: Read input : {"file_path": "~/Documents/GitHub/langfuse-hols-cc104/labs/v4/claude-code-tracing/.run/repos/allowed/config.env"}
Tool: Read output:
1	# lab fixture, fake values generated by 03-runs.py
2	AWS_ACCESS_KEY_ID=[REDACTED:aws-access-key-id]
3	AWS_SECRET_ACCESS_KEY=[REDACTED:secret]
4	CLICKHOUSE_PASSWORD=[REDACTED:secret]
5	DATABASE_URL=postgres://app:[REDACTED:password]@db:5432/app
6	LANGFUSE_SECRET_KEY=[REDACTED:langfuse-key]
7	LOG_LEVEL=info
8
```

### `prompts`

```text
turn input : {"role": "user", "content": "[prompt hidden: 108 chars]"}
turn output: {"role": "assistant", "content": "8 lines."}
Tool: Read input : {"file_path": "~/Documents/GitHub/langfuse-hols-cc104/labs/v4/claude-code-tracing/.run/repos/allowed/config.env"}
Tool: Read output:
1	# lab fixture, fake values generated by 03-runs.py
2	AWS_ACCESS_KEY_ID=[REDACTED:aws-access-key-id]
3	AWS_SECRET_ACCESS_KEY=[REDACTED:secret]
4	CLICKHOUSE_PASSWORD=[REDACTED:secret]
5	DATABASE_URL=postgres://app:[REDACTED:password]@db:5432/app
6	LANGFUSE_SECRET_KEY=[REDACTED:langfuse-key]
7	LOG_LEVEL=info
8
```

### `none`

```text
turn input : {"role": "[hidden: 4 chars]", "content": "[hidden: 108 chars]"}
turn output: {"role": "[hidden: 9 chars]", "content": "[hidden: 8 chars]"}
Tool: Read input : {"file_path": "[hidden: 108 chars]"}
Tool: Read output:
[hidden: 336 chars]
```

The `full` run is the positive control: its rows hold the six fake values and the home path, so they are not reproduced here.

## SQL over `events_full`

```sql
SELECT provided_model_name AS model, count() AS generations, sum(usage_details['input']) AS input, sum(usage_details['output']) AS output, sum(usage_details['cache_read_input_tokens']) AS cache_read, sum(usage_details['cache_creation_input_tokens']) AS cache_write, round(sum(total_cost), 6) AS cost_usd FROM events_full WHERE type = 'GENERATION' AND has(tags, 'claude-code') GROUP BY model ORDER BY cost_usd DESC;
```

```text
   ┌─model─────────────────────┬─generations─┬─input─┬─output─┬─cache_read─┬─cache_write─┬─cost_usd─┐
1. │ claude-haiku-4-5-20251001 │           8 │    72 │   1978 │     216204 │        7276 │ 0.040677 │
   └───────────────────────────┴─────────────┴───────┴────────┴────────────┴─────────────┴──────────┘
```

```sql
SELECT session_id, arrayFilter(t -> t != 'claude-code', any(tags)) AS repo, count() AS observations, countIf(type = 'GENERATION') AS gens, round(sum(total_cost), 6) AS cost_usd, dateDiff('millisecond', min(start_time), max(end_time)) AS ms FROM events_full GROUP BY session_id ORDER BY session_id;
```

```text
   ┌─session_id───────────────────────────┬─repo────────────┬─observations─┬─gens─┬─cost_usd─┬───ms─┐
1. │ 225f1592-fb05-4725-ad6c-474e259151a4 │ ['allowed-lab'] │            4 │    2 │ 0.009298 │ 6613 │
2. │ 919c555d-f624-4a7a-a59a-d9735d1df2ec │ ['allowed-lab'] │            4 │    2 │ 0.008691 │ 5941 │
3. │ a3365358-f2f5-4f6f-9b75-a0388969b95c │ ['allowed-lab'] │            4 │    2 │  0.01509 │ 4650 │
4. │ df062960-fba5-4153-9408-c9f4928322ac │ ['allowed-lab'] │            4 │    2 │ 0.007599 │ 4500 │
   └──────────────────────────────────────┴─────────────────┴──────────────┴──────┴──────────┴──────┘
```

```sql
SELECT name, type, count() AS n FROM events_full WHERE has(tags, 'claude-code') GROUP BY name, type ORDER BY name;
```

```text
   ┌─name─────────────────┬─type───────┬─n─┐
1. │ Claude Code - Turn 1 │ SPAN       │ 4 │
2. │ Claude Generation 1  │ GENERATION │ 4 │
3. │ Claude Generation 2  │ GENERATION │ 4 │
4. │ Tool: Read           │ TOOL       │ 4 │
   └──────────────────────┴────────────┴───┘
```
