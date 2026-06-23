#!/usr/bin/env bash
# Install the NVIDIA DRA driver — exposes GPUs to Kubernetes via the
# resource.k8s.io/v1 ResourceClaim API instead of the legacy
# `nvidia.com/gpu` extended resource.
#
# Prereqs:
#   - Talos cluster with the dra-feature-gates ConfigPatch applied (see
#     infrastructure/talos/dra-feature-gates-patch.yaml).
#   - K8s ≥ 1.32 (1.34+ has DRA beta default-on, simpler).
#   - At least one node with NVIDIA hardware AND the NVIDIA system
#     extension installed via Talos image factory. See
#     infrastructure/talos/nvidia-gpu.md for that step.
#   - kubectl + helm on PATH, kubeconfig pointed at the target cluster.
#
# Usage:
#   ./infrastructure/nvidia-dra-driver/install.sh
#   DRA_VERSION=v25.3.1 ./infrastructure/nvidia-dra-driver/install.sh

set -euo pipefail

DRA_VERSION="${DRA_VERSION:-v25.3.1}"
NAMESPACE="${NAMESPACE:-nvidia-dra-driver-gpu}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VALUES="${SCRIPT_DIR}/values.yaml"

log() { printf "[dra] %s\n" "$*"; }

# Sanity: API reachable
kubectl version --request-timeout=5s >/dev/null 2>&1 \
  || { echo "kubectl can't reach the cluster" >&2; exit 1; }

# Sanity: feature gate is on (cheap parse of any node's kubelet config)
NODE=$(kubectl get nodes -o name | head -1)
if [[ -n "${NODE}" ]]; then
  log "verifying DynamicResourceAllocation feature gate on ${NODE}..."
  if ! kubectl get --raw "/api/v1/nodes/${NODE#node/}/proxy/configz" 2>/dev/null \
      | grep -q '"DynamicResourceAllocation":true' ; then
    echo "WARN: DRA feature gate may not be enabled on kubelet. Apply" >&2
    echo "  infrastructure/talos/dra-feature-gates-patch.yaml first."  >&2
    echo "  Continuing — the install will fail at scheduler time if the"     >&2
    echo "  apiserver/scheduler also lack the gate."                         >&2
  fi
fi

# Sanity: at least one node carries NVIDIA labels
GPU_NODES=$(kubectl get nodes -l nvidia.com/gpu -o name 2>/dev/null | wc -l | tr -d ' ')
if [[ "${GPU_NODES}" == "0" ]]; then
  log "no nodes labeled nvidia.com/gpu — install will deploy but DeviceClass"
  log "  will report zero ResourceSlices. Bring up a GPU node first."
fi

log "creating namespace ${NAMESPACE}..."
kubectl create ns "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

log "adding NVIDIA helm repo..."
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1 || true
helm repo update >/dev/null

log "installing nvidia-dra-driver-gpu ${DRA_VERSION}..."
helm upgrade --install nvidia-dra-driver-gpu \
  nvidia/nvidia-dra-driver-gpu \
  --version "${DRA_VERSION}" \
  --namespace "${NAMESPACE}" \
  --values "${VALUES}" \
  --wait --timeout 5m

log "checking ResourceSlices (one per GPU per node)..."
kubectl get resourceslices.resource.k8s.io 2>&1 | head -20 || true

log "done. Smoke-test with: kubectl apply -f infrastructure/nvidia-dra-driver/example-pod.yaml"
