#!/usr/bin/env bash
# Uninstall Longhorn and clean up its resources.
#
# WARNING: This deletes ALL Longhorn-managed PersistentVolumes. Back up
# any critical data before running.
#
# Usage:
#   ./infrastructure/longhorn/uninstall.sh

set -euo pipefail

NAMESPACE="longhorn-system"
RELEASE_NAME="longhorn"

read -p "This will delete ALL Longhorn PVs and data. Type 'YES' to continue: " CONFIRM
if [[ "${CONFIRM}" != "YES" ]]; then
  echo "Aborted."
  exit 1
fi

echo "Setting deletion confirmation flag on Longhorn..."
kubectl -n "${NAMESPACE}" patch setting deleting-confirmation-flag \
  --type=merge -p '{"value":"true"}' 2>/dev/null || true

echo "Uninstalling Longhorn Helm release..."
helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" || true

echo "Running Longhorn uninstall job..."
kubectl create -f https://raw.githubusercontent.com/longhorn/longhorn/v1.7.2/uninstall/uninstall.yaml 2>/dev/null || true

echo "Waiting up to 10 minutes for uninstall job to complete..."
kubectl wait --for=condition=complete job/longhorn-uninstall -n "${NAMESPACE}" --timeout=10m || true

echo "Deleting namespace..."
kubectl delete namespace "${NAMESPACE}" --ignore-not-found

echo "Deleting leftover Longhorn CRDs..."
kubectl get crd -o name | grep -i longhorn | xargs -r kubectl delete --ignore-not-found

echo "✓ Longhorn uninstalled."
