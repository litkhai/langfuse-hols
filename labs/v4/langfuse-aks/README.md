# Langfuse on AKS: Helm values with room to spare, verified on kind

[English](#english) | [한국어](#한국어)

---

## English

**Verified end to end on 2026-11-03** with the official chart **langfuse 2.2.1** (Langfuse 4.70.1, ClickHouse 26.8.36.3), clickhouse-operator 0.0.8 and cert-manager v1.20.2. Fresh kind cluster (kind 0.33.0, Kubernetes v1.37.0; Docker 29.9.2 with 12 CPU / 16 GiB): [03-checks.sh](03-checks.sh) passed 19 checks and [04-render-aks.sh](04-render-aks.sh) 10. An injected fault (ClickHouse replicas 3 → 2 in `values-aks.yaml`) failed the render check, and it passed again after the revert. **Not run on AKS itself** and not against the Azure managed services (no spending): the AKS file is checked by rendering it and validating against a real Kubernetes API, and the same file runs on kind with an overlay that only shrinks sizes and swaps addresses.

[values-aks.yaml](values-aks.yaml) is the deliverable: self-hosted Langfuse on AKS with ClickHouse OSS run by the operator and Postgres, Redis and Blob as Azure managed services.

### Sizing

| Component | Count | Each (requests) | Where | Documented minimum |
|---|---|---|---|---|
| Langfuse web | 2 (HPA 2–4) | 2 CPU / 4 GiB | `app` pool | 2 CPU / 4 GiB |
| Langfuse worker | 2 (HPA 2–6) | 2 CPU / 4 GiB | `app` pool | 2 CPU / 4 GiB |
| ClickHouse | 1 shard × 3 replicas | 6 CPU / 24 GiB (limit 26 GiB), 512 GiB Premium SSD | `clickhouse` pool, 1 per node | 2 CPU / 8 GiB; 16 GiB+ for larger deployments |
| ClickHouse Keeper | 3 | 0.5 CPU / 1 GiB, 20 GiB | `app` pool, spread | — |
| PostgreSQL | Azure Database for PostgreSQL Flexible Server | 2 vCPU / 8 GiB, zone-redundant HA | managed | 2 CPU / 4 GiB |
| Redis | Azure Managed Redis, non-clustered, `noeviction` | ~4 GiB | managed | 1 CPU / 1.5 GiB |
| Blob | Azure Blob Storage, one container | — | managed | — |

Node pools: `app` 3 × 4 vCPU / 16 GiB; `clickhouse` 3 × 8 vCPU / 32 GiB, tainted `dedicated=clickhouse:NoSchedule`, one ClickHouse replica each (required anti-affinity).

Why these numbers:
- **The room goes to ClickHouse.** UI queries, dashboards and evaluations all land there, and the Langfuse docs say ClickHouse scales vertically: more memory gives faster answers.
- **Web and worker stay at the documented minimum and scale out.** The docs scale workers when a 2-CPU container passes 50% CPU (or on the ingestion queue depth). The HPA needs metrics-server, which AKS installs by default per the Azure docs (not checked here); on kind, which has none, it shows `<unknown>`.
- **One shard, three replicas.** Langfuse does not support a multi-shard cluster ("Today, Langfuse does not support a multi-shard cluster"), and recommends at least 3 replicas for production. The replica count is hard to change later, so it starts at 3. Every replica holds a full copy: total disk = 3 × per-replica size.
- **Postgres and Redis are small.** Traces go to ClickHouse; Postgres holds users, settings, prompts and the audit log, Redis the queue and cache.

### Prerequisites on AKS (once per cluster)

```bash
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.20.2 \
  --namespace cert-manager --create-namespace --set crds.enabled=true
helm install clickhouse-operator oci://ghcr.io/clickhouse/clickhouse-operator-helm --version 0.0.8 \
  --namespace clickhouse-operator --create-namespace
```

Then: the two node pools, the Azure services (PostgreSQL Flexible Server, Azure Managed Redis, a storage account **with the container already created**), the `langfuse` Secret ([secret-example.yaml](secret-example.yaml)), the TLS secret `langfuse-tls`, and

```bash
helm install langfuse langfuse/langfuse --version 2.2.1 -n langfuse -f values-aks.yaml
```

### Run the local verification

```bash
cd labs/v4/langfuse-aks
./01-kind-up.sh       # kind cluster shaped like the AKS pools, cert-manager, operator, stand-ins, Secrets
./02-install.sh       # the chart with values-aks.yaml + values-kind.yaml
./03-checks.sh        # placement, wiring, data path, failover (19 checks)
./04-render-aks.sh    # values-aks.yaml alone: render, server-side dry run, field checks (10 checks)
./99-down.sh          # delete the kind cluster
```

Needs `kind`, `kubectl`, `helm`, `jq`, `openssl`, `uv`. The langfuse-hols compose stack uses ports and memory too; stop it first (`lf_compose -- stop`). Stand-ins on kind ([standins.yaml](standins.yaml)): Postgres 17.11 for the Flexible Server, Redis 7.2.16 for Azure Managed Redis, Azurite 3.37.0 for Blob Storage (the chart's `storageProvider: azure` path, account key generated per run).

### What the checks found (2026-11-03)

`03-checks.sh`: 19 PASS
- **Placement:** the three ClickHouse replicas on three different `clickhouse` nodes; web, worker and Keeper on `app`; ClickHouseCluster and KeeperCluster 3/3 ready; HPA 2–4 and 2–6; four PDBs (web and worker from the chart, ClickHouse and Keeper from the operator).
- **Cluster:** `default` is 1 shard, 3 replicas; `events_full`, `events_core` and `scores` are `ReplicatedReplacingMergeTree`.
- **Wiring:** `CLICKHOUSE_CLUSTER_ENABLED=true`, `LANGFUSE_USE_AZURE_BLOB=true`, Postgres and Redis at the stand-ins.
- **Data path:** a trace sent through the public API is read back, its row is on all three replicas, its raw event in the Blob container, the project in Postgres.
- **Failover:** with one ClickHouse replica deleted, a new trace is ingested and read back, and the replica returns with that row. With one Keeper deleted, the same.

`04-render-aks.sh`: 10 PASS. `values-aks.yaml` alone (placeholders swapped for example values) renders 12 objects that the kind API accepts in a server-side dry run, with web/worker 2 CPU / 4 GiB on `app` (replicas owned by the HPA), ClickHouse 3 replicas × 6 CPU / 24 GiB / 512 GiB `managed-csi-premium` on the tainted pool, Keeper 3, ingress class `webapprouting.kubernetes.azure.com` with TLS, and Redis as `rediss://…:10000`.

### Things worth knowing

- **Create the Blob container beforehand.** The chart docs say Langfuse attempts to create a missing container; Langfuse 4.70.1 did not, on upload or after a restart: every event PUT got 404 and OTLP ingestion answered HTTP 500 (`Failed to upload JSON to Azure Blob Storage`). [01-kind-up.sh](01-kind-up.sh) creates it, as IaC would on Azure.
- **First start restarts a few times.** ClickHouse exits with a Keeper coordination error (exit 231) until Keeper is up, and web until ClickHouse answers. Both settle on their own; [02-install.sh](02-install.sh) waits on the CR conditions instead of pod counts.
- **Anti-affinity needs the operator's label.** clickhouse-operator 0.0.8 labels pods `clickhouse.com/role=clickhouse-server` (and `clickhouse-keeper`); the values use it.
- **With HPA on, the chart omits `spec.replicas`.** The HPA minimum (2) is the floor.
- **Azurite only:** in-cluster hostnames need `--disableProductStyleUrl`, or Azurite reads `azurite.standins…` as `<account>.<host>` and answers 400. Not relevant on Azure.
- **Langfuse version:** the chart runs Langfuse 4.70.1, newer than the compose labs' pin (4.56.0).

### Not run

- An AKS cluster, the Azure managed services, the AKS application routing add-on and Premium SSD volumes (checked only as rendered fields).
- Load: no throughput or latency measured; the sizing follows the docs' minimums plus room, not a benchmark.
- Disk size: 512 GiB per replica is a placeholder; size it from daily observations × average size × retention, measured on PoC data.

### Files

| File | What |
|---|---|
| [values-aks.yaml](values-aks.yaml) | the AKS values (the deliverable) |
| [values-kind.yaml](values-kind.yaml) | overlay for kind: sizes, addresses, storage class, headless init |
| [secret-example.yaml](secret-example.yaml) | the keys of the `langfuse` Secret |
| [kind-config.yaml](kind-config.yaml) | kind cluster shaped like the AKS pools |
| [standins.yaml](standins.yaml) | Postgres, Redis, Azurite on kind |
| `01`–`04`, `99` | setup, install, checks, AKS render check, teardown |

---

## 한국어

**2026-11-03에 처음부터 끝까지 검증**했습니다. 공식 차트 **langfuse 2.2.1**(Langfuse 4.70.1, ClickHouse 26.8.36.3), clickhouse-operator 0.0.8, cert-manager v1.20.2 기준입니다. 새 kind 클러스터(kind 0.33.0, Kubernetes v1.37.0, Docker 29.9.2에 12 CPU / 16 GiB)에서 [03-checks.sh](03-checks.sh)가 확인 19개, [04-render-aks.sh](04-render-aks.sh)가 10개를 통과했습니다. 일부러 넣은 결함(`values-aks.yaml`의 ClickHouse replica 3 → 2)은 렌더 검사가 잡았고, 되돌리자 다시 통과했습니다. **AKS 자체와 Azure 관리형 서비스에서는 실행하지 않았습니다**(비용 없음). AKS 파일은 렌더링해서 실제 Kubernetes API로 검증했고, 같은 파일을 사양과 주소만 바꾸는 overlay와 함께 kind에서 띄웠습니다.

결과물은 [values-aks.yaml](values-aks.yaml)입니다. AKS에서 셀프호스팅 Langfuse를 운영하는 구성으로, ClickHouse OSS는 operator로 띄우고 Postgres, Redis, Blob은 Azure 관리형 서비스를 씁니다.

### 사이징

| 구성 요소 | 대수 | 대당(requests) | 위치 | 문서 최소치 |
|---|---|---|---|---|
| Langfuse web | 2 (HPA 2–4) | 2 CPU / 4 GiB | `app` 풀 | 2 CPU / 4 GiB |
| Langfuse worker | 2 (HPA 2–6) | 2 CPU / 4 GiB | `app` 풀 | 2 CPU / 4 GiB |
| ClickHouse | 1 shard × 3 replica | 6 CPU / 24 GiB(limit 26 GiB), Premium SSD 512 GiB | `clickhouse` 풀, 노드당 1개 | 2 CPU / 8 GiB, 큰 배포는 16 GiB 이상 |
| ClickHouse Keeper | 3 | 0.5 CPU / 1 GiB, 20 GiB | `app` 풀, 분산 | — |
| PostgreSQL | Azure Database for PostgreSQL Flexible Server | 2 vCPU / 8 GiB, 영역 중복 HA | 관리형 | 2 CPU / 4 GiB |
| Redis | Azure Managed Redis, 비클러스터, `noeviction` | 4 GiB 안팎 | 관리형 | 1 CPU / 1.5 GiB |
| Blob | Azure Blob Storage, 컨테이너 1개 | — | 관리형 | — |

노드 풀: `app`은 4 vCPU / 16 GiB 3대. `clickhouse`는 8 vCPU / 32 GiB 3대로, `dedicated=clickhouse:NoSchedule` taint를 걸고 노드마다 ClickHouse replica 하나를 둡니다(required anti-affinity).

이렇게 잡은 이유:
- **여유는 ClickHouse에 둡니다.** 화면 조회, 대시보드, 평가가 모두 여기로 몰리고, Langfuse 문서도 ClickHouse는 메모리를 늘릴수록 빨라진다고 합니다.
- **web·worker는 문서 최소치로 두고 대수로 늘립니다.** 문서는 2 CPU 컨테이너가 CPU 50%를 넘거나 수집 큐가 쌓이면 worker를 늘립니다. HPA에는 metrics-server가 필요하고, Azure 문서에 따르면 AKS는 이를 기본 설치합니다(여기서 확인하지 않음). metrics-server가 없는 kind에서는 `<unknown>`으로 보입니다.
- **shard는 하나, replica는 셋.** Langfuse는 멀티 샤드를 지원하지 않고("Today, Langfuse does not support a multi-shard cluster"), 운영에는 replica 3개 이상을 권합니다. replica 수는 나중에 바꾸기 어려워 처음부터 3으로 둡니다. replica마다 전체 사본이 있으므로 총 디스크는 replica 하나의 3배입니다.
- **Postgres와 Redis는 작게.** trace는 ClickHouse로 가고, Postgres에는 사용자, 설정, 프롬프트, 감사 로그, Redis에는 큐와 캐시만 있습니다.

### AKS 사전 준비(클러스터마다 한 번)

```bash
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.20.2 \
  --namespace cert-manager --create-namespace --set crds.enabled=true
helm install clickhouse-operator oci://ghcr.io/clickhouse/clickhouse-operator-helm --version 0.0.8 \
  --namespace clickhouse-operator --create-namespace
```

그다음 노드 풀 두 개, Azure 서비스(PostgreSQL Flexible Server, Azure Managed Redis, **컨테이너를 미리 만든** 스토리지 계정), `langfuse` Secret([secret-example.yaml](secret-example.yaml)), TLS secret `langfuse-tls`를 준비하고 설치합니다.

```bash
helm install langfuse langfuse/langfuse --version 2.2.1 -n langfuse -f values-aks.yaml
```

### 로컬 검증 실행

```bash
cd labs/v4/langfuse-aks
./01-kind-up.sh       # AKS 풀 모양의 kind 클러스터, cert-manager, operator, 대체 서비스, Secret
./02-install.sh       # values-aks.yaml + values-kind.yaml로 차트 설치
./03-checks.sh        # 배치, 연결, 데이터 경로, 장애 조치 (확인 19개)
./04-render-aks.sh    # values-aks.yaml 단독: 렌더, server-side dry run, 필드 확인 (확인 10개)
./99-down.sh          # kind 클러스터 삭제
```

`kind`, `kubectl`, `helm`, `jq`, `openssl`, `uv`가 필요합니다. langfuse-hols compose 스택도 포트와 메모리를 쓰므로 먼저 멈춥니다(`lf_compose -- stop`). kind의 대체 서비스([standins.yaml](standins.yaml))는 Flexible Server 대신 Postgres 17.11, Azure Managed Redis 대신 Redis 7.2.16, Blob Storage 대신 Azurite 3.37.0입니다. Azurite는 차트의 `storageProvider: azure` 경로를 그대로 타고, 계정 키는 실행할 때마다 만듭니다.

### 확인한 것 (2026-11-03)

`03-checks.sh`: 19개 PASS
- **배치:** ClickHouse replica 3개가 서로 다른 `clickhouse` 노드 3대에 있고, web, worker, Keeper는 `app`에 있습니다. ClickHouseCluster와 KeeperCluster는 3/3 준비, HPA는 2–4와 2–6, PDB는 4개입니다(web·worker는 차트, ClickHouse·Keeper는 operator가 만듦).
- **클러스터:** `default`는 1 shard, 3 replica이고, `events_full`, `events_core`, `scores`는 `ReplicatedReplacingMergeTree`입니다.
- **연결:** `CLICKHOUSE_CLUSTER_ENABLED=true`, `LANGFUSE_USE_AZURE_BLOB=true`, Postgres와 Redis는 대체 서비스를 가리킵니다.
- **데이터 경로:** public API로 보낸 trace가 다시 읽히고, 그 행이 replica 3개 모두에 있고, 원본 이벤트는 Blob 컨테이너에, 프로젝트는 Postgres에 있습니다.
- **장애 조치:** ClickHouse replica 하나를 지운 상태에서도 새 trace가 수집되고 읽혔으며, 돌아온 replica에 그 행이 있었습니다. Keeper 하나를 지웠을 때도 같았습니다.

`04-render-aks.sh`: 10개 PASS. `values-aks.yaml`만으로(자리표시자는 예시 값으로 바꿈) 객체 12개가 렌더링되고, kind API가 server-side dry run으로 받아들였습니다. web·worker는 `app`에 2 CPU / 4 GiB(대수는 HPA가 정함), ClickHouse는 taint 걸린 풀에 3 replica × 6 CPU / 24 GiB / 512 GiB `managed-csi-premium`, Keeper 3, ingress class `webapprouting.kubernetes.azure.com`과 TLS, Redis는 `rediss://…:10000`입니다.

### 알아 둘 것

- **Blob 컨테이너는 미리 만듭니다.** 차트 문서는 없는 컨테이너를 Langfuse가 만들려고 시도한다고 하지만, Langfuse 4.70.1은 업로드 때도 재시작한 뒤에도 만들지 않았습니다. 이벤트 PUT이 모두 404였고, OTLP 수집은 HTTP 500(`Failed to upload JSON to Azure Blob Storage`)이었습니다. Azure에서 IaC로 하듯, [01-kind-up.sh](01-kind-up.sh)가 미리 만듭니다.
- **첫 기동에는 몇 번 재시작합니다.** Keeper가 뜨기 전까지 ClickHouse가 Keeper 연결 오류(exit 231)로 끝나고, ClickHouse가 응답하기 전까지 web이 재시작합니다. 둘 다 저절로 안정되므로, [02-install.sh](02-install.sh)는 pod 수가 아니라 CR 상태를 기다립니다.
- **anti-affinity에는 operator의 라벨이 필요합니다.** clickhouse-operator 0.0.8은 pod에 `clickhouse.com/role=clickhouse-server`(Keeper는 `clickhouse-keeper`)를 붙이고, values가 이 라벨을 씁니다.
- **HPA를 켜면 차트가 `spec.replicas`를 빼고 렌더링합니다.** HPA 최소값(2)이 하한입니다.
- **Azurite에서만:** 클러스터 내부 hostname에는 `--disableProductStyleUrl`이 필요합니다. 없으면 Azurite가 `azurite.standins…`를 `<account>.<host>`로 읽어 400을 돌려줍니다. Azure에서는 상관없습니다.
- **Langfuse 버전:** 차트는 Langfuse 4.70.1을 띄웁니다. compose 실습의 고정 버전(4.56.0)보다 새 버전입니다.

### 실행하지 않은 것

- AKS 클러스터, Azure 관리형 서비스, AKS application routing 애드온, Premium SSD 볼륨(렌더된 필드로만 확인)
- 부하: 처리량이나 지연은 측정하지 않았습니다. 사이징은 벤치마크가 아니라 문서 최소치에 여유를 더한 값입니다.
- 디스크 크기: replica당 512 GiB는 자리표시자입니다. 하루 observation 수 × 평균 크기 × 보존 기간을 PoC 데이터로 실측해 정합니다.

### 파일

| 파일 | 내용 |
|---|---|
| [values-aks.yaml](values-aks.yaml) | AKS values(결과물) |
| [values-kind.yaml](values-kind.yaml) | kind용 overlay: 사양, 주소, 스토리지 클래스, headless init |
| [secret-example.yaml](secret-example.yaml) | `langfuse` Secret의 키 |
| [kind-config.yaml](kind-config.yaml) | AKS 풀 모양의 kind 클러스터 |
| [standins.yaml](standins.yaml) | kind의 Postgres, Redis, Azurite |
| `01`–`04`, `99` | 설정, 설치, 확인, AKS 렌더 검사, 정리 |
