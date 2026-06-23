#!/usr/bin/env bash
# Install Spegel — distributed in-cluster image pull-through cache.
#
# Prereqs:
#   - Talos cluster with the spegel-containerd-patch ConfigPatch applied
#     (see infrastructure/talos/spegel-containerd-patch.yaml). Nodes MUST
#     have rebooted after that patch — containerd config is read once at
#     startup.
#   - kubectl + helm on PATH, kubeconfig pointed at the target cluster.
#
# Usage:
#   ./infrastructure/spegel/install.sh
#   SPEGEL_VERSION=v0.7.0 ./infrastructure/spegel/install.sh

set -euo pipefail

SPEGEL_VERSION="${SPEGEL_VERSION:-0.7.0}"
NAMESPACE="${NAMESPACE:-spegel}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VALUES="${SCRIPT_DIR}/values.yaml"

log() { printf "[spegel] %s\n" "$*"; }

kubectl version --request-timeout=5s >/dev/null 2>&1 \
  || { echo "kubectl can't reach the cluster" >&2; exit 1; }

# Sanity: warn if discard_unpacked_layers patch isn't applied. Spegel
# will run but every cache entry is empty → effectively useless.
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
if [[ -n "${NODE}" ]]; then
  log "verifying containerd discard_unpacked_layers=false on ${NODE}..."
  if ! kubectl debug node/"${NODE}" -it --image=busybox --quiet \
       -- chroot /host cat /var/etc/cri/conf.d/20-spegel.part 2>/dev/null \
       | grep -q "discard_unpacked_layers = false" ; then
    echo "WARN: spegel-containerd-patch may not be applied. Apply it via:" >&2
    echo "  omnictl apply -f infrastructure/talos/spegel-containerd-patch.yaml" >&2
    echo "  --label omni.sidero.dev/cluster=<cluster-name>" >&2
    echo "  Continuing — Spegel runs but the cache will be useless without it." >&2
  fi
fi

log "creating namespace ${NAMESPACE} (privileged PSS — Spegel needs hostPath + hostNetwork)..."
kubectl create ns "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl label ns "${NAMESPACE}" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite

log "installing spegel ${SPEGEL_VERSION}..."
helm upgrade --install spegel \
  oci://ghcr.io/spegel-org/helm-charts/spegel \
  --version "${SPEGEL_VERSION}" \
  --namespace "${NAMESPACE}" \
  --values "${VALUES}" \
  --wait --timeout 5m

log "waiting for DaemonSet rollout..."
kubectl -n "${NAMESPACE}" rollout status ds/spegel --timeout=5m

log "verifying registry mirror config landed on a node..."
sleep 5
kubectl -n "${NAMESPACE}" exec ds/spegel -- ls /etc/cri/conf.d/hosts/ 2>&1 | head -10 || true

log "done. Smoke test:"
log "  kubectl run spegel-test --image=nginx:latest --restart=Never --image-pull-policy=Always"
log "  # delete + recreate elsewhere — second pull should be served by Spegel"
log "Metrics:"
log "  kubectl -n ${NAMESPACE} port-forward ds/spegel 9090:9090"
log "  curl localhost:9090/metrics | grep spegel_"
