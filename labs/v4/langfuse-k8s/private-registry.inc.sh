# private-registry.inc.sh — sourced (not run) by 01, 02, 05 and 06 for the private-registry run
# (PRIVATE_REGISTRY=1). It names the registry and where its local files live; it starts nothing.
REG_HOST=privreg.lab.test             # the name nodes and pods pull from (on AKS: <registry>.azurecr.io)
HELM_HOST=localhost:5443              # the same registry as the helm client on this machine reaches it
REG_CONTAINER=langfuse-k8s-registry   # registry:2 on the kind Docker network, alias $REG_HOST, port 443
REG_VOLUME=langfuse-k8s-registry-data
REG_USER=lab                          # htpasswd user; the password is generated per run, never printed
PULL_SECRET=regcred                   # kubernetes.io/dockerconfigjson Secret in every namespace that pulls
PR_NAMESPACES="cert-manager clickhouse-operator standins langfuse pull-controls"
STATE="$HERE/.private-registry"       # CA, server cert, htpasswd, docker config, mirror log (gitignored)
CA_FILE="$STATE/ca/ca.crt"
export HELM_REGISTRY_CONFIG="$STATE/helm-registry.json"
