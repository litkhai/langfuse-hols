# `_base/` — the shared Langfuse stack

[English](#english) | [한국어](#한국어)

---

## English

One Docker Compose stack that every lab in this repository runs on. The labs keep only their own scripts; the stack, its overlays, the `.env` template, the Python requirements and the readiness check live here. A new lab that needs Langfuse points at `_base/` instead of copying a compose file.

### Two tracks: v3 and v4

Every lab exists once per Langfuse major version, in `labs/v3/` and `labs/v4/` ([#33](https://github.com/litkhai/langfuse-hols/issues/33)). Both tracks use the same compose files. What differs lives in `_base/<track>/`:

| | v3 (`_base/v3/`) | v4 (`_base/v4/`) |
|---|---|---|
| Image pins (`versions.env`) | Langfuse 3.225.11, ClickHouse 26.8.18.2 | Langfuse 4.52.0, ClickHouse 26.8.18.2 |
| Python deps (`requirements.txt`) | `langfuse==3.15.0` | `langfuse==4.17.0`, `anthropic`, `opentelemetry-instrumentation-anthropic` |
| Trace generator (`seed_traces.py`) | SDK v3, optional real OpenAI calls | SDK v4, optional real Anthropic calls |
| Where ClickHouse puts traces | `traces`, `observations`, `scores` | `events_full` / `events_core` (one wide row per observation, a trace is its root observation `is_app_root`) and `scores`; the v3 tables stay empty |
| Compose project, containers | `langfuse-hols-v3`, `langfuse-hols-v3-<service>-1` | `langfuse-hols-v4`, `langfuse-hols-v4-<service>-1` |

**v4 is the current track.** v3 keeps the labs as they were before the v4 port, for Langfuse v3 deployments, until v3 support ends on 2027-01-31 ([#35](https://github.com/litkhai/langfuse-hols/issues/35)).

The track is always an explicit argument: `_base/bin/up.sh v4`, `_base/bin/check.sh v3`, `. _base/lib/env.sh v4`. There is no default. Each track is its own compose project with its own volumes, so switching tracks never runs one major's migrations on the other's data. Both tracks publish the same host ports, so **one track runs at a time**; `bin/up.sh` refuses to start while the other track is up. Both SDK majors need **Python 3.10+**, in separate virtual environments.

### What is in the stack

Six services (`docker-compose.yml`, single node, not highly available):

| Service | Role | Host port |
|---|---|---|
| `langfuse-web` | UI + public API | 3000 |
| `langfuse-worker` | async ingestion and background jobs | 3030 (loopback) |
| `postgres` | OLTP: users, orgs, projects, prompts, audit log | 5432 (loopback) |
| `clickhouse` | OLAP: traces and observations (tables per track, above), scores | 8123 / 9000 (loopback) |
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
├── .env.example                   # copy to _base/.env — one file for both tracks
├── v3/ · v4/                      # per track: versions.env · requirements.txt · seed_traces.py
├── bin/up.sh · check.sh · down.sh # first argument: the track
└── lib/env.sh                     # BASE_DIR, TRACK, LF_PROJECT, load_env, lf_compose for the lab scripts
```

### Overlays and which lab uses which

The same in both tracks:

| Overlay file | Added by | What it changes |
|---|---|---|
| *(none — base only)* | labs 01–04, `langfuse-eval` | OSS stack |
| `docker-compose.ee.yml` | lab 05 (and `EE=1 bin/up.sh <track>`) | injects `LANGFUSE_EE_LICENSE_KEY` into web and worker, plus `ADMIN_API_KEY` |
| `+ docker-compose.masking.yml` | lab 08 | adds the `masking` sidecar, wires the worker to it |
| `+ docker-compose.governance.yml` | lab 10 | UI customization and the org-creators allowlist on web |
| all four | lab 99 / `bin/down.sh <track>` | so the sidecar and every overlay's config are torn down together |

Lab scripts do not spell the compose flags. They source [`lib/env.sh`](lib/env.sh) with their track and call `lf_compose`:

```bash
. _base/lib/env.sh v4
lf_compose ee masking -- up -d
#   = docker compose --env-file _base/v4/versions.env --env-file _base/.env \
#       -f _base/docker-compose.yml -f _base/docker-compose.ee.yml -f _base/docker-compose.masking.yml up -d
lf_compose -- exec -T postgres psql …  # base only
```

The track's `versions.env` comes first, so a value in `_base/.env`, or in the shell, overrides a pin. `_base/.env` is passed only if it exists. The base compose file is **always first**: compose resolves relative paths (the masking volume) against the directory of the first `-f` file, which is `_base/`, so the same command works from any directory. Run without a track, the compose file refuses to resolve (`LF_TRACK`, `LANGFUSE_VERSION` and `CLICKHOUSE_VERSION` are required), so a bare `docker compose -f _base/docker-compose.yml …` needs `--env-file _base/<track>/versions.env`.

CI runs once per track. It merges each overlay set above with `docker compose config` and asserts what the merge contains: the right variables on the right service, the masking mount, the six services, the project name and the image tags of that track's `versions.env`. It also checks that the base file does not resolve without a track. Run [`check_compose.sh`](../.github/scripts/check_compose.sh) to do the same locally.

### One `.env`

There is exactly one env file for both tracks: `_base/.env` (gitignored, mode 600). `bin/up.sh` creates it from `.env.example` on first run; to do it by hand:

```bash
cp _base/.env.example _base/.env
chmod 600 _base/.env
```

It holds:

- the headless-init credentials
- the SDK keys (`LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY`)
- the enterprise license key
- the optional real-call keys. `OPENAI_API_KEY` switches the v3 track from the offline simulation to real OpenAI calls. `ANTHROPIC_API_KEY` switches the v4 track to real `claude-haiku-4-5` calls. Each track reads only its own key.

Every lab reads this file. Never commit it.

### Scripts

| Script | What it does |
|---|---|
| `bin/up.sh <track>` | creates `_base/.env` if missing, refuses if the other track is running, starts the stack (`EE=1` adds the EE overlay), waits for `/api/public/health`, prints the logins |
| `bin/check.sh <track>` | readiness check — PASS / FAIL / SKIP per item, exit 1 on any FAIL; `--env-file PATH`, `--help` |
| `bin/down.sh <track>` | stops that track's stack with all four compose files; `--purge` also deletes its data volumes (`down -v`) |
| `<track>/seed_traces.py` | the trace generator both labs of the track use (`labs/<track>/langfuse-ee/02-generate-traces.py` and `labs/<track>/langfuse-eval/01-seed-traces.py` are thin wrappers); needs `pip install -r _base/<track>/requirements.txt` |

`bin/check.sh` needs only `docker` and `curl`, and never prints a key value:

1. **Containers** — the six services of the track's project are running; `postgres`, `clickhouse`, `redis`, `minio` report `healthy`.
2. **Web / worker** — `GET $NEXTAUTH_URL/api/public/health` returns 200, and the version it reports equals the `LANGFUSE_VERSION` in effect (the track's `versions.env`, overridden by the env file, then by the shell); `GET http://localhost:3030/api/health` returns 200.
3. **Langfuse's ClickHouse migrations finished** — the latest row of `default.schema_migrations` is not dirty, and its version equals the highest migration number shipped in the web image (`/app/packages/shared/clickhouse/migrations/unclustered/`, the same path in both majors). A server that answers is not enough: the web container migrates ClickHouse on boot, and a half-applied schema looks healthy until a query hits it.
4. **SDK keys** — `GET /api/public/projects` with `LANGFUSE_PUBLIC_KEY:LANGFUSE_SECRET_KEY`: 200 passes, 401 fails, keys unset is a SKIP.
5. **Overlays** — if a `masking` container is running it must be healthy, otherwise SKIP.

A SKIP is not a pass.

### Image versions

Per track, in `_base/<track>/versions.env`: `LANGFUSE_VERSION` (`langfuse/langfuse`, `langfuse/langfuse-worker`) and `CLICKHOUSE_VERSION` (`clickhouse/clickhouse-server`) — values in the table above. Shared by both tracks, as defaults in the compose file:

| Variable | Default | Image |
|---|---|---|
| `REDIS_VERSION` | `7.2.16` | `redis` |
| `POSTGRES_VERSION` | `17.11` | `postgres` |

Two images are not variables. MinIO (`cgr.dev/chainguard/minio`) publishes no version tag, so it is pinned by the digest of `latest` (`@sha256:4cf4831a…`, resolved 2026-10-06). The masking sidecar runs `python:3.12.15-slim`.

Langfuse v4 needs ClickHouse 25.12 or newer and recommends 26.4 ([ClickHouse deployment guide](https://langfuse.com/self-hosting/deployment/infrastructure/clickhouse)). 26.8.18.2 is the newest patch of the current long-term-support line (2026-10-06). Langfuse 3.225.11 applied all 37 of its ClickHouse migrations on it in a throwaway run (2026-10-06), so both tracks share it. Why each pin is what it is: [STATUS.md](../STATUS.md#pins).

Override a pin in the shell or in `_base/.env`, for example `LANGFUSE_VERSION=4.52.0 _base/bin/up.sh v4`. A value in `_base/.env` applies to both tracks.

### Python dependencies

One virtual environment per track, from the repository root (both need Python 3.10 or newer):

```bash
python3.12 -m venv .venv-v4 && source .venv-v4/bin/activate
pip install -r _base/v4/requirements.txt     # langfuse 4.17.0; anthropic + opentelemetry-instrumentation-anthropic, imported only when ANTHROPIC_API_KEY is set

python3.12 -m venv .venv-v3 && source .venv-v3/bin/activate
pip install -r _base/v3/requirements.txt     # langfuse 3.15.0; the OpenAI path (OPENAI_API_KEY) also needs `pip install openai`
```

`.venv-*/` is gitignored.

### Project name and container names

`docker-compose.yml` sets `name: langfuse-hols-${LF_TRACK}`, so container names depend on the track and not on the directory the stack was started from:

`langfuse-hols-<track>-langfuse-web-1` · `-langfuse-worker-1` · `-postgres-1` · `-clickhouse-1` · `-redis-1` · `-minio-1` · `-masking-1`

This is the name the lab SQL instructions use, e.g. `docker exec -i langfuse-hols-v4-clickhouse-1 clickhouse-client …`. Scripts that source `lib/env.sh` use `${LF_PROJECT}-clickhouse-1`.

**Existing data is not carried over.**

- **Before #33** the stack ran as project `langfuse-hols`, with volumes `langfuse-hols_langfuse_*`.
- **Before `_base/`** it ran as `langfuse-ee`, with volumes `langfuse-ee_langfuse_*`.

The track projects create new, empty volumes (`langfuse-hols-v3_*`, `langfuse-hols-v4_*`) and never reuse the old ones. Remove the old volumes with `docker volume rm` once you no longer need them.

`bin/up.sh` only looks for the other track's project, not for these old ones. If a `langfuse-hols` stack from before #33 is still running, stop it first:

```bash
docker stop $(docker ps -q --filter label=com.docker.compose.project=langfuse-hols)
```

---

## 한국어

이 저장소의 모든 랩이 함께 쓰는 Docker Compose 스택입니다. 랩에는 각자의 스크립트만 남기고, 스택·오버레이·`.env` 템플릿·Python 요구사항·준비 상태 점검은 여기에 둡니다. Langfuse가 필요한 새 랩은 compose 파일을 복사하는 대신 `_base/`를 가리킵니다.

### 두 트랙: v3와 v4

모든 랩은 Langfuse 메이저 버전마다 하나씩, `labs/v3/`와 `labs/v4/`에 있습니다([#33](https://github.com/litkhai/langfuse-hols/issues/33)). 두 트랙은 같은 compose 파일을 쓰고, 다른 부분만 `_base/<track>/`에 둡니다.

| | v3 (`_base/v3/`) | v4 (`_base/v4/`) |
|---|---|---|
| 이미지 버전 고정 (`versions.env`) | Langfuse 3.225.11, ClickHouse 26.8.18.2 | Langfuse 4.52.0, ClickHouse 26.8.18.2 |
| Python 의존성 (`requirements.txt`) | `langfuse==3.15.0` | `langfuse==4.17.0`, `anthropic`, `opentelemetry-instrumentation-anthropic` |
| trace 생성기 (`seed_traces.py`) | SDK v3, 선택적으로 실제 OpenAI 호출 | SDK v4, 선택적으로 실제 Anthropic 호출 |
| ClickHouse의 trace 저장 위치 | `traces`, `observations`, `scores` | `events_full` / `events_core`(observation마다 넓은 행 하나, trace는 루트 observation `is_app_root`)와 `scores`. v3 테이블은 비어 있음 |
| compose 프로젝트, 컨테이너 | `langfuse-hols-v3`, `langfuse-hols-v3-<service>-1` | `langfuse-hols-v4`, `langfuse-hols-v4-<service>-1` |

**현재 트랙은 v4입니다.** v3는 v4 포팅 이전의 랩을 Langfuse v3 운영 환경을 위해 남겨 둔 것이며, v3 지원이 끝나는 2027-01-31까지 유지합니다([#35](https://github.com/litkhai/langfuse-hols/issues/35)).

트랙은 항상 명시적인 인자입니다. `_base/bin/up.sh v4`, `_base/bin/check.sh v3`, `. _base/lib/env.sh v4`처럼 쓰고, 기본값은 없습니다. 트랙마다 compose 프로젝트와 볼륨이 따로라서, 트랙을 바꿔도 한 메이저의 마이그레이션이 다른 메이저의 데이터에 적용되지 않습니다. 두 트랙은 같은 호스트 포트를 쓰므로 **한 번에 한 트랙만** 실행됩니다. 다른 트랙이 떠 있으면 `bin/up.sh`가 시작을 거부합니다. 두 SDK 메이저 모두 **Python 3.10+**가 필요하며, 가상환경은 따로 만듭니다.

### 스택 구성

서비스 6개(`docker-compose.yml`, 단일 노드, 고가용성 아님):

| 서비스 | 역할 | 호스트 포트 |
|---|---|---|
| `langfuse-web` | UI + 공개 API | 3000 |
| `langfuse-worker` | 비동기 인제스트·백그라운드 작업 | 3030 (루프백) |
| `postgres` | OLTP: 사용자·조직·프로젝트·프롬프트·감사 로그 | 5432 (루프백) |
| `clickhouse` | OLAP: trace와 observation(트랙별 테이블은 위 표), scores | 8123 / 9000 (루프백) |
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
├── .env.example                   # _base/.env 로 복사 — 두 트랙이 같은 파일을 씀
├── v3/ · v4/                      # 트랙별: versions.env · requirements.txt · seed_traces.py
├── bin/up.sh · check.sh · down.sh # 첫 번째 인자: 트랙
└── lib/env.sh                     # 랩 스크립트용 BASE_DIR, TRACK, LF_PROJECT, load_env, lf_compose
```

### 오버레이와 사용하는 랩

두 트랙에서 같습니다.

| 오버레이 파일 | 추가하는 곳 | 바뀌는 것 |
|---|---|---|
| *(없음 — 베이스만)* | 랩 01–04, `langfuse-eval` | OSS 스택 |
| `docker-compose.ee.yml` | 랩 05 (그리고 `EE=1 bin/up.sh <track>`) | web·worker에 `LANGFUSE_EE_LICENSE_KEY` 주입 + `ADMIN_API_KEY` |
| `+ docker-compose.masking.yml` | 랩 08 | `masking` 사이드카 추가, worker를 그쪽으로 연결 |
| `+ docker-compose.governance.yml` | 랩 10 | web에 UI 커스터마이징과 조직 생성 허용목록 |
| 4개 전부 | 랩 99 / `bin/down.sh <track>` | 사이드카와 모든 오버레이 설정을 함께 정리 |

랩 스크립트는 compose 플래그를 직접 쓰지 않습니다. 자기 트랙을 넘겨 [`lib/env.sh`](lib/env.sh)를 source 하고 `lf_compose`를 호출합니다.

```bash
. _base/lib/env.sh v4
lf_compose ee masking -- up -d
#   = docker compose --env-file _base/v4/versions.env --env-file _base/.env \
#       -f _base/docker-compose.yml -f _base/docker-compose.ee.yml -f _base/docker-compose.masking.yml up -d
lf_compose -- exec -T postgres psql …  # 베이스만
```

트랙의 `versions.env`가 먼저 오므로, `_base/.env`나 셸에 있는 값이 고정 버전을 덮어씁니다. `_base/.env`는 파일이 있을 때만 넘깁니다. 베이스 compose 파일은 **항상 첫 번째**입니다. Compose는 상대 경로(마스킹 볼륨)를 첫 번째 `-f` 파일의 디렉터리, 즉 `_base/` 기준으로 해석하므로 같은 명령이 어느 디렉터리에서든 동작합니다. 트랙 없이 실행하면 compose 파일이 해석을 거부합니다(`LF_TRACK`, `LANGFUSE_VERSION`, `CLICKHOUSE_VERSION` 필수). 그래서 `docker compose -f _base/docker-compose.yml …`을 직접 쓰려면 `--env-file _base/<track>/versions.env`가 필요합니다.

CI는 트랙마다 한 번씩 돕니다. 위의 오버레이 조합마다 `docker compose config`로 병합하고, 병합 결과가 담아야 할 것을 검사합니다. 올바른 서비스의 올바른 변수, 마스킹 마운트, 서비스 6개, 프로젝트 이름, 그 트랙 `versions.env`의 이미지 태그가 대상입니다. 트랙 없이는 베이스 파일이 해석되지 않는지도 확인합니다. 로컬에서는 [`check_compose.sh`](../.github/scripts/check_compose.sh)로 같은 검사를 할 수 있습니다.

### `.env`는 하나

env 파일은 두 트랙 공통으로 `_base/.env` 하나뿐입니다(gitignore, 권한 600). `bin/up.sh`가 처음 실행될 때 `.env.example`에서 만들어 줍니다. 직접 하려면:

```bash
cp _base/.env.example _base/.env
chmod 600 _base/.env
```

이 파일에는 다음이 들어 있습니다.

- headless-init 자격증명
- SDK 키(`LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY`)
- 엔터프라이즈 라이선스 키
- 실제 호출용 선택 키. `OPENAI_API_KEY`가 있으면 v3 트랙이 오프라인 시뮬레이션 대신 실제 OpenAI를 호출하고, `ANTHROPIC_API_KEY`가 있으면 v4 트랙이 실제 `claude-haiku-4-5`를 호출합니다. 각 트랙은 자기 키만 읽습니다.

모든 랩이 이 파일을 읽습니다. 절대 커밋하지 마세요.

### 스크립트

| 스크립트 | 하는 일 |
|---|---|
| `bin/up.sh <track>` | `_base/.env`가 없으면 생성, 다른 트랙이 실행 중이면 거부, 스택 기동(`EE=1`이면 EE 오버레이 추가), `/api/public/health` 대기, 로그인 정보 출력 |
| `bin/check.sh <track>` | 준비 상태 점검 — 항목별 PASS / FAIL / SKIP, FAIL이 하나라도 있으면 종료 코드 1; `--env-file PATH`, `--help` |
| `bin/down.sh <track>` | compose 파일 4개를 모두 지정해 그 트랙의 스택 종료; `--purge`는 그 트랙의 데이터 볼륨까지 삭제(`down -v`) |
| `<track>/seed_traces.py` | 그 트랙의 두 랩이 함께 쓰는 trace 생성기(`labs/<track>/langfuse-ee/02-generate-traces.py`와 `labs/<track>/langfuse-eval/01-seed-traces.py`는 얇은 래퍼); `pip install -r _base/<track>/requirements.txt` 필요 |

`bin/check.sh`는 `docker`와 `curl`만 필요하고, 키 값은 절대 출력하지 않습니다.

1. **컨테이너** — 그 트랙 프로젝트의 서비스 6개가 실행 중이고, `postgres`·`clickhouse`·`redis`·`minio`가 `healthy`.
2. **Web / worker** — `GET $NEXTAUTH_URL/api/public/health`가 200이고, 보고된 버전이 적용 중인 `LANGFUSE_VERSION`과 같음(트랙의 `versions.env`를 env 파일이, 그다음 셸이 덮어씀); `GET http://localhost:3030/api/health`가 200.
3. **Langfuse의 ClickHouse 마이그레이션 완료** — `default.schema_migrations`의 가장 최근 행이 dirty가 아니고, 그 버전이 web 이미지에 들어 있는 가장 높은 마이그레이션 번호(`/app/packages/shared/clickhouse/migrations/unclustered/`, 두 메이저에서 같은 경로)와 같음. 서버가 응답하는 것만으로는 부족합니다. web 컨테이너가 부팅 시 ClickHouse를 마이그레이션하며, 절반만 적용된 스키마는 쿼리가 닿기 전까지 정상으로 보입니다.
4. **SDK 키** — `LANGFUSE_PUBLIC_KEY:LANGFUSE_SECRET_KEY`로 `GET /api/public/projects`: 200이면 PASS, 401이면 FAIL, 키가 없으면 SKIP.
5. **오버레이** — `masking` 컨테이너가 실행 중이면 healthy여야 하고, 아니면 SKIP.

SKIP은 통과가 아닙니다.

### 이미지 버전

트랙별 버전은 `_base/<track>/versions.env`에 있습니다. `LANGFUSE_VERSION`은 `langfuse/langfuse`·`langfuse/langfuse-worker`의 버전이고, `CLICKHOUSE_VERSION`은 `clickhouse/clickhouse-server`의 버전입니다. 값은 위 표와 같습니다. 두 트랙이 공유하는 버전은 compose 파일의 기본값입니다.

| 변수 | 기본값 | 이미지 |
|---|---|---|
| `REDIS_VERSION` | `7.2.16` | `redis` |
| `POSTGRES_VERSION` | `17.11` | `postgres` |

변수가 아닌 이미지가 둘 있습니다. MinIO(`cgr.dev/chainguard/minio`)는 버전 태그를 배포하지 않아 `latest`의 다이제스트로 고정했습니다(`@sha256:4cf4831a…`, 2026-10-06에 확인). 마스킹 사이드카는 `python:3.12.15-slim`을 씁니다.

Langfuse v4는 ClickHouse 25.12 이상을 요구하고 26.4를 권장합니다([ClickHouse 배포 가이드](https://langfuse.com/self-hosting/deployment/infrastructure/clickhouse)). 26.8.18.2는 현재 장기 지원(LTS) 계열의 최신 패치입니다(2026-10-06). 임시 스택으로 돌려 보니 Langfuse 3.225.11이 이 버전에서 ClickHouse 마이그레이션 37개를 모두 적용했습니다(2026-10-06). 그래서 두 트랙이 같은 버전을 씁니다. 각 버전을 고른 이유는 [STATUS.md](../STATUS.md#pins)에 있습니다.

고정 버전은 셸이나 `_base/.env`에서 덮어쓸 수 있습니다. 예: `LANGFUSE_VERSION=4.52.0 _base/bin/up.sh v4`. `_base/.env`에 둔 값은 두 트랙에 모두 적용됩니다.

### Python 의존성

저장소 루트에서 트랙마다 가상환경을 하나씩 만드세요(둘 다 Python 3.10 이상).

```bash
python3.12 -m venv .venv-v4 && source .venv-v4/bin/activate
pip install -r _base/v4/requirements.txt     # langfuse 4.17.0; anthropic + opentelemetry-instrumentation-anthropic은 ANTHROPIC_API_KEY가 있을 때만 import

python3.12 -m venv .venv-v3 && source .venv-v3/bin/activate
pip install -r _base/v3/requirements.txt     # langfuse 3.15.0; OpenAI 경로(OPENAI_API_KEY)는 `pip install openai`도 필요
```

`.venv-*/`는 gitignore에 있습니다.

### 프로젝트 이름과 컨테이너 이름

`docker-compose.yml`이 `name: langfuse-hols-${LF_TRACK}`를 지정하므로, 컨테이너 이름은 트랙에 따라 정해지고 스택을 어느 디렉터리에서 띄웠는지에 좌우되지 않습니다.

`langfuse-hols-<track>-langfuse-web-1` · `-langfuse-worker-1` · `-postgres-1` · `-clickhouse-1` · `-redis-1` · `-minio-1` · `-masking-1`

랩 SQL 안내가 쓰는 이름이 이것입니다. 예: `docker exec -i langfuse-hols-v4-clickhouse-1 clickhouse-client …`. `lib/env.sh`를 source 하는 스크립트는 `${LF_PROJECT}-clickhouse-1`을 씁니다.

**기존 데이터는 이어지지 않습니다.**

- **#33 이전**에는 스택이 프로젝트 `langfuse-hols`(볼륨 `langfuse-hols_langfuse_*`)로 실행됐습니다.
- **`_base/` 이전**에는 `langfuse-ee`(볼륨 `langfuse-ee_langfuse_*`)였습니다.

트랙 프로젝트는 비어 있는 새 볼륨(`langfuse-hols-v3_*`, `langfuse-hols-v4_*`)을 만들고 옛 볼륨을 재사용하지 않습니다. 더 필요 없어지면 `docker volume rm`으로 직접 지우세요.

`bin/up.sh`는 다른 트랙의 프로젝트만 확인하고, 이 옛 프로젝트는 확인하지 않습니다. #33 이전의 `langfuse-hols` 스택이 아직 떠 있으면 먼저 멈추세요.

```bash
docker stop $(docker ps -q --filter label=com.docker.compose.project=langfuse-hols)
```
