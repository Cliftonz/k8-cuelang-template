#!/usr/bin/env bash
# Install Cilium CNI on a Talos cluster that was bootstrapped with the
# `cilium-cni-patch.yaml` Talos ConfigPatch (cluster.network.cni.name=none
# + cluster.proxy.disabled=true).
#
# Prereqs:
#   - kubeconfig points at a freshly bootstrapped Talos cluster
#   - nodes are NotReady (expected — no CNI yet)
#   - kubectl + helm on PATH
#
# Usage:
#   ./infrastructure/cilium/install.sh
#   CILIUM_VERSION=1.19.3 ./infrastructure/cilium/install.sh
#
# Idempotent — re-running is a `helm upgrade --install`.

set -euo pipefail

CILIUM_VERSION="${CILIUM_VERSION:-1.19.3}"
NAMESPACE="${NAMESPACE:-kube-system}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VALUES="${SCRIPT_DIR}/values.yaml"

log() { printf "[cilium] %s\n" "$*"; }

# Sanity: API reachable
if ! kubectl version --request-timeout=5s >/dev/null 2>&1; then
  echo "kubectl can't reach the cluster. Check your kubeconfig context." >&2
  exit 1
fi

log "adding cilium helm repo..."
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update >/dev/null

log "installing cilium ${CILIUM_VERSION} into ${NAMESPACE}..."
helm upgrade --install cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace "${NAMESPACE}" \
  --values "${VALUES}" \
  --wait --timeout 5m

log "waiting for cilium DaemonSet..."
kubectl -n "${NAMESPACE}" rollout status ds/cilium --timeout=5m
kubectl -n "${NAMESPACE}" rollout status deploy/cilium-operator --timeout=5m

log "waiting for nodes to flip Ready..."
for i in $(seq 1 30); do
  not_ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {c++} END {print c+0}')
  if [[ "${not_ready}" == "0" ]]; then
    log "all nodes Ready"
    break
  fi
  echo "  ${not_ready} node(s) still NotReady..."
  sleep 10
done

log "running cilium status..."
CILIUM_POD=$(kubectl -n "${NAMESPACE}" get pods -l k8s-app=cilium -o name | head -1)
kubectl -n "${NAMESPACE}" exec "${CILIUM_POD}" -c cilium-agent -- cilium status --brief || true

# Post-reboot BPF socket-LB watchdog (ADR 006). See docs/adr/006-cilium-socketlb-watchdog.md.
# Idempotent — kubectl apply.
log "applying cilium-bpf-watchdog DaemonSet..."
kubectl apply -f "${SCRIPT_DIR}/bpf-socketlb-watchdog.yaml"
kubectl -n "${NAMESPACE}" rollout status ds/cilium-bpf-watchdog --timeout=2m || true

log "done. To enable Hubble UI later: helm upgrade ... --set hubble.relay.enabled=true --set hubble.ui.enabled=true"
