#!/usr/bin/env bash
# Install metrics-server on a Talos cluster, per Sidero docs.
# https://docs.siderolabs.com/kubernetes-guides/monitoring-and-observability/deploy-metrics-server
#
# Two pieces:
#   1. kubelet-serving-cert-approver — auto-approves CSRs from kubelets so
#      their server certs become valid (avoids --kubelet-insecure-tls).
#   2. metrics-server — exposes Pod/Node CPU+memory via metrics.k8s.io.
#
# Prerequisite: kubelet must rotate server certificates. Apply
# infrastructure/talos/kubelet-cert-rotation.yaml as an Omni machine-config
# patch and reboot each node BEFORE running this script. Without it,
# metrics-server pods will be Running but `kubectl top` returns errors.
#
# Versions are pinned; bump them when upstream releases land.
#
# Usage:
#   ./infrastructure/metrics-server/install.sh

set -euo pipefail

CERT_APPROVER_VERSION="${CERT_APPROVER_VERSION:-v0.10.3}"
METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-v0.8.1}"

echo "Installing kubelet-serving-cert-approver ${CERT_APPROVER_VERSION}..."
kubectl apply -f \
  "https://raw.githubusercontent.com/alex1989hu/kubelet-serving-cert-approver/${CERT_APPROVER_VERSION}/deploy/standalone-install.yaml"

# Strategic-merge patch over the upstream Deployment — bumps probe
# timeouts so the approver doesn't restart-loop on memory-pressured
# clusters. See infrastructure/metrics-server/cert-approver-probe-tuning.yaml
# for the rationale.
echo "Applying cert-approver probe tuning patch..."
kubectl apply -f "$(dirname "$0")/cert-approver-probe-tuning.yaml"

echo "Installing metrics-server ${METRICS_SERVER_VERSION}..."
kubectl apply -f \
  "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"

echo "Waiting for both Deployments to become Available..."
kubectl -n kube-system                    wait --for=condition=Available deployment/metrics-server                --timeout=3m
kubectl -n kubelet-serving-cert-approver  wait --for=condition=Available deployment/kubelet-serving-cert-approver --timeout=3m

echo ""
echo "Verifying metrics API..."
for i in $(seq 1 12); do
  if kubectl top nodes >/dev/null 2>&1; then
    echo "✓ metrics.k8s.io API responding"
    kubectl top nodes
    exit 0
  fi
  echo "  waiting for first metrics scrape ($i/12)..."
  sleep 10
done

echo ""
echo "✗ metrics API still not responding after 2m. Common causes:"
echo "    - kubelet rotate-server-certificates not enabled (see infrastructure/talos/kubelet-cert-rotation.yaml)"
echo "    - nodes not rebooted after machine config patch"
echo "    - kubelet-serving-cert-approver Pod not yet reconciled CSRs"
echo ""
echo "Check pending CSRs:"
echo "    kubectl get csr | grep Pending"
exit 1
