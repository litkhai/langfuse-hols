# Langfuse on Helm: chart v1 → v2, then Langfuse v3 → v4

[English](#english) | [한국어](#한국어)

---

## English

> **Related notes** (Korean): [Langfuse 셀프호스팅 업그레이드: Helm chart v1 → v2, Langfuse v3 → v4](https://clickhouse.litkhai.dev/articles/langfuse/langfuse-helm-v3-to-v4-upgrade/)

A Helm deployment of Langfuse v3 that runs the chart's bundled ClickHouse cannot go to Langfuse v4
directly. Chart v1 ships ClickHouse 25.2 and cannot take it to the 25.12 that v4 needs, but chart v2 can.
So there are two upgrades, in this order:

1. **Chart v1 → v2** (infrastructure). Every Bitnami store is replaced. A plain `helm upgrade` is
   blocked, so a sibling v2 release is installed, the data is copied while v1 serves, and traffic moves.
2. **Langfuse v3 → v4** (application) on chart v2, through the migration write modes
   `legacy` → `dual` → backfill → `events_only`.

This lab runs both end to end on a local kind cluster. It starts from an old v3 (3.172.1), keeps
traffic running during the chart copy, rehearses a rollback before the cutover, and checks every
step against the stores. It follows the two official guides,
[upgrade-v1-to-v2](https://github.com/langfuse/langfuse-k8s/tree/main/examples/upgrade-v1-to-v2) and
[upgrade v3 to v4](https://langfuse.com/self-hosting/upgrade/upgrade-guides/upgrade-v3-to-v4). Where
they did not hold, the step says so (see [What the guides do not tell you](#what-the-guides-do-not-tell-you)).

Not a `_base/` lab: it runs on Kubernetes, not Docker Compose, so it sits outside the `v3/`/`v4/`
track folders.

### Path

```
chart 1.5.41 + Langfuse 3.172.1      (Bitnami Postgres 17.3, ClickHouse 25.2, Valkey 8.0, MinIO)
  │ 04  helm upgrade, image 3.225.15 (latest v3); background migrations finished
chart 1.5.41 + Langfuse 3.225.15
  │ 05  sibling release langfuse-v2: Postgres logical replication, ClickHouse remote() copy,
  │     mc mirror; freeze, final deltas, Service retargeted (traffic running throughout)
chart 2.2.1  + Langfuse 3.225.15     (postgres 18, ClickHouse 26.8.36.3 via the operator, Valkey 8.0, SeaweedFS)
  │ 07  image 4.72.0, write mode legacy  (schema migrations run, v3 behaviour)
  │ 08  dual                              (old tables and events_full both written)
  │ 09  rollback rehearsal: v3 image alone fails; rewind to 37, v3 runs; forward to v4 dual again
  │ 10  historic backfill
  │ 11  events_only                       (the cutover)
  │ 12  optional cleanup: drop the scratch table, TRUNCATE traces/observations
chart 2.2.1  + Langfuse 4.72.0, events_only
```

### Pins (read 2026-11-03)

| What | Version | Source |
|---|---|---|
| Chart v1 / v2 | 1.5.41 (appVersion 3.224.1) / 2.2.1 (appVersion 4.70.1) | `oci://ghcr.io/langfuse/langfuse-k8s/charts/langfuse` |
| Langfuse | 3.172.1 → 3.225.15 (latest v3, 2026-10-27) → 4.72.0 (latest v4, 2026-10-29) | `gh release list langfuse/langfuse` |
| Upgrade scripts | `langfuse-k8s` @ `15f31e8` (main, 2026-11-02) | cloned by step 05 |
| cert-manager / ClickHouse operator | v1.20.2 / 0.0.8 | the upstream script's defaults |
| Python SDK | 3.15.0 (old producer) / 4.17.0 (v4-compatible) | this repository's track pins |
| kind / Kubernetes / Helm | 0.33.0 / 1.37.0 / 4.3.1 | local |

### Prerequisites

Docker with about 8 GB free for the kind node, `kind`, `kubectl`, `helm` ≥ 3.17, `jq`, Python 3.10+
(`PYTHON=python3.12` by default), `openssl`. Optional: Playwright for `shots.mjs` (UI screenshots).

### Steps

| Step | What it does | Gate |
|---|---|---|
| `01-cluster.sh` | kind cluster, the shared app Secret (salt, encryption key, NextAuth secret), SDK virtualenvs | — |
| `02-install-v1.sh` | chart 1.5.41, every store bundled, Langfuse 3.172.1 | stores up, `wal_level=logical` |
| `03-seed-v3.sh [phase]` | the client Service `langfuse-app`; prompts, a dataset and an experiment run; 40 SDK v3 traces and 10 legacy-API traces; `inventory.sh v1` | — |
| `04-latest-v3.sh` | image 3.225.15 on chart v1, worker restarted after web | non-gated unfinished background migrations = 0, failed = 0; ClickHouse schema 37 |
| `05-migrate-chart.sh` | the upstream `migrate-v1-to-v2.sh --yes --force` with one trace per second from `traffic.sh`; retargets `langfuse-app` when the script asks | — |
| `06-verify-v2.sh` | counts v1 before vs v2 after, the accepted traffic, old keys and password | all PASS |
| `07-v4-legacy.sh` | the gate again, `pg_dump`, image 4.72.0 with `legacy` | tables dropped/created as the guide says; old tables written, events_full empty; v3 APIs 200 |
| `08-v4-dual.sh` | `dual`; SDK v3, SDK v4 and legacy-API traces; waits for propagation | all producers in events_full |
| `09-rollback-rehearsal.sh` | v3 image alone; rewind to 37; v3; forward to v4 `dual` | v3 web refuses without the rewind, runs after it |
| `10-backfill.sh` | backfill on, waits for steps 1–4 | no trace or observation of the old tables missing from events_full |
| `11-cutover.sh` | `events_only` | old tables no longer written; deprecated endpoints; the replacements |
| `12-cleanup-storage.sh` | scratch table dropped, old tables truncated | v3-era trace still readable through v2 observations |
| `99-cleanup.sh` | deletes the cluster and `.work/` | — |

Run them in order from this directory. Run `03-seed-v3.sh v3-latest` once more after 04 if you want
data written by the latest v3 too, as the verification run did. Mode files for 07–11 are in
`modes/`, and `v4-values.yaml` mounts them as a ConfigMap. Changing write mode is
`kubectl apply` plus a restart. The values file does not change.

### Results (2026-11-03)

Verified on Langfuse 3.172.1 → 3.225.15 → 4.72.0 / SDK 3.15.0 and 4.17.0 / ClickHouse 25.2.1.3085 → 26.8.36.3,
chart 1.5.41 → 2.2.1, kind 0.33.0 (Kubernetes 1.37.0, one node), Helm 4.3.1, Docker 29.9.2. Every gate
passed. Full log: [lab-output.md](lab-output.md).

| Step | Result |
|---|---|
| 04 latest v3 | non-gated unfinished background migrations 0, failed 0; ClickHouse schema 37 |
| 05–06 chart v2 | Postgres counts and the API-key hash identical; ClickHouse traces/observations/scores/dataset_run_items_rmt 104/264/80/4 on both; all 339 accepted traffic traces on v2; v1 keys and password work |
| 05 downtime | resumed run 215 s end to end (online passes, 60 s drain wait, final deltas, scale-up, retarget); first 2xx 13 s after the retarget. The 682 s failure window of this run includes the first run's stop (finding 5) |
| 07 legacy | schema 37 → 53; Postgres `traces observations scores dataset_run_items` dropped; ClickHouse `event_log project_environments dataset_run_items` dropped, `events_full events_core observations_batch_staging` created; writes only in the old tables; v3 APIs 200, v2 observations 404 |
| 08 dual | SDK 4.17.0 in events_full at once; SDK 3.15.0 and legacy API after **557 s** |
| 09 rollback | v3 image alone: web not ready, `no migration found for version 53`; rewind 53 → 37 (clustered command); v3 runs and reads a trace written on v4; forward to v4 again: events tables recreated empty |
| 10 backfill | steps 1–4 in **225 s** for 527 traces / 409 observations; nothing missing from events_full; 527 virtual roots |
| 11 events_only | old tables get no writes; 12 deprecated endpoints 404; legacy ingestion 207 + per-event 400; SDK 3.15.0 still accepted; v2 observations, v3 scores, v2 metrics, experiments 200 |
| 12 cleanup | scratch table dropped, old tables truncated; v3-era trace still served from events_full |

The data set is small (hundreds of traces), so the times are not sizing figures. They show the
mechanisms, and that each wait is real.

### What the guides do not tell you

1. **The background-migration gate never reaches 0 on 3.225.x.** The v4 backfill chain ships on the
   last v3 as five rows gated by `args.envGate`. The upstream query `WHERE finished_at IS NULL` returns
   them, and the UI lists them as *Queued*. Leave gated rows out: `… AND NOT (args ? 'envGate')`. Fail on
   anything else that is unfinished or failed.
2. **Restart the worker after web on every upgrade.** The worker looks for background migrations once,
   at start. Web inserts new rows while it migrates, so a worker that started first misses them. On
   3.172.1 → 3.225.15, `20261022_encrypt_legacy_webhook_headers` stayed pending until the restart.
3. **`migrate-v1-to-v2.sh` takes the image tag from values or the chart appVersion, not from the pods.**
   With the tag set by `--set` (or an ArgoCD parameter), it would have started the sibling on 3.224.1
   against data from 3.225.15. Pass `--image-tag` with the running version.
4. **The script's default MinIO client image is gone.** `quay.io/minio/mc:latest` answers 401 and
   `minio/mc` on Docker Hub no longer exists. Set `MC_IMAGE` to an image that has `mc`. The chart v1
   MinIO image does.
5. **The freeze stops on a stock v3 worker.** The drain check counts BullMQ `:delayed` sets. Every v3
   worker keeps repeatable-job entries there (integrations, data retention) that are due hours later,
   so the depth never reaches 0. The script stops with v1 web already at 0, which means the outage has
   started. Check `wait` + `active` yourself, then run with `--force`. `--force` also skips the
   Postgres-lag and readiness checks, so verify those after (06).
6. **The rollback error names the current schema version.** On 4.72.0 it is 53, not the 46 quoted in
   the guide.
7. **Chart v2 sets `CLICKHOUSE_CLUSTER_ENABLED=true`, even with one replica.** Use the *clustered*
   rewind command and `TRUNCATE … ON CLUSTER default`.
8. **A rewind empties the new tables.** Whatever dual wrote to events_full before a rollback is gone
   afterwards. It survives in the old tables, so the backfill brings it back. Do not enable the
   backfill until you are back on dual for good.
9. **After the backfill, OTel-SDK traces have two roots.** The backfill adds a virtual root `t-<id>`
   per trace. A trace sent by SDK v3, which already had its own root span, shows the virtual root and,
   under it, the SDK root, both named after the trace. Observation counts by name double for those
   roots. Not looked into further.
10. **Python SDK v3 keeps working after the cutover.** It sends OpenTelemetry, so `events_only`
    accepts it. What the cutover stops is the legacy REST ingestion (`/api/public/ingestion` for
    anything but scores) and SDK v2.

### Not tested here

- ArgoCD or any `helm template` pipeline. The chart warns that `lookup` does not run there, so
  generated credentials rotate on every sync. Pin salt, encryption key and NextAuth secret explicitly
  (this lab used one pre-created Secret).
- External stores (`*.deploy: false`, the in-place path), ClickHouse with more than one replica, a
  ClickHouse user with only the documented grants (the bundled user has full rights), chart Ingress.
- A ClickHouse backup and restore. Only Postgres was dumped. In production, snapshot the volumes or
  use `BACKUP`.
- Retention-based rollover instead of the backfill; JS/TS SDK; LLM-as-a-Judge evaluators and exports
  moving to the observation level; data volumes beyond a few hundred traces.

---

## 한국어

> **관련 글**: [Langfuse 셀프호스팅 업그레이드: Helm chart v1 → v2, Langfuse v3 → v4](https://clickhouse.litkhai.dev/articles/langfuse/langfuse-helm-v3-to-v4-upgrade/)

Helm chart에 들어 있는 ClickHouse로 Langfuse v3를 운영하고 있다면 v4로 바로 올릴 수 없습니다.
chart v1의 ClickHouse는 25.2이고 v4가 요구하는 25.12까지 올릴 방법이 없습니다. chart v2에서는 가능합니다.
그래서 업그레이드가 두 번, 이 순서로 필요합니다.

1. **chart v1 → v2** (인프라). Bitnami 저장소를 모두 바꿉니다. 그냥 `helm upgrade`를 하면 chart가 막으므로,
   v2 release를 옆에 하나 더 띄우고 v1이 서비스하는 동안 데이터를 복사한 다음 트래픽을 옮깁니다.
2. **Langfuse v3 → v4** (애플리케이션). chart v2 위에서 쓰기 모드를
   `legacy` → `dual` → backfill → `events_only` 순서로 바꿉니다.

이 실습은 둘 다 로컬 kind 클러스터에서 처음부터 끝까지 실행합니다. 오래된 v3(3.172.1)에서 시작하고,
chart 복사 중에도 트래픽을 계속 보내고, 전환 전에 롤백을 리허설하고, 단계마다 저장소를 직접 확인합니다.
공식 가이드 두 개([upgrade-v1-to-v2](https://github.com/langfuse/langfuse-k8s/tree/main/examples/upgrade-v1-to-v2),
[upgrade v3 to v4](https://langfuse.com/self-hosting/upgrade/upgrade-guides/upgrade-v3-to-v4))를 따르고,
가이드대로 되지 않은 곳은 그 단계에 적었습니다([가이드에 없는 것](#가이드에-없는-것)).

`_base/` 실습이 아닙니다. Docker Compose가 아니라 Kubernetes에서 돌기 때문에 `v3/`·`v4/` 트랙 폴더 밖에 둡니다.

### 경로

위 English 절의 그림과 같습니다.

### 고정 버전 (2026-11-03 확인)

위 English 절의 표와 같습니다.

### 사전 준비물

kind 노드에 쓸 여유 메모리 약 8 GB가 있는 Docker, `kind`, `kubectl`, `helm` 3.17 이상, `jq`, Python 3.10 이상
(기본 `PYTHON=python3.12`), `openssl`. 화면 캡처(`shots.mjs`)를 하려면 Playwright가 있어야 합니다.

### 단계

| 단계 | 하는 일 | 통과 조건 |
|---|---|---|
| `01-cluster.sh` | kind 클러스터, 공유 앱 Secret(salt, 암호화 키, NextAuth secret), SDK 가상환경 | — |
| `02-install-v1.sh` | chart 1.5.41, 저장소 모두 내장, Langfuse 3.172.1 | 저장소 기동, `wal_level=logical` |
| `03-seed-v3.sh [phase]` | 클라이언트용 Service `langfuse-app`; prompt, dataset, experiment run; SDK v3 trace 40개, legacy API trace 10개; `inventory.sh v1` | — |
| `04-latest-v3.sh` | chart v1에서 이미지 3.225.15로, web 다음에 worker 재시작 | gate 없는 미완료 background migration 0, 실패 0; ClickHouse schema 37 |
| `05-migrate-chart.sh` | 공식 `migrate-v1-to-v2.sh --yes --force`, `traffic.sh`가 초당 trace 1개; 스크립트가 요청하면 `langfuse-app`을 v2로 | — |
| `06-verify-v2.sh` | 복사 전 v1과 복사 후 v2의 개수, 받아들여진 트래픽, 기존 키와 비밀번호 | 모두 PASS |
| `07-v4-legacy.sh` | gate 다시, `pg_dump`, 이미지 4.72.0 + `legacy` | 가이드대로 테이블 삭제·생성; 예전 테이블에 기록, events_full 비어 있음; v3 API 200 |
| `08-v4-dual.sh` | `dual`; SDK v3·SDK v4·legacy API trace; 전파 대기 | 모든 producer가 events_full에 |
| `09-rollback-rehearsal.sh` | v3 이미지만 교체; 37로 되감기; v3; 다시 v4 `dual` | 되감기 없이는 v3 web이 뜨지 않고, 되감은 뒤에는 뜸 |
| `10-backfill.sh` | backfill 켜기, 1~4단계 대기 | 예전 테이블의 trace·observation 중 events_full에 없는 것 0 |
| `11-cutover.sh` | `events_only` | 예전 테이블에 더 이상 기록 안 됨; 지원 종료 엔드포인트; 대체 API |
| `12-cleanup-storage.sh` | 중간 테이블 삭제, 예전 테이블 truncate | v3 시절 trace를 v2 observations로 여전히 조회 |
| `99-cleanup.sh` | 클러스터와 `.work/` 삭제 | — |

이 디렉터리에서 순서대로 실행합니다. 검증 실행처럼 최신 v3가 쓴 데이터도 넣으려면 04 다음에
`03-seed-v3.sh v3-latest`를 한 번 더 실행합니다. 07~11의 모드는 `modes/`에 있고 `v4-values.yaml`이
ConfigMap으로 붙입니다. 쓰기 모드를 바꿀 때는 `kubectl apply`와 재시작만 하고, values 파일은 바꾸지 않습니다.

### 결과 (2026-11-03)

확인한 버전: Langfuse 3.172.1 → 3.225.15 → 4.72.0 / SDK 3.15.0, 4.17.0 / ClickHouse 25.2.1.3085 → 26.8.36.3,
chart 1.5.41 → 2.2.1, kind 0.33.0(Kubernetes 1.37.0, 노드 1개), Helm 4.3.1, Docker 29.9.2. 모든 통과 조건을
만족했습니다. 전체 로그: [lab-output.md](lab-output.md).

| 단계 | 결과 |
|---|---|
| 04 최신 v3 | gate 없는 미완료 background migration 0, 실패 0; ClickHouse schema 37 |
| 05–06 chart v2 | Postgres 개수와 API 키 해시 동일; ClickHouse traces/observations/scores/dataset_run_items_rmt 104/264/80/4 양쪽 동일; 받아들여진 트래픽 trace 339개 모두 v2에 있음; v1 키와 비밀번호 동작 |
| 05 다운타임 | 재개한 실행 215초(온라인 복사, 60초 drain 대기, 마지막 델타, scale-up, 전환 포함); 전환 13초 뒤 첫 2xx. 이번 실행의 실패 구간 682초에는 첫 실행이 멈춘 시간(5번)이 들어 있음 |
| 07 legacy | schema 37 → 53; Postgres `traces observations scores dataset_run_items` 삭제; ClickHouse `event_log project_environments dataset_run_items` 삭제, `events_full events_core observations_batch_staging` 생성; 기록은 예전 테이블에만; v3 API 200, v2 observations 404 |
| 08 dual | SDK 4.17.0은 바로 events_full에; SDK 3.15.0과 legacy API는 **557초** 뒤 |
| 09 롤백 | v3 이미지만 바꾸면 web이 준비되지 않음, `no migration found for version 53`; 53 → 37 되감기(clustered 명령); v3가 뜨고 v4에서 쓴 trace를 읽음; 다시 v4로 가면 events 테이블이 빈 채로 다시 생김 |
| 10 backfill | trace 527개·observation 409개를 1~4단계 **225초**; events_full에 빠진 것 없음; virtual root 527개 |
| 11 events_only | 예전 테이블에 기록 없음; 지원 종료 엔드포인트 12개 404; legacy ingestion 207 + 이벤트별 400; SDK 3.15.0은 계속 받음; v2 observations, v3 scores, v2 metrics, experiments 200 |
| 12 정리 | 중간 테이블 삭제, 예전 테이블 truncate; v3 시절 trace를 events_full에서 계속 조회 |

데이터가 수백 건이라 시간은 용량 산정용 수치가 아닙니다. 동작 방식과, 각 대기 시간이 실제로 있다는 것을 보여 줍니다.

### 가이드에 없는 것

1. **최신 v3(3.225.x)에서는 background migration gate가 0이 되지 않습니다.** v4 backfill 단계 다섯 개가
   `args.envGate`로 잠긴 행으로 마지막 v3에 미리 들어 있습니다. 공식 쿼리 `WHERE finished_at IS NULL`은
   이 행들을 돌려주고, UI에도 *Queued*로 나옵니다. gate가 있는 행은 빼고 셉니다:
   `… AND NOT (args ? 'envGate')`. 그 밖에 끝나지 않았거나 실패한 행이 있으면 멈춥니다.
2. **업그레이드할 때마다 web 다음에 worker를 재시작합니다.** worker는 시작할 때 한 번만 background migration을
   찾습니다. web은 migration을 적용하면서 새 행을 넣기 때문에, 먼저 뜬 worker는 그 행을 놓칩니다.
   3.172.1 → 3.225.15에서 `20261022_encrypt_legacy_webhook_headers`가 재시작 전까지 대기 상태였습니다.
3. **`migrate-v1-to-v2.sh`는 이미지 태그를 실행 중인 pod가 아니라 values나 chart appVersion에서 가져옵니다.**
   태그를 `--set`(또는 ArgoCD parameter)으로 지정했다면 3.225.15의 데이터에 3.224.1 sibling을 띄웠을 것입니다.
   실행 중인 버전을 `--image-tag`로 넘깁니다.
4. **스크립트의 기본 MinIO client 이미지가 없습니다.** `quay.io/minio/mc:latest`는 401을 돌려주고, Docker Hub의
   `minio/mc`는 더 이상 없습니다. `mc`가 들어 있는 이미지를 `MC_IMAGE`로 지정합니다. chart v1의 MinIO 이미지에 있습니다.
5. **기본 설정의 v3 worker에서 freeze가 멈춥니다.** drain 확인이 BullMQ `:delayed`까지 셉니다. 모든 v3 worker는
   몇 시간 뒤에 실행될 반복 작업(연동, 데이터 보존) 항목을 거기에 두므로 0이 되지 않습니다. 스크립트는
   v1 web을 이미 0으로 줄인 상태, 즉 장애가 시작된 상태에서 멈춥니다. `wait` + `active`를 직접 확인한 뒤
   `--force`로 실행합니다. `--force`는 Postgres 지연과 readiness 확인도 건너뛰므로 06처럼 나중에 확인합니다.
6. **롤백 오류 메시지의 버전은 현재 schema 버전입니다.** 4.72.0에서는 가이드에 적힌 46이 아니라 53입니다.
7. **chart v2는 replica가 하나여도 `CLICKHOUSE_CLUSTER_ENABLED=true`입니다.** 되감기는 *clustered* 명령을, truncate는
   `ON CLUSTER default`를 씁니다.
8. **되감기를 하면 새 테이블이 비워집니다.** 롤백 전에 dual이 events_full에 쓴 데이터는 사라집니다. 예전 테이블에는
   남아 있어서 backfill이 다시 가져옵니다. dual로 확실히 돌아오기 전에는 backfill을 켜지 않습니다.
9. **backfill 뒤 OTel SDK trace에는 루트가 둘 생깁니다.** backfill은 trace마다 virtual root `t-<id>`를 만듭니다.
   SDK v3로 보낸 trace는 원래 자체 루트 span이 있어서, virtual root 아래에 SDK 루트가 한 번 더 보이고 둘의 이름이 같습니다.
   이름별 observation 수는 이 루트만큼 두 배가 됩니다. 더 들여다보지는 않았습니다.
10. **Python SDK v3는 전환 뒤에도 동작합니다.** OpenTelemetry로 보내므로 `events_only`가 받습니다. 전환으로 막히는 것은
    legacy REST ingestion(score 외의 `/api/public/ingestion`)과 SDK v2입니다.

### 여기서 확인하지 않은 것

- ArgoCD 등 `helm template` 파이프라인. chart 안내대로 거기서는 `lookup`이 동작하지 않아 자동 생성 자격 증명이
  sync마다 바뀝니다. salt, 암호화 키, NextAuth secret을 명시적으로 고정합니다(이 실습은 미리 만든 Secret 하나를 씀).
- 외부 저장소(`*.deploy: false`, in-place 경로), replica가 둘 이상인 ClickHouse, 문서의 grant만 가진 ClickHouse 사용자
  (내장 사용자는 전체 권한), chart Ingress.
- ClickHouse 백업·복원. Postgres만 dump했습니다. 운영에서는 볼륨 스냅샷이나 `BACKUP`을 씁니다.
- backfill 대신 보존 기간 rollover; JS/TS SDK; LLM-as-a-Judge 평가와 export를 observation 단위로 옮기는 작업;
  수백 건을 넘는 데이터 양.
