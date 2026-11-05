# Langfuse on managed Kubernetes (AKS, EKS, GKE): Helm values with room to spare, verified on kind

[English](#english) | [한국어](#한국어)

---

## English

**Verified end to end on 2026-11-04** with the official chart **langfuse 2.2.1** (Langfuse 4.70.1, ClickHouse 26.8.36.3), clickhouse-operator 0.0.8 and cert-manager v1.20.2, from a deleted kind cluster with a staged first install (kind 0.33.0, Kubernetes v1.37.0; Docker 29.9.2 with 12 CPU / 16 GiB): [03-checks.sh](03-checks.sh) passed 19 checks on `values-base.yaml` + the kind overlay, and [04-render-clouds.sh](04-render-clouds.sh) 42 (14 per cloud) on `values-base.yaml` + each cloud file. On 2026-11-03 an injected fault (ClickHouse replicas 3 → 2) failed the render check. **Not run on AKS, EKS or GKE**, nor against their managed services (no spending): each cloud file is rendered and validated against a real Kubernetes API.

AKS, EKS and GKE differ only in a few places: the storage class, the ingress, the managed Postgres, Redis and object storage, and how pods get cloud credentials. So the sizing lives in one file and each cloud adds a short one:

```
values-base.yaml    sizing, node placement, HPA/PDB, ClickHouse 1 shard × 3 replicas + Keeper 3
values-aks.yaml     managed-csi-premium · app routing ingress · Flexible Server · Azure Managed Redis · Blob
values-eks.yaml     gp3 (storageclass-eks.yaml) · ALB · RDS · ElastiCache · S3 via IAM role
values-gke.yaml     premium-rwo · GKE Ingress · Cloud SQL · Memorystore · GCS via Workload Identity
```

### Sizing (values-base.yaml)

| Component | Count | Each (requests) | Where | Documented minimum |
|---|---|---|---|---|
| Langfuse web | 2 (HPA 2–4) | 2 CPU / 4 GiB | `workload=app` | 2 CPU / 4 GiB |
| Langfuse worker | 2 (HPA 2–6) | 2 CPU / 4 GiB | `workload=app` | 2 CPU / 4 GiB |
| ClickHouse | 1 shard × 3 replicas | 6 CPU / 24 GiB (limit 26 GiB), 1,850 GiB SSD (30 days, [below](#clickhouse-disk)) | `workload=clickhouse`, 1 per node | 2 CPU / 8 GiB; 16 GiB+ for larger deployments |
| ClickHouse Keeper | 3 | 0.5 CPU / 1 GiB, 20 GiB | `workload=app`, spread | — |
| PostgreSQL | managed, HA | 2 vCPU / 8 GiB | cloud service | 2 CPU / 4 GiB |
| Redis | managed, non-clustered, `noeviction` | ~4 GiB | cloud service | 1 CPU / 1.5 GiB |
| Object storage | one bucket / container | — | cloud service | — |

Node pools, the same on every cloud: `workload=app`, 3 × 4 vCPU / 16 GiB; `workload=clickhouse`, 3 × 8 vCPU / 32 GiB with the taint `dedicated=clickhouse:NoSchedule`, one ClickHouse replica each (required anti-affinity). Each cloud's built-in pool label is different, so the values use this custom label; set it and the taint when creating the pools (AKS `az aks nodepool add --labels --node-taints`, EKS managed node group labels and taints, GKE node pool label and `--node-taints`).

Why these numbers:
- **The room goes to ClickHouse.** UI queries, dashboards and evaluations all land there, and the Langfuse docs say ClickHouse scales vertically: more memory gives faster answers.
- **Web and worker stay at the documented minimum and scale out.** The docs scale workers when a 2-CPU container passes 50% CPU (or on the ingestion queue depth). The HPA needs metrics-server; on kind, which has none, it shows `<unknown>`.
- **One shard, three replicas.** Langfuse does not support a multi-shard cluster ("Today, Langfuse does not support a multi-shard cluster"), and recommends at least 3 replicas for production. The replica count is hard to change later. Every replica holds a full copy: total disk = 3 × per-replica size.
- **Postgres and Redis are small.** Traces go to ClickHouse; Postgres holds users, settings, prompts and the audit log, Redis the queue and cache.

### ClickHouse disk

Disk is sized by retention, not by load. Test 07 of [langfuse-ops-checks](../langfuse-ops-checks/README.md#07--clickhouse-resources-per-tier) (2026-11-04, laptop, Langfuse 4.56.0, ClickHouse 26.8.22.13; 4 observations per trace of 10 KB in + 1 KB out) measured **~2.0 KB on disk per observation, per replica**: 10.6 / 21.7 / 43.1 GiB per day at 1,000 / 2,000 / 4,000 traces/min. CPU and memory of the sizes above held with room in the same test; the disk did not: the earlier default of 512 GiB holds ~8 days at 4,000 traces/min.

Per replica = GiB per day × retention days ÷ 0.7 (30 % kept free for merges). `values-base.yaml` sets **30 days at 4,000 traces/min: 1,850 GiB**. Total = 3 × per replica.

| Traces/min | GiB per day | 7 days | 30 days | 90 days |
|---|---|---|---|---|
| 1,000 | 10.6 | 106 GiB | 454 GiB | 1,363 GiB |
| 2,000 | 21.7 | 217 GiB | 930 GiB | 2,790 GiB |
| 4,000 | 43.1 | 431 GiB | 1,847 GiB | 5,541 GiB |

- **Another retention or rate:** set `clickhouse.cluster.storage.size` in a file layered after `values-base.yaml`, from the table or the formula.
- **Payload changes it:** 2.0 KB is for 11 KB observations; smaller prompts need proportionally less. Re-measure GiB per day on PoC data.
- **Growing after install was not tested.** The EKS class here sets `allowVolumeExpansion: true`; check the AKS and GKE built-in classes with `kubectl get storageclass`. Whether clickhouse-operator 0.0.8 resizes existing PVCs when the value changes was not checked; volumes cannot shrink.
- **Blob storage** keeps the raw OTLP JSON in addition and is not sized here.

### What each cloud file sets

| | AKS | EKS | GKE |
|---|---|---|---|
| Storage class | `managed-csi-premium` (built-in) | `langfuse-gp3`, from [storageclass-eks.yaml](storageclass-eks.yaml) (EBS CSI driver; Auto Mode uses `ebs.csi.eks.amazonaws.com`) | `premium-rwo` (built-in SSD PD) |
| Ingress | `ingressClassName: webapprouting.kubernetes.azure.com` (app routing add-on) | annotation `kubernetes.io/ingress.class: alb`, IP targets, TLS at the ALB (ACM) | annotation `kubernetes.io/ingress.class: gce`; GKE does not accept `ingressClassName` |
| Postgres | Flexible Server, `sslmode=require` | RDS / Aurora PostgreSQL, `sslmode=require` | Cloud SQL private IP, `sslmode=require` |
| Redis | Azure Managed Redis, TLS on 10000 | ElastiCache, in-transit encryption, 6379 (Langfuse's ElastiCache example) | Memorystore, in-transit encryption on 6378 with the instance's server CA mounted |
| Objects | Blob Storage, storage account key; create the container first | S3, IAM role on the service account (IRSA or Pod Identity), no keys | GCS, Workload Identity (the chart falls back to the pod's service account) |

Vendor facts read on 2026-11-04 from the AKS, EKS, GKE and Memorystore docs; the ElastiCache port is from the Langfuse docs' example, not an AWS page.

### Install (any of the three)

Once per cluster: cert-manager and the ClickHouse operator.

```bash
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.20.2 \
  --namespace cert-manager --create-namespace --set crds.enabled=true
helm install clickhouse-operator oci://ghcr.io/clickhouse/clickhouse-operator-helm --version 0.0.8 \
  --namespace clickhouse-operator --create-namespace
```

Then the two node pools, the managed services, the `langfuse` Secret ([secret-example.yaml](secret-example.yaml)), on EKS `kubectl apply -f storageclass-eks.yaml`, on GKE the `memorystore-ca` Secret, and the chart in three steps the first time (later upgrades are one `helm upgrade`):

```bash
CLOUD=aks   # or eks, gke
H="helm upgrade --install langfuse langfuse/langfuse --version 2.2.1 -n langfuse -f values-base.yaml -f values-$CLOUD.yaml"
ZERO="--set langfuse.web.replicas=null --set langfuse.worker.replicas=null --set langfuse.web.hpa.enabled=false --set langfuse.worker.hpa.enabled=false"
$H $ZERO --set langfuse.replicas=0      # 1. ClickHouse and Keeper only
kubectl -n langfuse wait --for=condition=Ready keepercluster/langfuse clickhousecluster/langfuse --timeout=15m
$H $ZERO --set langfuse.replicas=1      # 2. one web pod runs the ClickHouse migrations
kubectl -n langfuse rollout status deploy/langfuse-web --timeout=15m
$H                                      # 3. full values
```

### Run the local verification

```bash
cd labs/v4/langfuse-k8s
./01-kind-up.sh         # kind cluster shaped like the node pools, cert-manager, operator, stand-ins, Secrets
./02-install.sh         # values-base.yaml + values-kind.yaml, staged first install
./03-checks.sh          # placement, wiring, data path, failover (19 checks)
./04-render-clouds.sh   # base + each cloud file: render, server-side dry run, field checks (42 checks)
./99-down.sh            # delete the kind cluster
```

Needs `kind`, `kubectl`, `helm`, `jq`, `openssl`, `uv`. The langfuse-hols compose stack uses ports and memory too; stop it first. Stand-ins on kind ([standins.yaml](standins.yaml)): Postgres 17.11, Redis 7.2.16, and Azurite 3.37.0 for object storage through the chart's Azure Blob path, with the account key generated per run.

### What the checks found

`03-checks.sh` (2026-11-04): 19 PASS
- **Placement:** the three ClickHouse replicas on three different `clickhouse` nodes; web, worker and Keeper on `app`; ClickHouseCluster and KeeperCluster 3/3 ready; HPA 2–4 and 2–6; four PDBs (web and worker from the chart, ClickHouse and Keeper from the operator).
- **Cluster:** `default` is 1 shard, 3 replicas; `events_full`, `events_core` and `scores` are `ReplicatedReplacingMergeTree`.
- **Wiring:** `CLICKHOUSE_CLUSTER_ENABLED=true`, Postgres and Redis at the stand-ins, object storage through the Azure Blob interface.
- **Data path:** a trace sent through the public API is read back, its row is on all three replicas, its raw event in the Blob container, the project in Postgres.
- **Failover:** with one ClickHouse replica deleted, a new trace is ingested and read back, and the replica returns with that row. With one Keeper deleted, the same.

`04-render-clouds.sh` (2026-11-05, re-run after the disk change; the 2026-11-04 run with 512 GiB also passed 42): 42 PASS, 14 per cloud. For each of AKS, EKS and GKE the rendered objects are accepted by the kind API in a server-side dry run (the EKS run includes the gp3 StorageClass), the base values come through unchanged (web and worker 2 CPU / 4 GiB on `app` with replicas owned by the HPA, liveness delay 300 s, ClickHouse 3 replicas × 6 CPU / 24 GiB / 1,850 GiB on the tainted pool, Keeper 3, cluster mode on), and the cloud file's choices land as intended: storage class, ingress class or annotation, `rediss://` port (10000, 6379, 6378 with the CA path on GKE), object storage interface with a static key only on AKS, and the workload identity annotation on EKS and GKE.

### Things worth knowing

- **Create the bucket or container beforehand.** The chart docs say Langfuse attempts to create a missing container; Langfuse 4.70.1 did not (Azure Blob path, 2026-11-03): every event PUT got 404 and OTLP ingestion answered HTTP 500 (`Failed to upload JSON to Azure Blob Storage`). [01-kind-up.sh](01-kind-up.sh) creates it, as IaC would.
- **Give the first start time to migrate.** Two first installs ended with `Dirty database version 5`: the migration state was left half-applied, and web restarted forever. The pod events show why: `Container langfuse-web failed liveness probe, will be restarted`. A first start applies 461 Postgres migrations and then the ClickHouse ones on three replicas, longer than the chart's default liveness window (20 s + 3 × 10 s, and no startup probe for web). `values-base.yaml` sets `livenessProbe.initialDelaySeconds: 300`, and [02-install.sh](02-install.sh) stages a first install: data stores first until the `ClickHouseCluster` and `KeeperCluster` Ready conditions (ClickHouse restarts a few times with a Keeper coordination error, exit 231, until Keeper is up), then one web pod for the migrations, then the full values.
- **Anti-affinity needs the operator's label.** clickhouse-operator 0.0.8 labels pods `clickhouse.com/role=clickhouse-server` (and `clickhouse-keeper`); the values use it.
- **With HPA on, the chart omits `spec.replicas`.** The HPA minimum (2) is the floor.
- **On EKS the Redis user is `default`.** The chart builds `rediss://default:…@…:6379` from the base; ElastiCache AUTH-token mode takes it. Azure Managed Redis and Memorystore use the key alone (`username: null`).
- **Azurite only:** in-cluster hostnames need `--disableProductStyleUrl`, or Azurite reads `azurite.standins…` as `<account>.<host>` and answers 400.
- **Langfuse version:** the chart runs Langfuse 4.70.1, newer than the compose labs' pin (4.56.0).

### Not run

- AKS, EKS and GKE clusters and their managed services, ingress controllers, load balancers and disks (checked only as rendered fields against the Kubernetes API).
- Workload identity (IRSA, Pod Identity, GKE Workload Identity) against real cloud IAM, and Memorystore's CA.
- Load: no throughput or latency measured; the sizing follows the docs' minimums plus room, not a benchmark.
- Disk on a cloud: 1,850 GiB rests on 07's laptop measurement with 11 KB observations ([ClickHouse disk](#clickhouse-disk)); re-measure GiB per day on PoC data.

### Files

| File | What |
|---|---|
| [values-base.yaml](values-base.yaml) | sizing and placement, the same on every cloud |
| [values-aks.yaml](values-aks.yaml) · [values-eks.yaml](values-eks.yaml) · [values-gke.yaml](values-gke.yaml) | what each cloud adds |
| [storageclass-eks.yaml](storageclass-eks.yaml) | gp3 StorageClass for EKS |
| [values-kind.yaml](values-kind.yaml) | overlay for kind: sizes, stand-in addresses, storage class, headless init |
| [secret-example.yaml](secret-example.yaml) | the keys of the `langfuse` Secret |
| [kind-config.yaml](kind-config.yaml) · [standins.yaml](standins.yaml) | kind cluster shaped like the node pools; Postgres, Redis, Azurite |
| `01`–`04`, `99` | setup, install, checks, cloud render checks, teardown |

---

## 한국어

**2026-11-04에 처음부터 끝까지 검증**했습니다. 공식 차트 **langfuse 2.2.1**(Langfuse 4.70.1, ClickHouse 26.8.36.3), clickhouse-operator 0.0.8, cert-manager v1.20.2 기준입니다. kind 클러스터를 지우고 첫 설치를 단계로 나눠 진행했습니다(kind 0.33.0, Kubernetes v1.37.0, Docker 29.9.2에 12 CPU / 16 GiB). [03-checks.sh](03-checks.sh)는 `values-base.yaml` + kind overlay로 확인 19개, [04-render-clouds.sh](04-render-clouds.sh)는 `values-base.yaml` + 클라우드 파일마다 14개씩 모두 42개를 통과했습니다. 2026-11-03에는 일부러 넣은 결함(ClickHouse replica 3 → 2)을 렌더 검사가 잡았습니다. **AKS, EKS, GKE와 그 관리형 서비스에서는 실행하지 않았습니다**(비용 없음). 클라우드 파일마다 렌더링해서 실제 Kubernetes API로 검증했습니다.

AKS, EKS, GKE는 몇 군데만 다릅니다. 스토리지 클래스, ingress, 관리형 Postgres·Redis·오브젝트 스토리지, 그리고 pod가 클라우드 자격 증명을 얻는 방식입니다. 그래서 사이징은 파일 하나에 두고, 클라우드마다 짧은 파일을 더합니다.

```
values-base.yaml    사이징, 노드 배치, HPA/PDB, ClickHouse 1 shard × 3 replica + Keeper 3
values-aks.yaml     managed-csi-premium · app routing ingress · Flexible Server · Azure Managed Redis · Blob
values-eks.yaml     gp3 (storageclass-eks.yaml) · ALB · RDS · ElastiCache · IAM 역할로 S3
values-gke.yaml     premium-rwo · GKE Ingress · Cloud SQL · Memorystore · Workload Identity로 GCS
```

### 사이징 (values-base.yaml)

| 구성 요소 | 대수 | 대당(requests) | 위치 | 문서 최소치 |
|---|---|---|---|---|
| Langfuse web | 2 (HPA 2–4) | 2 CPU / 4 GiB | `workload=app` | 2 CPU / 4 GiB |
| Langfuse worker | 2 (HPA 2–6) | 2 CPU / 4 GiB | `workload=app` | 2 CPU / 4 GiB |
| ClickHouse | 1 shard × 3 replica | 6 CPU / 24 GiB(limit 26 GiB), SSD 1,850 GiB(30일, [아래](#clickhouse-디스크)) | `workload=clickhouse`, 노드당 1개 | 2 CPU / 8 GiB, 큰 배포는 16 GiB 이상 |
| ClickHouse Keeper | 3 | 0.5 CPU / 1 GiB, 20 GiB | `workload=app`, 분산 | — |
| PostgreSQL | 관리형, HA | 2 vCPU / 8 GiB | 클라우드 서비스 | 2 CPU / 4 GiB |
| Redis | 관리형, 비클러스터, `noeviction` | 4 GiB 안팎 | 클라우드 서비스 | 1 CPU / 1.5 GiB |
| 오브젝트 스토리지 | 버킷 / 컨테이너 1개 | — | 클라우드 서비스 | — |

노드 풀은 클라우드와 상관없이 같습니다. `workload=app`은 4 vCPU / 16 GiB 3대, `workload=clickhouse`는 8 vCPU / 32 GiB 3대로 `dedicated=clickhouse:NoSchedule` taint를 걸고 노드마다 ClickHouse replica 하나를 둡니다(required anti-affinity). 클라우드마다 기본 노드 풀 라벨이 달라서 values는 이 사용자 라벨을 씁니다. 풀을 만들 때 라벨과 taint를 함께 지정합니다(AKS `az aks nodepool add --labels --node-taints`, EKS 관리형 노드 그룹의 labels와 taints, GKE 노드 풀 라벨과 `--node-taints`).

이렇게 잡은 이유:
- **여유는 ClickHouse에 둡니다.** 화면 조회, 대시보드, 평가가 모두 여기로 몰리고, Langfuse 문서도 ClickHouse는 메모리를 늘릴수록 빨라진다고 합니다.
- **web·worker는 문서 최소치로 두고 대수로 늘립니다.** 문서는 2 CPU 컨테이너가 CPU 50%를 넘거나 수집 큐가 쌓이면 worker를 늘립니다. HPA에는 metrics-server가 필요하고, metrics-server가 없는 kind에서는 `<unknown>`으로 보입니다.
- **shard는 하나, replica는 셋.** Langfuse는 멀티 샤드를 지원하지 않고("Today, Langfuse does not support a multi-shard cluster"), 운영에는 replica 3개 이상을 권합니다. replica 수는 나중에 바꾸기 어렵습니다. replica마다 전체 사본이 있으므로 총 디스크는 replica 하나의 3배입니다.
- **Postgres와 Redis는 작게.** trace는 ClickHouse로 가고, Postgres에는 사용자, 설정, 프롬프트, 감사 로그, Redis에는 큐와 캐시만 있습니다.

### ClickHouse 디스크

디스크는 부하가 아니라 보관 기간으로 정합니다. [langfuse-ops-checks](../langfuse-ops-checks/README.md#07--티어별-clickhouse-자원)의 07(2026-11-04, 노트북, Langfuse 4.56.0, ClickHouse 26.8.22.13, trace당 관측치 4개, 각 입력 10 KB + 출력 1 KB)에서 **관측치당 디스크는 replica마다 약 2.0 KB**였고, 분당 1,000 / 2,000 / 4,000 trace에서 하루 10.6 / 21.7 / 43.1 GiB였습니다. 같은 시험에서 위 사양의 CPU와 메모리는 여유가 있었지만 디스크는 아니었습니다. 이전 기본값 512 GiB는 분당 4,000 trace에서 약 8일 분입니다.

replica당 = 하루 GiB × 보관 일수 ÷ 0.7(merge용 30 % 여유). `values-base.yaml`은 **분당 4,000 trace로 30일, 1,850 GiB**로 잡습니다. 총량 = replica당 × 3.

| 분당 trace | 하루 GiB | 7일 | 30일 | 90일 |
|---|---|---|---|---|
| 1,000 | 10.6 | 106 GiB | 454 GiB | 1,363 GiB |
| 2,000 | 21.7 | 217 GiB | 930 GiB | 2,790 GiB |
| 4,000 | 43.1 | 431 GiB | 1,847 GiB | 5,541 GiB |

- **다른 보관 기간이나 부하:** 표나 식으로 구한 값을 `values-base.yaml` 뒤에 겹치는 파일에서 `clickhouse.cluster.storage.size`로 지정합니다.
- **payload에 따라 달라집니다:** 2.0 KB는 11 KB 관측치 기준이고 prompt가 작으면 그만큼 덜 듭니다. 하루 GiB는 PoC 데이터로 다시 재세요.
- **설치 후 늘리기는 시험하지 않았습니다.** 여기 EKS 클래스는 `allowVolumeExpansion: true`입니다. AKS와 GKE 기본 클래스는 `kubectl get storageclass`로 확인하세요. 값을 바꿨을 때 clickhouse-operator 0.0.8이 기존 PVC를 늘리는지는 확인하지 않았고, 볼륨은 줄일 수 없습니다.
- **blob storage**는 원본 OTLP JSON을 따로 보관하며 여기서 크기를 잡지 않았습니다.

### 클라우드 파일이 정하는 것

| | AKS | EKS | GKE |
|---|---|---|---|
| 스토리지 클래스 | `managed-csi-premium`(기본 제공) | [storageclass-eks.yaml](storageclass-eks.yaml)의 `langfuse-gp3`(EBS CSI 드라이버, Auto Mode는 `ebs.csi.eks.amazonaws.com`) | `premium-rwo`(기본 제공 SSD PD) |
| Ingress | `ingressClassName: webapprouting.kubernetes.azure.com`(app routing 애드온) | 어노테이션 `kubernetes.io/ingress.class: alb`, IP 타깃, TLS는 ALB(ACM)에서 | 어노테이션 `kubernetes.io/ingress.class: gce`, GKE는 `ingressClassName`을 받지 않음 |
| Postgres | Flexible Server, `sslmode=require` | RDS / Aurora PostgreSQL, `sslmode=require` | Cloud SQL 사설 IP, `sslmode=require` |
| Redis | Azure Managed Redis, TLS 10000 | ElastiCache, 전송 중 암호화, 6379(Langfuse의 ElastiCache 예시) | Memorystore, 전송 중 암호화 6378, 인스턴스 서버 CA 마운트 |
| 오브젝트 | Blob Storage, 스토리지 계정 키, 컨테이너를 미리 생성 | S3, 서비스 계정의 IAM 역할(IRSA 또는 Pod Identity), 키 없음 | GCS, Workload Identity(차트가 pod의 서비스 계정으로 대체) |

클라우드 쪽 사실은 2026-11-04에 AKS, EKS, GKE, Memorystore 문서에서 확인했습니다. ElastiCache 포트는 AWS 문서가 아니라 Langfuse 문서의 예시입니다.

### 설치 (세 클라우드 공통)

클러스터마다 한 번: cert-manager와 ClickHouse operator.

```bash
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.20.2 \
  --namespace cert-manager --create-namespace --set crds.enabled=true
helm install clickhouse-operator oci://ghcr.io/clickhouse/clickhouse-operator-helm --version 0.0.8 \
  --namespace clickhouse-operator --create-namespace
```

그다음 노드 풀 두 개, 관리형 서비스, `langfuse` Secret([secret-example.yaml](secret-example.yaml))을 준비합니다. EKS에서는 `kubectl apply -f storageclass-eks.yaml`, GKE에서는 `memorystore-ca` Secret도 만듭니다. 차트는 처음에 세 단계로 설치합니다(이후 업그레이드는 `helm upgrade` 한 번).

```bash
CLOUD=aks   # 또는 eks, gke
H="helm upgrade --install langfuse langfuse/langfuse --version 2.2.1 -n langfuse -f values-base.yaml -f values-$CLOUD.yaml"
ZERO="--set langfuse.web.replicas=null --set langfuse.worker.replicas=null --set langfuse.web.hpa.enabled=false --set langfuse.worker.hpa.enabled=false"
$H $ZERO --set langfuse.replicas=0      # 1. ClickHouse와 Keeper만
kubectl -n langfuse wait --for=condition=Ready keepercluster/langfuse clickhousecluster/langfuse --timeout=15m
$H $ZERO --set langfuse.replicas=1      # 2. web pod 하나가 ClickHouse 마이그레이션 실행
kubectl -n langfuse rollout status deploy/langfuse-web --timeout=15m
$H                                      # 3. 전체 values
```

### 로컬 검증 실행

```bash
cd labs/v4/langfuse-k8s
./01-kind-up.sh         # 노드 풀 모양의 kind 클러스터, cert-manager, operator, 대체 서비스, Secret
./02-install.sh         # values-base.yaml + values-kind.yaml, 첫 설치는 단계로
./03-checks.sh          # 배치, 연결, 데이터 경로, 장애 조치 (확인 19개)
./04-render-clouds.sh   # base + 클라우드 파일마다: 렌더, server-side dry run, 필드 확인 (확인 42개)
./99-down.sh            # kind 클러스터 삭제
```

`kind`, `kubectl`, `helm`, `jq`, `openssl`, `uv`가 필요합니다. langfuse-hols compose 스택도 포트와 메모리를 쓰므로 먼저 멈춥니다. kind의 대체 서비스([standins.yaml](standins.yaml))는 Postgres 17.11, Redis 7.2.16, 오브젝트 스토리지 대신 Azurite 3.37.0입니다. Azurite는 차트의 Azure Blob 경로를 타고, 계정 키는 실행할 때마다 만듭니다.

### 확인한 것

`03-checks.sh`(2026-11-04): 19개 PASS
- **배치:** ClickHouse replica 3개가 서로 다른 `clickhouse` 노드 3대에 있고, web, worker, Keeper는 `app`에 있습니다. ClickHouseCluster와 KeeperCluster는 3/3 준비, HPA는 2–4와 2–6, PDB는 4개입니다(web·worker는 차트, ClickHouse·Keeper는 operator가 만듦).
- **클러스터:** `default`는 1 shard, 3 replica이고, `events_full`, `events_core`, `scores`는 `ReplicatedReplacingMergeTree`입니다.
- **연결:** `CLICKHOUSE_CLUSTER_ENABLED=true`, Postgres와 Redis는 대체 서비스, 오브젝트 스토리지는 Azure Blob 인터페이스입니다.
- **데이터 경로:** public API로 보낸 trace가 다시 읽히고, 그 행이 replica 3개 모두에 있고, 원본 이벤트는 Blob 컨테이너에, 프로젝트는 Postgres에 있습니다.
- **장애 조치:** ClickHouse replica 하나를 지운 상태에서도 새 trace가 수집되고 읽혔으며, 돌아온 replica에 그 행이 있었습니다. Keeper 하나를 지웠을 때도 같았습니다.

`04-render-clouds.sh`(2026-11-05, 디스크 변경 후 다시 실행. 512 GiB였던 2026-11-04 실행도 42개 통과): 42개 PASS, 클라우드마다 14개. AKS, EKS, GKE 각각에서 렌더된 객체를 kind API가 server-side dry run으로 받아들였습니다(EKS는 gp3 StorageClass 포함). base 값은 그대로 들어갔습니다. web·worker는 `app`에 2 CPU / 4 GiB이고 대수는 HPA가 정하며, liveness 대기 300초, ClickHouse는 taint 걸린 풀에 3 replica × 6 CPU / 24 GiB / 1,850 GiB, Keeper 3, 클러스터 모드입니다. 클라우드 파일이 정한 값도 의도대로였습니다. 스토리지 클래스, ingress 클래스나 어노테이션, `rediss://` 포트(10000, 6379, GKE는 CA 경로와 함께 6378), 오브젝트 스토리지 인터페이스(정적 키는 AKS만), EKS와 GKE의 워크로드 아이덴티티 어노테이션입니다.

### 알아 둘 것

- **버킷이나 컨테이너는 미리 만듭니다.** 차트 문서는 없는 컨테이너를 Langfuse가 만들려고 시도한다고 하지만, Langfuse 4.70.1은 만들지 않았습니다(Azure Blob 경로, 2026-11-03). 이벤트 PUT이 모두 404였고, OTLP 수집은 HTTP 500(`Failed to upload JSON to Azure Blob Storage`)이었습니다. IaC로 하듯, [01-kind-up.sh](01-kind-up.sh)가 미리 만듭니다.
- **첫 기동에는 마이그레이션할 시간을 줍니다.** 첫 설치 두 번이 `Dirty database version 5`로 끝났습니다. 마이그레이션 상태가 중간에 멈춘 채 남았고, web은 계속 재시작했습니다. pod 이벤트에 이유가 있었습니다. `Container langfuse-web failed liveness probe, will be restarted`. 첫 기동은 Postgres 마이그레이션 461개와 replica 3개의 ClickHouse 마이그레이션을 적용하는데, 이것이 차트 기본 liveness 여유(20초 + 10초 × 3, web에는 startup probe 없음)보다 오래 걸립니다. `values-base.yaml`은 `livenessProbe.initialDelaySeconds: 300`을 두고, [02-install.sh](02-install.sh)는 첫 설치를 단계로 나눕니다. 데이터 저장소부터 띄워 `ClickHouseCluster`와 `KeeperCluster`의 Ready를 기다리고(Keeper가 뜰 때까지 ClickHouse가 Keeper 연결 오류 exit 231로 몇 번 재시작함), web pod 하나로 마이그레이션한 뒤 전체 values를 적용합니다.
- **anti-affinity에는 operator의 라벨이 필요합니다.** clickhouse-operator 0.0.8은 pod에 `clickhouse.com/role=clickhouse-server`(Keeper는 `clickhouse-keeper`)를 붙이고, values가 이 라벨을 씁니다.
- **HPA를 켜면 차트가 `spec.replicas`를 빼고 렌더링합니다.** HPA 최소값(2)이 하한입니다.
- **EKS의 Redis 사용자는 `default`입니다.** 차트가 base 값으로 `rediss://default:…@…:6379`를 만들고, ElastiCache AUTH 토큰 방식은 이를 받습니다. Azure Managed Redis와 Memorystore는 키만 씁니다(`username: null`).
- **Azurite에서만:** 클러스터 내부 hostname에는 `--disableProductStyleUrl`이 필요합니다. 없으면 Azurite가 `azurite.standins…`를 `<account>.<host>`로 읽어 400을 돌려줍니다.
- **Langfuse 버전:** 차트는 Langfuse 4.70.1을 띄웁니다. compose 실습의 고정 버전(4.56.0)보다 새 버전입니다.

### 실행하지 않은 것

- AKS, EKS, GKE 클러스터와 관리형 서비스, ingress 컨트롤러, 로드밸런서, 디스크(렌더된 필드를 Kubernetes API로만 확인)
- 실제 클라우드 IAM에서의 워크로드 아이덴티티(IRSA, Pod Identity, GKE Workload Identity), Memorystore CA
- 부하: 처리량이나 지연은 측정하지 않았습니다. 사이징은 벤치마크가 아니라 문서 최소치에 여유를 더한 값입니다.
- 클라우드의 디스크: 1,850 GiB는 11 KB 관측치로 잰 07의 노트북 측정에 근거합니다([ClickHouse 디스크](#clickhouse-디스크)). 하루 GiB는 PoC 데이터로 다시 재세요.

### 파일

| 파일 | 내용 |
|---|---|
| [values-base.yaml](values-base.yaml) | 사이징과 배치, 모든 클라우드 공통 |
| [values-aks.yaml](values-aks.yaml) · [values-eks.yaml](values-eks.yaml) · [values-gke.yaml](values-gke.yaml) | 클라우드마다 더하는 부분 |
| [storageclass-eks.yaml](storageclass-eks.yaml) | EKS용 gp3 StorageClass |
| [values-kind.yaml](values-kind.yaml) | kind용 overlay: 사양, 대체 서비스 주소, 스토리지 클래스, headless init |
| [secret-example.yaml](secret-example.yaml) | `langfuse` Secret의 키 |
| [kind-config.yaml](kind-config.yaml) · [standins.yaml](standins.yaml) | 노드 풀 모양의 kind 클러스터, Postgres, Redis, Azurite |
| `01`–`04`, `99` | 설정, 설치, 확인, 클라우드 렌더 검사, 정리 |
