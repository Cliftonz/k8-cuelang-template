#!/usr/bin/env bash
# Uninstall Upbound Universal Crossplane (UXP) from the target cluster.
# Reverses the operations performed by install.sh.
#
# Usage:
#   ./infrastructure/crossplane/uninstall.sh
#
# Prerequisites:
#   - kubectl configured with cluster-admin access
#   - helm v3+

set -euo pipefail

NAMESPACE="crossplane-system"
RELEASE_NAME="crossplane"

echo "=== Removing Crossplane ProviderConfigs ==="
kubectl delete providerconfig/default --ignore-not-found 2>/dev/null || true
kubectl delete providerconfig.kubernetes.crossplane.io/default --ignore-not-found 2>/dev/null || true
kubectl delete providerconfig.harbor.crossplane.io/default --ignore-not-found 2>/dev/null || true

echo "=== Removing Functions ==="
kubectl delete function/function-dns-validator --ignore-not-found 2>/dev/null || true
kubectl delete function/crossplane-contrib-function-extra-resources --ignore-not-found 2>/dev/null || true
kubectl delete function/crossplane-contrib-function-patch-and-transform --ignore-not-found 2>/dev/null || true

echo "=== Removing Providers ==="
kubectl delete provider/provider-harbor --ignore-not-found 2>/dev/null || true
kubectl delete provider/provider-kubernetes --ignore-not-found 2>/dev/null || true
kubectl delete provider/provider-helm --ignore-not-found 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
K8S_NODE_RBAC_PATH="${SCRIPT_DIR}/providers/kubernetes/rbac-node-patch.yaml"

echo "=== Removing Provider Kubernetes node RBAC ==="
kubectl delete -f "${K8S_NODE_RBAC_PATH}" --ignore-not-found 2>/dev/null || true

echo "=== Waiting for providers and functions to be fully removed ==="
for _ in {1..60}; do
  REMAINING=$(kubectl get providers,functions -o name 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${REMAINING}" == "0" ]]; then
    break
  fi
  echo "  Still waiting... (${REMAINING} resources remaining)"
  sleep 5
done

echo "=== Uninstalling UXP Helm release ==="
helm uninstall "${RELEASE_NAME}" --namespace "${NAMESPACE}" --wait --timeout 5m 2>/dev/null || true

echo "=== Deleting namespace ${NAMESPACE} ==="
kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait --timeout 5m

echo "=== Crossplane uninstall complete ==="
