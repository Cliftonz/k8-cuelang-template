#!/usr/bin/env bash
# Install CloudNativePG operator via Bitnami Helm chart.
# Required by Crossplane UXP Apollo for managed PostgreSQL.
#
# Usage:
#   ./infrastructure/cloudnative-pg/install.sh
#
# Prerequisites:
#   - kubectl configured with cluster-admin access
#   - helm v3+

set -euo pipefail

NAMESPACE="cnpg-system"
REPO_NAME="cnpg"
REPO_URL="https://cloudnative-pg.github.io/charts"
RELEASE_NAME="cnpg"

echo "Creating namespace ${NAMESPACE}..."
kubectl apply -f "$(dirname "$0")/namespace.yaml"

echo "Adding CloudNativePG Helm repo..."
helm repo add "${REPO_NAME}" "${REPO_URL}" 2>/dev/null || true
helm repo update

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing CloudNativePG operator..."
helm upgrade --install "${RELEASE_NAME}" \
  --namespace "${NAMESPACE}" \
  "${REPO_NAME}/cloudnative-pg" \
  --values "${SCRIPT_DIR}/values.yaml" \
  --wait --timeout 5m

echo "CloudNativePG operator installed successfully. Pods:"
kubectl -n "${NAMESPACE}" get pods
