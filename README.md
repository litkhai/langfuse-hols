# Langfuse on ClickHouse Hands-on Labs

[English](#english) | [한국어](#한국어)

## English

Self-hosting Langfuse on ClickHouse (OSS and Enterprise tracks) and Langfuse's evaluation loop, with every result read back from Langfuse's ClickHouse tables.

> This repository was split out of [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols) on the `pre-split-2026-10` tag, with history. The last version of these labs in the original repository: https://github.com/litkhai/clickhouse-hols/tree/pre-split-2026-10

### 🧪 Labs (`labs/`)

Each lab comes in two tracks, one per Langfuse major version. Pick the one your deployment
runs. **v4 is the current track**; Langfuse v3 gets security patches only until 2027-01-31.

| Lab | Langfuse v4 | Langfuse v3 | What it covers |
|-----|---|---|----------------|
| langfuse-ee | [labs/v4/langfuse-ee](labs/v4/langfuse-ee/) | [labs/v3/langfuse-ee](labs/v3/langfuse-ee/) | Self-hosting Langfuse on ClickHouse (OSS + Enterprise) |
| langfuse-eval | [labs/v4/langfuse-eval](labs/v4/langfuse-eval/) | [labs/v3/langfuse-eval](labs/v3/langfuse-eval/) | Langfuse prompts, datasets, experiments and evals |

All four run on the shared stack in [`_base/`](_base/). The track is the first argument of
its scripts (`_base/bin/up.sh v4`), and its pins are in `_base/<track>/versions.env`.

### 📖 Reading (`reading/`)

Background pages, not labs: nothing in them is run.

| Page | What it covers |
|---|---|
| [Langfuse behind an Azure API Management AI gateway](reading/azure-apim-gateway.md) | Getting traces into Langfuse when every model call goes through APIM; Entra ID; where ClickHouse runs on Azure |

### 🔗 Related repositories

| Repository | What it is |
|---|---|
| [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols) | Core ClickHouse hands-on labs |
| [litkhai/llmops-in-a-box](https://github.com/litkhai/llmops-in-a-box) | LLMOps stack in a box |

### ✅ Repository checks

Current state and what still needs a re-run: [STATUS.md](STATUS.md).

```bash
git config core.hooksPath .githooks
python3 .github/scripts/check_links.py
./.github/scripts/check_syntax.sh
python3 tools/labs_json.py --check
./.github/scripts/check_compose.sh   # merges every compose overlay set of each track; needs docker compose
./.github/scripts/check_sql.sh       # parses each track's .sql files in that track's ClickHouse image; needs docker
```

`docs/labs.json` lists the labs whose `lab.yaml` sets `web: true`, for the notes site, which
fetches it from `main`. Keys and categories: [`tools/lab.schema.md`](tools/lab.schema.md).
After changing a `lab.yaml`, run `python3 tools/labs_json.py` and commit the file.

### 📝 License

[MIT](LICENSE). Labs install ClickHouse and other software at run time under their own licences.

---

## 한국어

ClickHouse 위에서 Langfuse를 자체 호스팅(OSS·Enterprise 트랙)하고 Langfuse 평가 루프를 돌린 뒤, 모든 결과를 Langfuse의 ClickHouse 테이블에서 직접 확인하는 실습입니다.

> 이 저장소는 [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols)의 `pre-split-2026-10` 태그 시점에서 히스토리와 함께 분리했습니다. 원래 저장소에 있던 마지막 버전: https://github.com/litkhai/clickhouse-hols/tree/pre-split-2026-10

### 🧪 실습 (`labs/`)

실습마다 Langfuse 메이저 버전별로 트랙이 두 개 있습니다. 운영 중인 버전에 맞는 트랙을
고르세요. **현재 트랙은 v4**이고, Langfuse v3 보안 패치는 2027-01-31까지만 나옵니다.

| 실습 | Langfuse v4 | Langfuse v3 | 내용 |
|-----|---|---|----------------|
| langfuse-ee | [labs/v4/langfuse-ee](labs/v4/langfuse-ee/) | [labs/v3/langfuse-ee](labs/v3/langfuse-ee/) | ClickHouse 기반 Langfuse 자체 호스팅 (OSS + Enterprise) |
| langfuse-eval | [labs/v4/langfuse-eval](labs/v4/langfuse-eval/) | [labs/v3/langfuse-eval](labs/v3/langfuse-eval/) | Langfuse 프롬프트·데이터셋·실험·평가 |

네 실습 모두 [`_base/`](_base/)의 공유 스택 위에서 실행됩니다. 트랙은 스크립트의 첫 번째
인자(`_base/bin/up.sh v4`)이고, 트랙별 버전 고정은 `_base/<track>/versions.env`에 있습니다.

### 📖 읽기 자료 (`reading/`)

실습이 아닌 배경 문서입니다. 실행하는 내용은 없습니다.

| 페이지 | 내용 |
|---|---|
| [Azure API Management AI 게이트웨이 뒤의 Langfuse](reading/azure-apim-gateway.md) | 모든 모델 호출이 APIM을 거칠 때 Langfuse로 트레이스를 넣는 방법, Entra ID, Azure에서 ClickHouse 운영 위치 |

### 🔗 관련 저장소

| 저장소 | 설명 |
|---|---|
| [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols) | ClickHouse 핵심 실습 |
| [litkhai/llmops-in-a-box](https://github.com/litkhai/llmops-in-a-box) | LLMOps 스택 올인원 |

### ✅ 저장소 검사

현재 상태와 재실행이 필요한 항목: [STATUS.md](STATUS.md).

```bash
git config core.hooksPath .githooks
python3 .github/scripts/check_links.py
./.github/scripts/check_syntax.sh
python3 tools/labs_json.py --check
./.github/scripts/check_compose.sh   # 트랙마다 compose 오버레이 조합을 모두 병합; docker compose 필요
./.github/scripts/check_sql.sh       # 트랙마다 그 트랙의 ClickHouse 이미지로 .sql 파일을 파싱; docker 필요
```

`docs/labs.json`에는 `lab.yaml`에 `web: true`가 있는 실습만 담기며, 노트 사이트가 `main`에서
가져갑니다. 키와 분류는 [`tools/lab.schema.md`](tools/lab.schema.md). `lab.yaml`을 바꾼 뒤
`python3 tools/labs_json.py`를 실행하고 그 파일을 커밋하세요.

### 📝 라이선스

[MIT](LICENSE). 실습이 실행 시점에 설치하는 소프트웨어는 각자의 라이선스를 따릅니다.
