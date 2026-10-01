# Langfuse on ClickHouse Hands-on Labs

[English](#english) | [한국어](#한국어)

## English

Self-hosting Langfuse on ClickHouse (OSS and Enterprise tracks) and Langfuse's evaluation loop, with every result read back from Langfuse's ClickHouse tables.

> This repository was split out of [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols) on the `pre-split-2026-10` tag, with history. The last version of these labs in the original repository: https://github.com/litkhai/clickhouse-hols/tree/pre-split-2026-10

### 🧪 Labs (`labs/`)

| Lab | What it covers |
|-----|----------------|
| [labs/langfuse-ee](labs/langfuse-ee/) | Self-hosting Langfuse on ClickHouse (OSS + Enterprise) |
| [labs/langfuse-eval](labs/langfuse-eval/) | Langfuse prompts, datasets, experiments and evals |

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
```

### 📝 License

[MIT](LICENSE). Labs install ClickHouse and other software at run time under their own licences.

---

## 한국어

ClickHouse 위에서 Langfuse를 자체 호스팅(OSS·Enterprise 트랙)하고 Langfuse 평가 루프를 돌린 뒤, 모든 결과를 Langfuse의 ClickHouse 테이블에서 직접 확인하는 실습입니다.

> 이 저장소는 [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols)의 `pre-split-2026-10` 태그 시점에서 히스토리와 함께 분리했습니다. 원래 저장소에 있던 마지막 버전: https://github.com/litkhai/clickhouse-hols/tree/pre-split-2026-10

### 🧪 실습 (`labs/`)

| 실습 | 내용 |
|-----|----------------|
| [labs/langfuse-ee](labs/langfuse-ee/) | ClickHouse 기반 Langfuse 자체 호스팅 (OSS + Enterprise) |
| [labs/langfuse-eval](labs/langfuse-eval/) | Langfuse 프롬프트·데이터셋·실험·평가 |

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
```

### 📝 라이선스

[MIT](LICENSE). 실습이 실행 시점에 설치하는 소프트웨어는 각자의 라이선스를 따릅니다.
