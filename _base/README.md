# `_base/` — the shared Langfuse stack

[English](#english) | [한국어](#한국어)

---

## English

One Docker Compose stack that every lab in this repository runs on. The labs keep only their own scripts; the stack, its overlays, the `.env` template and the readiness check live here. A new lab that needs Langfuse points at `_base/` instead of copying a compose file.

### What is in the stack

Six services (`docker-compose.yml`, single node, not highly available):

| Service | Role | Host port |
|---|---|---|
| `langfuse-web` | UI + public API | 3000 |
| `langfuse-worker` | async ingestion and background jobs | 3030 (loopback) |
| `postgres` | OLTP: users, orgs, projects, prompts, audit log | 5432 (loopback) |
| `clickhouse` | OLAP: traces, observations, scores | 8123 / 9000 (loopback) |
| `redis` | queue and cache | 6379 (loopback) |
| `minio` | S3-compatible blob store: raw events, media, exports | 9090 (S3 API), 9091 (console, loopback) |

`postgres`, `clickhouse`, `redis` and `minio` have a healthcheck; `langfuse-web` and `langfuse-worker` do not (`bin/check.sh` probes them over HTTP instead).

### Layout

```
_base/
├── docker-compose.yml             # the six services — always the FIRST -f file
├── docker-compose.ee.yml          # overlay: enterprise license key + admin API key
├── docker-compose.masking.yml     # overlay: masking sidecar + worker callback (needs ee)
├── docker-compose.governance.yml  # overlay: UI customization + org-creators allowlist (needs ee)
├── masking/masking_service.py     # the masking sidecar (mounted by the masking overlay)
├── .env.example                   # copy to _base/.env
├── bin/up.sh · check.sh · down.sh · seed_traces.py
└── lib/env.sh                     # BASE_DIR, load_env, lf_compose for the lab scripts
```

### Overlays and which lab uses which

| Overlay file | Added by | What it changes |
|---|---|---|
| *(none — base only)* | labs 01–04, `langfuse-eval` | OSS stack |
| `docker-compose.ee.yml` | lab 05 (and `EE=1 bin/up.sh`) | injects `LANGFUSE_EE_LICENSE_KEY` into web and worker, plus `ADMIN_API_KEY` |
| `+ docker-compose.masking.yml` | lab 08 | adds the `masking` sidecar, wires the worker to it |
| `+ docker-compose.governance.yml` | lab 10 | UI customization and the org-creators allowlist on web |
| all four | lab 99 / `bin/down.sh` | so the sidecar and every overlay's config are torn down together |

The base file is **always first**. Compose resolves relative paths (the masking volume) and reads `.env` against the directory of the first `-f` file, which is `_base/` — so the same command works from the repository root, from a lab directory, or anywhere else. Lab scripts do not spell the `-f` flags; they source [`lib/env.sh`](lib/env.sh) and call

```bash
lf_compose ee masking -- up -d        # = docker compose -f _base/docker-compose.yml -f _base/docker-compose.ee.yml -f _base/docker-compose.masking.yml up -d
lf_compose -- exec -T postgres psql …  # base only
```

### One `.env`

There is exactly one env file: `_base/.env` (gitignored, mode 600). `bin/up.sh` creates it from `.env.example` on first run; to do it by hand:

```bash
cp _base/.env.example _base/.env
chmod 600 _base/.env
```

It holds the headless-init credentials, the SDK keys (`LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY`), the enterprise license key, and optional keys such as `OPENAI_API_KEY`. Every lab reads it. Never commit it.

### Scripts

| Script | What it does |
|---|---|
| `bin/up.sh` | creates `_base/.env` if missing, starts the stack (`EE=1` adds the EE overlay), waits for `/api/public/health`, prints the logins |
| `bin/check.sh` | readiness check — PASS / FAIL / SKIP per item, exit 1 on any FAIL; `--env-file PATH`, `--help` |
| `bin/down.sh` | stops the stack with all four compose files; `--purge` also deletes the data volumes (`down -v`) |
| `bin/seed_traces.py` | the trace generator both labs use (`labs/langfuse-ee/02-generate-traces.py` and `labs/langfuse-eval/01-seed-traces.py` are thin wrappers) |

`bin/check.sh` needs only `docker` and `curl`, and never prints a key value:

1. **Containers** — the six services are running; `postgres`, `clickhouse`, `redis`, `minio` report `healthy`.
2. **Web / worker** — `GET $NEXTAUTH_URL/api/public/health` returns 200 (and prints the Langfuse version); `GET http://localhost:3030/api/health` returns 200.
3. **Langfuse's ClickHouse migrations finished** — the latest row of `default.schema_migrations` is not dirty, and its version equals the highest migration number shipped in the web image (`/app/packages/shared/clickhouse/migrations/unclustered/`). A server that answers is not enough: the web container migrates ClickHouse on boot, and a half-applied schema looks healthy until a query hits it.
4. **SDK keys** — `GET /api/public/projects` with `LANGFUSE_PUBLIC_KEY:LANGFUSE_SECRET_KEY`: 200 passes, 401 fails, keys unset is a SKIP.
5. **Overlays** — if a `masking` container is running it must be healthy, otherwise SKIP.

A SKIP is not a pass.

### Image versions

The compose file reads four variables, so a run can be pinned without editing it:

| Variable | Default | Image |
|---|---|---|
| `LANGFUSE_VERSION` | `3` | `langfuse/langfuse`, `langfuse/langfuse-worker` |
| `CLICKHOUSE_VERSION` | `latest` | `clickhouse/clickhouse-server` |
| `REDIS_VERSION` | `7` | `redis` |
| `POSTGRES_VERSION` | `17` | `postgres` |

The defaults are floating tags — they are what the stack used before `_base/` existed. Pinning them is tracked separately in [#6](https://github.com/litkhai/langfuse-hols/issues/6). Set a variable in `_base/.env` or in the shell, for example `LANGFUSE_VERSION=3.197.1 CLICKHOUSE_VERSION=25.11.2.24 _base/bin/up.sh`.

### Project name and container names

`docker-compose.yml` sets `name: langfuse-hols`, so container names no longer depend on the directory the stack was started from:

`langfuse-hols-langfuse-web-1` · `langfuse-hols-langfuse-worker-1` · `langfuse-hols-postgres-1` · `langfuse-hols-clickhouse-1` · `langfuse-hols-redis-1` · `langfuse-hols-minio-1` · `langfuse-hols-masking-1`

This is the name the lab SQL instructions use: `docker exec -i langfuse-hols-clickhouse-1 clickhouse-client …`.

**Existing data is not carried over.** Before `_base/`, the stack ran as project `langfuse-ee`, with volumes named `langfuse-ee_langfuse_*`. The new project name creates new, empty volumes (`langfuse-hols_langfuse_*`); the old ones are left alone and not reused. Remove them yourself with `docker volume rm` once you no longer need them.

---

## 한국어

이 저장소의 모든 랩이 함께 쓰는 Docker Compose 스택입니다. 랩에는 각자의 스크립트만 남기고, 스택·오버레이·`.env` 템플릿·준비 상태 점검은 여기에 둡니다. Langfuse가 필요한 새 랩은 compose 파일을 복사하는 대신 `_base/`를 가리킵니다.

### 스택 구성

서비스 6개(`docker-compose.yml`, 단일 노드, 고가용성 아님):

| 서비스 | 역할 | 호스트 포트 |
|---|---|---|
| `langfuse-web` | UI + 공개 API | 3000 |
| `langfuse-worker` | 비동기 인제스트·백그라운드 작업 | 3030 (루프백) |
| `postgres` | OLTP: 사용자·조직·프로젝트·프롬프트·감사 로그 | 5432 (루프백) |
| `clickhouse` | OLAP: traces·observations·scores | 8123 / 9000 (루프백) |
| `redis` | 큐·캐시 | 6379 (루프백) |
| `minio` | S3 호환 blob 스토어: 원본 이벤트·미디어·익스포트 | 9090 (S3 API), 9091 (콘솔, 루프백) |

`postgres`·`clickhouse`·`redis`·`minio`에는 healthcheck가 있고, `langfuse-web`·`langfuse-worker`에는 없습니다(`bin/check.sh`가 HTTP로 대신 확인).

### 구조

```
_base/
├── docker-compose.yml             # 서비스 6개 — 항상 첫 번째 -f 파일
├── docker-compose.ee.yml          # 오버레이: 엔터프라이즈 라이선스 키 + admin API 키
├── docker-compose.masking.yml     # 오버레이: 마스킹 사이드카 + worker 콜백 (ee 필요)
├── docker-compose.governance.yml  # 오버레이: UI 커스터마이징 + 조직 생성 허용목록 (ee 필요)
├── masking/masking_service.py     # 마스킹 사이드카 (마스킹 오버레이가 마운트)
├── .env.example                   # _base/.env 로 복사
├── bin/up.sh · check.sh · down.sh · seed_traces.py
└── lib/env.sh                     # 랩 스크립트용 BASE_DIR, load_env, lf_compose
```

### 오버레이와 사용하는 랩

| 오버레이 파일 | 추가하는 곳 | 바뀌는 것 |
|---|---|---|
| *(없음 — 베이스만)* | 랩 01–04, `langfuse-eval` | OSS 스택 |
| `docker-compose.ee.yml` | 랩 05 (그리고 `EE=1 bin/up.sh`) | web·worker에 `LANGFUSE_EE_LICENSE_KEY` 주입 + `ADMIN_API_KEY` |
| `+ docker-compose.masking.yml` | 랩 08 | `masking` 사이드카 추가, worker를 그쪽으로 연결 |
| `+ docker-compose.governance.yml` | 랩 10 | web에 UI 커스터마이징과 조직 생성 허용목록 |
| 4개 전부 | 랩 99 / `bin/down.sh` | 사이드카와 모든 오버레이 설정을 함께 정리 |

베이스 파일은 **항상 첫 번째**입니다. Compose는 상대 경로(마스킹 볼륨)와 `.env`를 첫 번째 `-f` 파일의 디렉터리, 즉 `_base/` 기준으로 해석합니다. 그래서 같은 명령이 저장소 루트에서든 랩 디렉터리에서든 어디서든 동작합니다. 랩 스크립트는 `-f` 플래그를 직접 쓰지 않고 [`lib/env.sh`](lib/env.sh)를 source 해서 다음과 같이 호출합니다.

```bash
lf_compose ee masking -- up -d        # = docker compose -f _base/docker-compose.yml -f _base/docker-compose.ee.yml -f _base/docker-compose.masking.yml up -d
lf_compose -- exec -T postgres psql …  # 베이스만
```

### `.env`는 하나

env 파일은 `_base/.env` 하나뿐입니다(gitignore, 권한 600). `bin/up.sh`가 처음 실행될 때 `.env.example`에서 만들어 줍니다. 직접 하려면:

```bash
cp _base/.env.example _base/.env
chmod 600 _base/.env
```

headless-init 자격증명, SDK 키(`LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY`), 엔터프라이즈 라이선스 키, 그리고 `OPENAI_API_KEY` 같은 선택 키가 들어 있고, 모든 랩이 이 파일을 읽습니다. 절대 커밋하지 마세요.

### 스크립트

| 스크립트 | 하는 일 |
|---|---|
| `bin/up.sh` | `_base/.env`가 없으면 생성, 스택 기동(`EE=1`이면 EE 오버레이 추가), `/api/public/health` 대기, 로그인 정보 출력 |
| `bin/check.sh` | 준비 상태 점검 — 항목별 PASS / FAIL / SKIP, FAIL이 하나라도 있으면 종료 코드 1; `--env-file PATH`, `--help` |
| `bin/down.sh` | compose 파일 4개를 모두 지정해 스택 종료; `--purge`는 데이터 볼륨까지 삭제(`down -v`) |
| `bin/seed_traces.py` | 두 랩이 함께 쓰는 trace 생성기(`labs/langfuse-ee/02-generate-traces.py`와 `labs/langfuse-eval/01-seed-traces.py`는 얇은 래퍼) |

`bin/check.sh`는 `docker`와 `curl`만 필요하고, 키 값은 절대 출력하지 않습니다.

1. **컨테이너** — 서비스 6개가 실행 중이고, `postgres`·`clickhouse`·`redis`·`minio`가 `healthy`.
2. **Web / worker** — `GET $NEXTAUTH_URL/api/public/health`가 200(Langfuse 버전도 출력); `GET http://localhost:3030/api/health`가 200.
3. **Langfuse의 ClickHouse 마이그레이션 완료** — `default.schema_migrations`의 가장 최근 행이 dirty가 아니고, 그 버전이 web 이미지에 들어 있는 가장 높은 마이그레이션 번호(`/app/packages/shared/clickhouse/migrations/unclustered/`)와 같음. 서버가 응답하는 것만으로는 부족합니다. web 컨테이너가 부팅 시 ClickHouse를 마이그레이션하며, 절반만 적용된 스키마는 쿼리가 닿기 전까지 정상으로 보입니다.
4. **SDK 키** — `LANGFUSE_PUBLIC_KEY:LANGFUSE_SECRET_KEY`로 `GET /api/public/projects`: 200이면 PASS, 401이면 FAIL, 키가 없으면 SKIP.
5. **오버레이** — `masking` 컨테이너가 실행 중이면 healthy여야 하고, 아니면 SKIP.

SKIP은 통과가 아닙니다.

### 이미지 버전

compose 파일이 변수 4개를 읽으므로, 파일을 고치지 않고도 실행을 고정할 수 있습니다.

| 변수 | 기본값 | 이미지 |
|---|---|---|
| `LANGFUSE_VERSION` | `3` | `langfuse/langfuse`, `langfuse/langfuse-worker` |
| `CLICKHOUSE_VERSION` | `latest` | `clickhouse/clickhouse-server` |
| `REDIS_VERSION` | `7` | `redis` |
| `POSTGRES_VERSION` | `17` | `postgres` |

기본값은 유동 태그이며, `_base/` 도입 전에 스택이 쓰던 값 그대로입니다. 고정은 [#6](https://github.com/litkhai/langfuse-hols/issues/6)에서 따로 다룹니다. 변수는 `_base/.env`나 셸에서 지정합니다. 예: `LANGFUSE_VERSION=3.197.1 CLICKHOUSE_VERSION=25.11.2.24 _base/bin/up.sh`.

### 프로젝트 이름과 컨테이너 이름

`docker-compose.yml`이 `name: langfuse-hols`를 지정하므로, 컨테이너 이름은 스택을 어느 디렉터리에서 띄웠는지에 좌우되지 않습니다.

`langfuse-hols-langfuse-web-1` · `langfuse-hols-langfuse-worker-1` · `langfuse-hols-postgres-1` · `langfuse-hols-clickhouse-1` · `langfuse-hols-redis-1` · `langfuse-hols-minio-1` · `langfuse-hols-masking-1`

랩 SQL 안내가 쓰는 이름이 이것입니다: `docker exec -i langfuse-hols-clickhouse-1 clickhouse-client …`.

**기존 데이터는 이어지지 않습니다.** `_base/` 이전에는 스택이 프로젝트 `langfuse-ee`로 실행되어 볼륨 이름이 `langfuse-ee_langfuse_*`였습니다. 새 프로젝트 이름은 비어 있는 새 볼륨(`langfuse-hols_langfuse_*`)을 만들고, 옛 볼륨은 건드리지도 재사용하지도 않습니다. 더 필요 없어지면 `docker volume rm`으로 직접 지우세요.
