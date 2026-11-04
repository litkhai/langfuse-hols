# Langfuse on managed Kubernetes (AKS, EKS, GKE): Helm values with room to spare, verified on kind

[English](#english) | [한국어](#한국어)

---

## English

**Verified end to end on 2026-11-04** with the official chart **langfuse 2.2.1** (Langfuse 4.70.1, ClickHouse 26.8.36.3), clickhouse-operator 0.0.8 and cert-manager v1.20.2, from a deleted kind cluster with a staged first install (kind 0.33.0, Kubernetes v1.37.0; Docker 29.9.2 with 12 CPU / 16 GiB): [03-checks.sh](03-checks.sh) passed 19 checks on `values-base.yaml` + the kind overlay, and [04-render-clouds.sh](04-render-clouds.sh) 42 (14 per cloud) on `values-base.yaml` + each cloud file. On 2026-11-03 an injected fault (ClickHouse replicas 3 → 2) failed the render check. **Not run on AKS, EKS or GKE**, nor against their managed services (no spending): each cloud file is rendered and validated against a real Kubernetes API. The same day the install also ran entirely from a private registry that needs a login, with the nodes cut off from public registries ([below](#install-from-a-private-registry-a-regulated-customer-on-aks--acr)).

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
| ClickHouse | 1 shard × 3 replicas | 6 CPU / 24 GiB (limit 26 GiB), 512 GiB SSD | `workload=clickhouse`, 1 per node | 2 CPU / 8 GiB; 16 GiB+ for larger deployments |
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

`04-render-clouds.sh` (2026-11-04): 42 PASS, 14 per cloud. For each of AKS, EKS and GKE the rendered objects are accepted by the kind API in a server-side dry run (the EKS run includes the gp3 StorageClass), the base values come through unchanged (web and worker 2 CPU / 4 GiB on `app` with replicas owned by the HPA, liveness delay 300 s, ClickHouse 3 replicas × 6 CPU / 24 GiB / 512 GiB on the tainted pool, Keeper 3, cluster mode on), and the cloud file's choices land as intended: storage class, ingress class or annotation, `rediss://` port (10000, 6379, 6378 with the CA path on GKE), object storage interface with a static key only on AKS, and the workload identity annotation on EKS and GKE.

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
- Disk size: 512 GiB per replica is a placeholder; size it from daily observations × average size × retention, measured on PoC data.
- Private registry: ACR, `az acr import`, `az aks update --attach-acr`, ACR anonymous-pull settings, ACR cache rules, Azure Firewall egress and network-isolated AKS (described from the docs); the bundled sub-charts behind a private registry (render only); finishing an image bump after mirroring it (Docker Hub limit); a fault injected into 06-private-registry-checks.sh (a public-image pod among the lab's pods): the kind API stopped answering (etcd timeouts) once other projects' containers started on the same Docker VM, at about 14:40 UTC. Its negatives so far are the three pull controls in 05 and the stalled 4.71.0 rollout.

### Install from a private registry (a regulated customer on AKS + ACR)

**Verified on kind on 2026-11-04:** the same install, with every image and every chart from a private registry that needs a login, and nodes that cannot pull from anywhere else. [05-private-registry.sh](05-private-registry.sh) passed 6 checks, [03-checks.sh](03-checks.sh) 19, [06-private-registry-checks.sh](06-private-registry-checks.sh) 7. Conditions: chart langfuse 2.2.1, cert-manager v1.20.2, clickhouse-operator-helm 0.0.8; registry `registry:2.8.3` with htpasswd and TLS from a lab CA; crane v0.20.3; kind 0.33.0 (Kubernetes v1.37.0, containerd 2.3.4); Docker 29.9.2 with 12 CPU / 16 GiB, shared with another compose stack and other projects' containers (their CPU use may lengthen the times). Times: 05 12 min 23 s (mostly mirroring 4.0 GB, every platform), 01 3 min 16 s, 02 4 min 26 s, 03 36 s. **Azure itself was not run** (no spending): ACR, `az acr import` and `--attach-acr` are described from the Azure docs below.

```bash
cd labs/v4/langfuse-k8s
./05-private-registry.sh                 # CA, registry, mirror, kind cluster with locked nodes, pull Secret, controls
PRIVATE_REGISTRY=1 ./01-kind-up.sh       # cert-manager, operator, stand-ins: charts and images from the registry
PRIVATE_REGISTRY=1 ./02-install.sh       # oci://…/charts/langfuse + values-private-registry.yaml
./03-checks.sh                           # the same 19 checks
./06-private-registry-checks.sh          # nothing came from outside the registry
./99-down.sh; docker rm -f langfuse-k8s-registry; docker volume rm langfuse-k8s-registry-data
```

**How it is shaped.** `registry:2` stands for ACR: it runs on the kind Docker network as `privreg.lab.test:443` (the helm client reaches it as `localhost:5443`), answers 401 without the htpasswd user, and its certificate is signed by a CA made per run. Images are mirrored to `<registry>/<source reference>`, the source host kept as the first path segment (`privreg.lab.test/docker.io/clickhouse/clickhouse-server:26.8.36.3`), with every platform, so the digest stays the source's. On every node containerd reads `/etc/containerd/certs.d`: `_default` and docker.io, ghcr.io, quay.io, registry.k8s.io, mcr.microsoft.com, docker.langfuse.com and gcr.io point at a dead endpoint (`127.0.0.1:9`); only `privreg.lab.test` has a real host, trusted through the lab CA. A missed image therefore fails with ImagePullBackOff instead of coming from the internet. The pull Secret `regcred` (`kubernetes.io/dockerconfigjson`) is created in every namespace that pulls.

**The image list (14 images, 3 charts).** From `helm template` with this lab's values, the two prerequisite charts, [standins.yaml](standins.yaml) and [01-kind-up.sh](01-kind-up.sh); the list with its sources is [private-registry-images.txt](private-registry-images.txt). Digests are the index (multi-platform) digests on 2026-11-04, the same in the source and the mirror:

| Source reference (image unless marked) | Used by | Digest (source = mirror) |
|---|---|---|
| `docker.langfuse.com/langfuse/langfuse:4.70.1` | langfuse-web (chart); blob-init pod (01-kind-up.sh) | `sha256:71b04842ecff8fe0dd15c7bbb1acd6e0555735e393a8108c43feb4b8d0adf9e6` |
| `docker.langfuse.com/langfuse/langfuse-worker:4.70.1` | langfuse-worker (chart) | `sha256:3976a73de84a29999ff4573398e240127b8a92012421ce5eec61cd57f087d8ca` |
| `docker.io/clickhouse/clickhouse-server:26.8.36.3` | ClickHouseCluster CR (chart) → operator → StatefulSets, version-probe Job | `sha256:d426d2f612e1e189c90f9a3f8dcd85a03c6851273833817a296bb327e63aa7a7` |
| `docker.io/clickhouse/clickhouse-keeper:26.8.36.3` | KeeperCluster CR (chart) → operator → StatefulSets | `sha256:a847f2f30ac6950828d6f2413828adeeee4c9d261cb88f88eb6f1606a5f5a062` |
| `ghcr.io/clickhouse/clickhouse-operator:v0.0.8` | clickhouse-operator chart | `sha256:80ff894a42fbc34fc40016776a5ba340b126b2ff408011a0af375d18c0dc8e44` |
| `quay.io/jetstack/cert-manager-controller:v1.20.2` | cert-manager chart | `sha256:fe0623d7d04a382c888f03343a3a2da716e0d96ad3d5d790c0ebcbcb2a4329a5` |
| `quay.io/jetstack/cert-manager-webhook:v1.20.2` | cert-manager chart | `sha256:baf651128b9f05c426cbd5e60e2036bf382c99ca270f49d0757d6f7d2452f4e5` |
| `quay.io/jetstack/cert-manager-cainjector:v1.20.2` | cert-manager chart | `sha256:6f5a644135887b2aa7d5cc145072fa56421560e3586ff1f184358022d490f4e1` |
| `quay.io/jetstack/cert-manager-startupapicheck:v1.20.2` | cert-manager chart, post-install hook Job | `sha256:4e2a69b4a0cc9627905bbeecf720f95d5153ca39cacdab923d2748e73556792b` |
| `quay.io/jetstack/cert-manager-acmesolver:v1.20.2` | cert-manager controller argument (pulled only for ACME HTTP-01) | `sha256:cfa55e9c3dcfc6a3cba97575748c1549b04a30fd14d88a2fcb9e2dddef415e2f` |
| `docker.io/postgres:17.11` | stand-in (standins.yaml) | `sha256:3b0cda93be7c8dba2ed484d19393d93845dc3dafb88973e248ba8e6d99d784e1` |
| `docker.io/redis:7.2.16` | stand-in (standins.yaml) | `sha256:1009f15ccd9ed271996d1c65745a1ab1dadedea188feb3f1ab938602a32e50a3` |
| `mcr.microsoft.com/azure-storage/azurite:3.37.0` | stand-in (standins.yaml) | `sha256:830430c1da1a2d537e08f3e6764dd1f5ae00cf0346bcaf625b968ec3f0971fd5` |
| `docker.io/library/busybox:1.37.0` | pull controls in 05-private-registry.sh only | `sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec` |
| chart `oci://quay.io/jetstack/charts/cert-manager:v1.20.2` | 01-kind-up.sh | `sha256:294a761ca972ea11ae79b9219960ca13a5337a1cbb550604c151586d266159eb` |
| chart `oci://ghcr.io/clickhouse/clickhouse-operator-helm:0.0.8` | 01-kind-up.sh | `sha256:61d97bb43a16859f485af1099251fc591b527a4c01013e6de355be11a80fbc9c` |
| langfuse chart 2.2.1 (classic Helm repository) | 02-install.sh: pushed as `oci://<registry>/charts/langfuse`; new OCI digest | `sha256:94bdf57a8f4c24db0b173c837be7c56c498ed4dfe1fdb6b1de79b255a0c49bff` (tgz `sha256:9ddb410ffe22a2cba3fc95c9e8fa7e0e85e3467fe5d4cd9386f8d5b7c32a12c3`) |

The langfuse chart renders no init containers and no hooks for these values; cert-manager renders one hook Job (startupapicheck). kind's own system images (kube-*, etcd, coredns, kindnetd, local-path-provisioner, pause) are preloaded in the node image and never pulled; on AKS the platform pulls its system images itself (see below).

**The values keys that were needed.**

| Chart | Keys | Notes |
|---|---|---|
| langfuse 2.2.1 ([values-private-registry.yaml](values-private-registry.yaml)) | `langfuse.web.image.repository`, `langfuse.worker.image.repository`, `clickhouse.cluster.image.repository`, `clickhouse.keeper.image.repository`; `langfuse.image.pullSecrets`, `clickhouse.cluster.image.pullSecrets`, `clickhouse.keeper.image.pullSecrets` | four repositories with the registry host in them, three pull-Secret keys |
| cert-manager v1.20.2 | `imageRegistry=privreg.lab.test/quay.io` (with the default `imageNamespace: jetstack`), `global.imagePullSecrets[0].name=regcred` | covers controller, webhook, cainjector, the startupapicheck hook and the acmesolver argument |
| clickhouse-operator-helm 0.0.8 | `global.imageRegistry=privreg.lab.test`, `manager.imagePullSecrets[0].name=regcred` | the prefix goes before the whole repository: `…/ghcr.io/clickhouse/clickhouse-operator` |
| stand-ins, blob-init pod | the image prefix, and `imagePullSecrets` on the namespace's default ServiceAccount | not charts |

**Where a global setting was not honoured, and the workaround.**

- **The langfuse chart has no `global.imageRegistry` and no global pull Secret.** In 2.2.1 the only `global` values are the sub-charts'. Set alone, `global.imageRegistry` leaves web, worker, ClickHouse and Keeper on their public references (render, 2026-11-04). Workaround: the four `repository` keys with the registry host in them, and the three `pullSecrets` keys ([values-private-registry.yaml](values-private-registry.yaml)).
- **ClickHouse and Keeper default to a repository with no host** (`clickhouse/clickhouse-server`), which containerd reads as Docker Hub. The operator takes the repository as given: with `privreg.lab.test/docker.io/clickhouse/clickhouse-server` the three servers, the three Keepers and the operator's own `langfuse-clickhouse-version-probe-*` Job all pulled from the registry with the CR's pull Secret. That Job is created by the operator at run time, so `helm template` does not show it; it reuses the CR's image and `imagePullSecrets`.
- **The sub-charts disagree** (off in this lab; render only). valkey and seaweedfs honour `global.imageRegistry` and `global.imagePullSecrets`, the seaweedfs bucket hook too. The postgres sub-chart (groundhog2k 1.6.3) ignores both: use `postgresql.image.registry` and `postgresql.imagePullSecrets`. valkey's `helm test` pod has no `imagePullSecrets`, so `helm test` cannot pull behind a pull Secret (it can with `--attach-acr`).
- **No Bitnami images.** Chart 2.2.1 has no Bitnami sub-chart (postgres is groundhog2k, Redis is valkey, object storage is seaweedfs, ClickHouse comes from the operator), so the Bitnami catalog move to `bitnamilegacy` does not affect it.
- **The prerequisites prefix differently.** cert-manager's `imageRegistry` replaces `quay.io` (a path is allowed); clickhouse-operator's `global.imageRegistry` is put in front of the whole `ghcr.io/clickhouse/clickhouse-operator`. Mirroring under the source host serves both; a flat layout would need `manager.image.repository` for the operator.
- **Web and worker pull with `imagePullPolicy: Always` by default.** Every pod start (restart, HPA scale-out, node drain) asks the registry, so a registry outage stops new pods. `langfuse.image.pullPolicy: IfNotPresent` with tags you never overwrite avoids that; the lab keeps the default.
- **Docker Hub limits the mirror step, not the cluster.** Mirroring one more tag at 14:33 UTC (after this run's copies) got `429 TOOMANYREQUESTS` from docker.langfuse.com, which serves from Docker Hub. Mirror with a Docker Hub login (`crane auth login`, `az acr import --username/--password`).
- **kind only: containerd reads `certs.d` only if the cluster was created with `config_path`.** The kind 0.33 node image leaves it empty, so 05-private-registry.sh creates the cluster with that patch and refuses an existing cluster without it.

**Upgrade path (an image or chart bump; a CVE patch is the same).**

1. Render the new version with your values and list its images: `helm template … | grep -E 'image:|repository:|tag:'`, plus the operator CRs' `repository`/`tag`. Compare with [private-registry-images.txt](private-registry-images.txt); only new references need mirroring. A patch that changes one tag (say ClickHouse 26.8.36.3 → a newer 26.8 build) is one line.
2. Mirror the new references, keeping digests: `crane cp <src> <registry>/<src>`, or on ACR `az acr import --name <acr> --source <src> --image <src path>:<tag>` (not run). A new chart version: `helm pull` + `helm push` for langfuse (a classic repository), `crane cp`/`az acr import` for the OCI charts.
3. Change the pin: `--version` of the chart, or the tag key (`langfuse.image.tag`, `clickhouse.cluster.image.tag`, `clickhouse.keeper.image.tag`), and `helm upgrade` with the same values.
4. Run `06-private-registry-checks.sh` (or its idea: every `imageID` from the registry and equal to the source digest). A reference you missed does not slip through: the nodes cannot reach the source, so the pod stays in ImagePullBackOff and the rollout stops with the old pods still serving.
5. Keep the old tags in the registry until the rollback window is over.

Measured 2026-11-04 (same conditions): `langfuse.worker.image.tag=4.71.0` set without mirroring that tag. The new worker pod stayed in ErrImagePull (`NotFound` from `privreg.lab.test`, nothing tried elsewhere), the rollout stopped at 1 of 2 updated, and the two 4.70.1 workers kept serving; `helm rollback` restored the release. The second half (mirror 4.71.0, the rollout finishes) was **not run**: that mirror hit the Docker Hub limit (below).

**On AKS + ACR (from the Azure docs, not run).**
- `az acr import --name <acr> --source docker.io/clickhouse/clickhouse-server:26.8.36.3 --image docker.io/clickhouse/clickhouse-server:26.8.36.3` copies a multi-arch image server side, keeping the digest; Docker Hub sources take `--username/--password` against rate limits. ACR cache rules (pull-through cache) are the alternative to importing.
- `az aks update -n <aks> -g <rg> --attach-acr <acr>` gives the kubelet identity AcrPull; the nodes then pull without any `imagePullSecrets`, and the pullSecrets lines in the values can go. With a token or service principal instead, they stay, as on kind.
- ACR does not allow anonymous pull unless `az acr update --anonymous-pull-enabled true` is set (Standard and Premium); off is the default, which is what `registry:2` with htpasswd stands for here.
- Helm charts in ACR are OCI artifacts: `helm registry login <acr>.azurecr.io` (token from `az acr login --name <acr> --expose-token`), `helm push langfuse-2.2.1.tgz oci://<acr>.azurecr.io/charts`, `helm install langfuse oci://<acr>.azurecr.io/charts/langfuse --version 2.2.1`.
- Blocking public registries on AKS is egress control (Azure Firewall or a UDR), not containerd config. AKS still needs `mcr.microsoft.com` for its own system images, unless the cluster is network isolated, where they come from a private ACR cache.

### Files

| File | What |
|---|---|
| [values-base.yaml](values-base.yaml) | sizing and placement, the same on every cloud |
| [values-aks.yaml](values-aks.yaml) · [values-eks.yaml](values-eks.yaml) · [values-gke.yaml](values-gke.yaml) | what each cloud adds |
| [storageclass-eks.yaml](storageclass-eks.yaml) | gp3 StorageClass for EKS |
| [values-kind.yaml](values-kind.yaml) | overlay for kind: sizes, stand-in addresses, storage class, headless init |
| [secret-example.yaml](secret-example.yaml) | the keys of the `langfuse` Secret |
| [kind-config.yaml](kind-config.yaml) · [standins.yaml](standins.yaml) | kind cluster shaped like the node pools; Postgres, Redis, Azurite |
| [values-private-registry.yaml](values-private-registry.yaml) | every image of the chart from a private registry, with its pull Secret |
| [private-registry-images.txt](private-registry-images.txt) · [private-registry.inc.sh](private-registry.inc.sh) | the images and charts to mirror; the registry's names for the scripts |
| `01`–`04`, `99` | setup, install, checks, cloud render checks, teardown |
| `05`, `06` | private registry: registry, mirror, locked nodes, pull controls; checks that nothing came from elsewhere |

---

## 한국어

**2026-11-04에 처음부터 끝까지 검증**했습니다. 공식 차트 **langfuse 2.2.1**(Langfuse 4.70.1, ClickHouse 26.8.36.3), clickhouse-operator 0.0.8, cert-manager v1.20.2 기준입니다. kind 클러스터를 지우고 첫 설치를 단계로 나눠 진행했습니다(kind 0.33.0, Kubernetes v1.37.0, Docker 29.9.2에 12 CPU / 16 GiB). [03-checks.sh](03-checks.sh)는 `values-base.yaml` + kind overlay로 확인 19개, [04-render-clouds.sh](04-render-clouds.sh)는 `values-base.yaml` + 클라우드 파일마다 14개씩 모두 42개를 통과했습니다. 2026-11-03에는 일부러 넣은 결함(ClickHouse replica 3 → 2)을 렌더 검사가 잡았습니다. **AKS, EKS, GKE와 그 관리형 서비스에서는 실행하지 않았습니다**(비용 없음). 클라우드 파일마다 렌더링해서 실제 Kubernetes API로 검증했습니다. 같은 날, 로그인이 필요한 사설 레지스트리에서만 받고 노드는 공개 레지스트리에 닿지 못하게 한 설치도 진행했습니다([아래](#사설-레지스트리에서-설치-aks--acr을-쓰는-규제-업종-고객)).

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
| ClickHouse | 1 shard × 3 replica | 6 CPU / 24 GiB(limit 26 GiB), SSD 512 GiB | `workload=clickhouse`, 노드당 1개 | 2 CPU / 8 GiB, 큰 배포는 16 GiB 이상 |
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

`04-render-clouds.sh`(2026-11-04): 42개 PASS, 클라우드마다 14개. AKS, EKS, GKE 각각에서 렌더된 객체를 kind API가 server-side dry run으로 받아들였습니다(EKS는 gp3 StorageClass 포함). base 값은 그대로 들어갔습니다. web·worker는 `app`에 2 CPU / 4 GiB이고 대수는 HPA가 정하며, liveness 대기 300초, ClickHouse는 taint 걸린 풀에 3 replica × 6 CPU / 24 GiB / 512 GiB, Keeper 3, 클러스터 모드입니다. 클라우드 파일이 정한 값도 의도대로였습니다. 스토리지 클래스, ingress 클래스나 어노테이션, `rediss://` 포트(10000, 6379, GKE는 CA 경로와 함께 6378), 오브젝트 스토리지 인터페이스(정적 키는 AKS만), EKS와 GKE의 워크로드 아이덴티티 어노테이션입니다.

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
- 디스크 크기: replica당 512 GiB는 자리표시자입니다. 하루 observation 수 × 평균 크기 × 보존 기간을 PoC 데이터로 실측해 정합니다.
- 사설 레지스트리: ACR, `az acr import`, `az aks update --attach-acr`, ACR 익명 pull 설정, ACR 캐시 규칙, Azure Firewall egress, network isolated AKS(문서 기준으로 적음). 사설 레지스트리 뒤의 내장 sub-chart(렌더만). 이미지 버전 올리기를 미러링 후 끝까지 진행(Docker Hub 제한). 06-private-registry-checks.sh에 결함 넣기(실습 pod 사이에 공개 이미지 pod 하나): 같은 Docker VM에서 다른 프로젝트 컨테이너가 뜬 14:40 UTC쯤부터 kind API가 응답하지 않았습니다(etcd timeout). 지금까지의 음성 대조는 05의 pull 대조 실험 3개와 멈춘 4.71.0 rollout입니다.

### 사설 레지스트리에서 설치 (AKS + ACR을 쓰는 규제 업종 고객)

**2026-11-04 kind에서 검증:** 같은 설치를, 모든 이미지와 차트를 로그인이 필요한 사설 레지스트리에서 받고, 노드는 다른 곳에서 받을 수 없게 해서 진행했습니다. [05-private-registry.sh](05-private-registry.sh)는 확인 6개, [03-checks.sh](03-checks.sh)는 19개, [06-private-registry-checks.sh](06-private-registry-checks.sh)는 7개를 통과했습니다. 조건: 차트 langfuse 2.2.1, cert-manager v1.20.2, clickhouse-operator-helm 0.0.8, 레지스트리 `registry:2.8.3`(htpasswd, 실습용 CA로 서명한 TLS), crane v0.20.3, kind 0.33.0(Kubernetes v1.37.0, containerd 2.3.4), Docker 29.9.2에 12 CPU / 16 GiB(다른 compose 스택, 다른 프로젝트 컨테이너와 함께 사용. 이들의 CPU 사용으로 시간이 늘었을 수 있음). 걸린 시간: 05는 12분 23초(대부분 모든 플랫폼 4.0 GB 미러링), 01은 3분 16초, 02는 4분 26초, 03은 36초. **Azure에서는 실행하지 않았습니다**(비용 없음). ACR, `az acr import`, `--attach-acr`은 아래에 Azure 문서 기준으로 적었습니다.

```bash
cd labs/v4/langfuse-k8s
./05-private-registry.sh                 # CA, 레지스트리, 미러링, 노드를 잠근 kind 클러스터, pull Secret, 대조 실험
PRIVATE_REGISTRY=1 ./01-kind-up.sh       # cert-manager, operator, 대체 서비스: 차트와 이미지를 레지스트리에서
PRIVATE_REGISTRY=1 ./02-install.sh       # oci://…/charts/langfuse + values-private-registry.yaml
./03-checks.sh                           # 같은 확인 19개
./06-private-registry-checks.sh          # 레지스트리 밖에서 받은 것이 없는지
./99-down.sh; docker rm -f langfuse-k8s-registry; docker volume rm langfuse-k8s-registry-data
```

**구성.** `registry:2`가 ACR 역할을 합니다. kind Docker 네트워크에서 `privreg.lab.test:443`으로 뜨고(helm 클라이언트는 `localhost:5443`으로 접근), htpasswd 사용자 없이는 401을 돌려주며, 인증서는 실행할 때마다 만드는 CA가 서명합니다. 이미지는 `<registry>/<원본 참조>`로 미러링합니다. 원본 호스트를 경로 첫 부분으로 남기고(`privreg.lab.test/docker.io/clickhouse/clickhouse-server:26.8.36.3`), 모든 플랫폼을 복사하므로 digest가 원본과 같습니다. 모든 노드의 containerd는 `/etc/containerd/certs.d`를 읽습니다. `_default`와 docker.io, ghcr.io, quay.io, registry.k8s.io, mcr.microsoft.com, docker.langfuse.com, gcr.io는 죽은 엔드포인트(`127.0.0.1:9`)를 가리키고, 실제 호스트가 있는 곳은 실습 CA를 신뢰하는 `privreg.lab.test`뿐입니다. 그래서 빠뜨린 이미지는 인터넷에서 조용히 받아지지 않고 ImagePullBackOff로 실패합니다. pull Secret `regcred`(`kubernetes.io/dockerconfigjson`)는 이미지를 받는 모든 namespace에 만듭니다.

**이미지 목록(이미지 14개, 차트 3개).** 이 실습의 values로 `helm template`한 결과, 선행 차트 두 개, [standins.yaml](standins.yaml), [01-kind-up.sh](01-kind-up.sh)에서 뽑았습니다. 출처와 함께 [private-registry-images.txt](private-registry-images.txt)에 있습니다. digest는 2026-11-04의 index(멀티 플랫폼) digest이고, 원본과 미러가 같습니다.

| 원본 참조(표시 없으면 이미지) | 쓰는 곳 | Digest(원본 = 미러) |
|---|---|---|
| `docker.langfuse.com/langfuse/langfuse:4.70.1` | langfuse-web(차트), blob-init pod(01-kind-up.sh) | `sha256:71b04842ecff8fe0dd15c7bbb1acd6e0555735e393a8108c43feb4b8d0adf9e6` |
| `docker.langfuse.com/langfuse/langfuse-worker:4.70.1` | langfuse-worker(차트) | `sha256:3976a73de84a29999ff4573398e240127b8a92012421ce5eec61cd57f087d8ca` |
| `docker.io/clickhouse/clickhouse-server:26.8.36.3` | ClickHouseCluster CR(차트) → operator → StatefulSet, version-probe Job | `sha256:d426d2f612e1e189c90f9a3f8dcd85a03c6851273833817a296bb327e63aa7a7` |
| `docker.io/clickhouse/clickhouse-keeper:26.8.36.3` | KeeperCluster CR(차트) → operator → StatefulSet | `sha256:a847f2f30ac6950828d6f2413828adeeee4c9d261cb88f88eb6f1606a5f5a062` |
| `ghcr.io/clickhouse/clickhouse-operator:v0.0.8` | clickhouse-operator 차트 | `sha256:80ff894a42fbc34fc40016776a5ba340b126b2ff408011a0af375d18c0dc8e44` |
| `quay.io/jetstack/cert-manager-controller:v1.20.2` | cert-manager 차트 | `sha256:fe0623d7d04a382c888f03343a3a2da716e0d96ad3d5d790c0ebcbcb2a4329a5` |
| `quay.io/jetstack/cert-manager-webhook:v1.20.2` | cert-manager 차트 | `sha256:baf651128b9f05c426cbd5e60e2036bf382c99ca270f49d0757d6f7d2452f4e5` |
| `quay.io/jetstack/cert-manager-cainjector:v1.20.2` | cert-manager 차트 | `sha256:6f5a644135887b2aa7d5cc145072fa56421560e3586ff1f184358022d490f4e1` |
| `quay.io/jetstack/cert-manager-startupapicheck:v1.20.2` | cert-manager 차트, post-install hook Job | `sha256:4e2a69b4a0cc9627905bbeecf720f95d5153ca39cacdab923d2748e73556792b` |
| `quay.io/jetstack/cert-manager-acmesolver:v1.20.2` | cert-manager controller 인자(ACME HTTP-01에서만 받음) | `sha256:cfa55e9c3dcfc6a3cba97575748c1549b04a30fd14d88a2fcb9e2dddef415e2f` |
| `docker.io/postgres:17.11` | 대체 서비스(standins.yaml) | `sha256:3b0cda93be7c8dba2ed484d19393d93845dc3dafb88973e248ba8e6d99d784e1` |
| `docker.io/redis:7.2.16` | 대체 서비스(standins.yaml) | `sha256:1009f15ccd9ed271996d1c65745a1ab1dadedea188feb3f1ab938602a32e50a3` |
| `mcr.microsoft.com/azure-storage/azurite:3.37.0` | 대체 서비스(standins.yaml) | `sha256:830430c1da1a2d537e08f3e6764dd1f5ae00cf0346bcaf625b968ec3f0971fd5` |
| `docker.io/library/busybox:1.37.0` | 05-private-registry.sh의 대조 실험만 | `sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec` |
| 차트 `oci://quay.io/jetstack/charts/cert-manager:v1.20.2` | 01-kind-up.sh | `sha256:294a761ca972ea11ae79b9219960ca13a5337a1cbb550604c151586d266159eb` |
| 차트 `oci://ghcr.io/clickhouse/clickhouse-operator-helm:0.0.8` | 01-kind-up.sh | `sha256:61d97bb43a16859f485af1099251fc591b527a4c01013e6de355be11a80fbc9c` |
| langfuse 차트 2.2.1(일반 Helm 저장소) | 02-install.sh: `oci://<registry>/charts/langfuse`로 push, 새 OCI digest | `sha256:94bdf57a8f4c24db0b173c837be7c56c498ed4dfe1fdb6b1de79b255a0c49bff` (tgz `sha256:9ddb410ffe22a2cba3fc95c9e8fa7e0e85e3467fe5d4cd9386f8d5b7c32a12c3`) |

이 values에서 langfuse 차트는 init container도 hook도 렌더링하지 않습니다. cert-manager는 hook Job 하나(startupapicheck)를 렌더링합니다. kind 자체의 시스템 이미지(kube-*, etcd, coredns, kindnetd, local-path-provisioner, pause)는 노드 이미지에 미리 들어 있어 받지 않습니다. AKS에서는 플랫폼이 시스템 이미지를 직접 받습니다(아래).

**필요했던 values 키.**

| 차트 | 키 | 비고 |
|---|---|---|
| langfuse 2.2.1 ([values-private-registry.yaml](values-private-registry.yaml)) | `langfuse.web.image.repository`, `langfuse.worker.image.repository`, `clickhouse.cluster.image.repository`, `clickhouse.keeper.image.repository`; `langfuse.image.pullSecrets`, `clickhouse.cluster.image.pullSecrets`, `clickhouse.keeper.image.pullSecrets` | 레지스트리 호스트를 넣은 repository 4개, pull Secret 키 3개 |
| cert-manager v1.20.2 | `imageRegistry=privreg.lab.test/quay.io`(기본 `imageNamespace: jetstack`과 함께), `global.imagePullSecrets[0].name=regcred` | controller, webhook, cainjector, startupapicheck hook, acmesolver 인자까지 |
| clickhouse-operator-helm 0.0.8 | `global.imageRegistry=privreg.lab.test`, `manager.imagePullSecrets[0].name=regcred` | 접두사가 repository 전체 앞에 붙음: `…/ghcr.io/clickhouse/clickhouse-operator` |
| 대체 서비스, blob-init pod | 이미지 접두사, namespace 기본 ServiceAccount의 `imagePullSecrets` | 차트 아님 |

**전역 설정이 통하지 않은 곳과 우회 방법.**

- **langfuse 차트에는 `global.imageRegistry`도 전역 pull Secret도 없습니다.** 2.2.1에서 `global` 값은 sub-chart의 것뿐입니다. `global.imageRegistry`만 넣으면 web, worker, ClickHouse, Keeper는 공개 참조 그대로입니다(렌더, 2026-11-04). 우회: 레지스트리 호스트를 넣은 `repository` 키 4개와 `pullSecrets` 키 3개([values-private-registry.yaml](values-private-registry.yaml)).
- **ClickHouse와 Keeper의 기본 repository에는 호스트가 없습니다**(`clickhouse/clickhouse-server`). containerd는 이를 Docker Hub로 읽습니다. operator는 repository를 그대로 씁니다. `privreg.lab.test/docker.io/clickhouse/clickhouse-server`로 주자 서버 3개, Keeper 3개, operator가 만드는 `langfuse-clickhouse-version-probe-*` Job까지 CR의 pull Secret으로 레지스트리에서 받았습니다. 이 Job은 실행 중에 operator가 만들기 때문에 `helm template`에는 나오지 않고, CR의 이미지와 `imagePullSecrets`를 그대로 씁니다.
- **sub-chart끼리 다릅니다**(이 실습에서는 꺼짐, 렌더만). valkey와 seaweedfs는 `global.imageRegistry`와 `global.imagePullSecrets`를 따르고, seaweedfs의 버킷 hook도 따릅니다. postgres sub-chart(groundhog2k 1.6.3)는 둘 다 무시하므로 `postgresql.image.registry`와 `postgresql.imagePullSecrets`를 씁니다. valkey의 `helm test` pod에는 `imagePullSecrets`가 없어서, pull Secret을 쓰는 레지스트리에서는 `helm test`가 이미지를 받지 못합니다(`--attach-acr`이면 받음).
- **Bitnami 이미지는 없습니다.** 차트 2.2.1에는 Bitnami sub-chart가 없습니다(postgres는 groundhog2k, Redis는 valkey, 오브젝트 스토리지는 seaweedfs, ClickHouse는 operator). 그래서 Bitnami 카탈로그의 `bitnamilegacy` 이전과 상관없습니다.
- **선행 차트는 접두사를 붙이는 방식이 다릅니다.** cert-manager의 `imageRegistry`는 `quay.io`를 대체하고(경로 포함 가능), clickhouse-operator의 `global.imageRegistry`는 `ghcr.io/clickhouse/clickhouse-operator` 전체 앞에 붙습니다. 원본 호스트를 경로에 남기는 미러링이면 둘 다 맞고, 평평한 구조라면 operator에 `manager.image.repository`가 필요합니다.
- **web과 worker는 기본이 `imagePullPolicy: Always`입니다.** pod가 뜰 때마다(재시작, HPA 확장, 노드 drain) 레지스트리에 묻기 때문에, 레지스트리가 멈추면 새 pod도 못 뜹니다. 덮어쓰지 않는 태그와 함께 `langfuse.image.pullPolicy: IfNotPresent`를 쓰면 피할 수 있습니다. 실습은 기본값 그대로입니다.
- **Docker Hub 제한은 클러스터가 아니라 미러링 단계에 걸립니다.** 14:33 UTC에 태그 하나를 더 미러링하자(이번 실행의 복사 뒤) Docker Hub를 거치는 docker.langfuse.com이 `429 TOOMANYREQUESTS`를 돌려줬습니다. Docker Hub에 로그인해서 미러링합니다(`crane auth login`, `az acr import --username/--password`).
- **kind에서만: 클러스터를 `config_path`로 만들어야 containerd가 `certs.d`를 읽습니다.** kind 0.33 노드 이미지는 이 값이 비어 있어서, 05-private-registry.sh가 그 패치로 클러스터를 만들고, 패치 없는 기존 클러스터는 거부합니다.

**업그레이드 경로(이미지나 차트 버전 올리기. CVE 패치도 같음).**

1. 새 버전을 쓰는 values로 렌더링해 이미지를 뽑습니다. `helm template … | grep -E 'image:|repository:|tag:'`, operator CR의 `repository`/`tag`도 봅니다. [private-registry-images.txt](private-registry-images.txt)와 비교해 새 참조만 미러링하면 됩니다. 태그 하나가 바뀌는 패치(예: ClickHouse 26.8.36.3 → 더 새 26.8 빌드)라면 한 줄입니다.
2. 새 참조를 digest를 유지해 미러링합니다. `crane cp <src> <registry>/<src>`, ACR에서는 `az acr import --name <acr> --source <src> --image <src 경로>:<tag>`(실행 안 함). 새 차트 버전은 langfuse(일반 저장소)는 `helm pull` + `helm push`, OCI 차트는 `crane cp`/`az acr import`입니다.
3. 고정값을 바꿉니다. 차트의 `--version`이나 태그 키(`langfuse.image.tag`, `clickhouse.cluster.image.tag`, `clickhouse.keeper.image.tag`)를 바꾸고 같은 values로 `helm upgrade`합니다.
4. `06-private-registry-checks.sh`(또는 같은 생각: 모든 `imageID`가 레지스트리에서 왔고 원본 digest와 같은지)를 돌립니다. 빠뜨린 참조는 그냥 지나가지 않습니다. 노드가 원본에 닿지 못하므로 pod는 ImagePullBackOff에 머물고, rollout은 기존 pod가 계속 서비스하는 채로 멈춥니다.
5. 롤백 기간이 끝날 때까지 이전 태그를 레지스트리에 둡니다.

2026-11-04 측정(같은 조건): 미러링하지 않은 채 `langfuse.worker.image.tag=4.71.0`을 넣었습니다. 새 worker pod는 ErrImagePull(`privreg.lab.test`의 `NotFound`, 다른 곳은 시도하지 않음)에 머물렀고, rollout은 2개 중 1개 갱신에서 멈췄으며, 4.70.1 worker 2개는 계속 서비스했습니다. `helm rollback`으로 되돌렸습니다. 뒷부분(4.71.0 미러링 후 rollout 완료)은 **실행하지 못했습니다**. 그 미러링이 Docker Hub 제한에 걸렸습니다(아래).

**AKS + ACR에서는(Azure 문서 기준, 실행 안 함).**
- `az acr import --name <acr> --source docker.io/clickhouse/clickhouse-server:26.8.36.3 --image docker.io/clickhouse/clickhouse-server:26.8.36.3`은 멀티 아키텍처 이미지를 서버 쪽에서 복사하고 digest를 유지합니다. Docker Hub 원본은 rate limit 때문에 `--username/--password`를 줍니다. import 대신 ACR 캐시 규칙(pull-through cache)을 쓸 수도 있습니다.
- `az aks update -n <aks> -g <rg> --attach-acr <acr>`은 kubelet identity에 AcrPull을 줍니다. 그러면 노드가 `imagePullSecrets` 없이 받고, values의 pullSecrets 줄은 빼도 됩니다. 토큰이나 service principal을 쓰면 kind에서처럼 남깁니다.
- ACR은 `az acr update --anonymous-pull-enabled true`(Standard, Premium)를 켜지 않으면 익명 pull을 허용하지 않습니다. 기본은 꺼짐이고, 여기서 htpasswd를 건 `registry:2`가 그 역할입니다.
- ACR의 Helm 차트는 OCI 아티팩트입니다. `helm registry login <acr>.azurecr.io`(토큰은 `az acr login --name <acr> --expose-token`), `helm push langfuse-2.2.1.tgz oci://<acr>.azurecr.io/charts`, `helm install langfuse oci://<acr>.azurecr.io/charts/langfuse --version 2.2.1`.
- AKS에서 공개 레지스트리를 막는 것은 containerd 설정이 아니라 egress 통제(Azure Firewall 또는 UDR)입니다. AKS는 자체 시스템 이미지 때문에 `mcr.microsoft.com`이 계속 필요합니다. network isolated 클러스터라면 시스템 이미지도 사설 ACR 캐시에서 옵니다.

### 파일

| 파일 | 내용 |
|---|---|
| [values-base.yaml](values-base.yaml) | 사이징과 배치, 모든 클라우드 공통 |
| [values-aks.yaml](values-aks.yaml) · [values-eks.yaml](values-eks.yaml) · [values-gke.yaml](values-gke.yaml) | 클라우드마다 더하는 부분 |
| [storageclass-eks.yaml](storageclass-eks.yaml) | EKS용 gp3 StorageClass |
| [values-kind.yaml](values-kind.yaml) | kind용 overlay: 사양, 대체 서비스 주소, 스토리지 클래스, headless init |
| [secret-example.yaml](secret-example.yaml) | `langfuse` Secret의 키 |
| [kind-config.yaml](kind-config.yaml) · [standins.yaml](standins.yaml) | 노드 풀 모양의 kind 클러스터, Postgres, Redis, Azurite |
| [values-private-registry.yaml](values-private-registry.yaml) | 차트의 모든 이미지를 사설 레지스트리에서, pull Secret과 함께 |
| [private-registry-images.txt](private-registry-images.txt) · [private-registry.inc.sh](private-registry.inc.sh) | 미러링할 이미지와 차트, 스크립트가 쓰는 레지스트리 이름 |
| `01`–`04`, `99` | 설정, 설치, 확인, 클라우드 렌더 검사, 정리 |
| `05`, `06` | 사설 레지스트리: 레지스트리, 미러링, 잠근 노드, pull 대조 실험, 다른 곳에서 받은 것이 없는지 확인 |
