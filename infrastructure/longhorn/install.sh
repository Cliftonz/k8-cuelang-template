#!/usr/bin/env bash
# Install Longhorn block storage on a Talos Linux cluster.
#
# Usage:
#   ./infrastructure/longhorn/install.sh
#
# Prerequisites:
#   - kubectl configured with cluster-admin access
#   - helm v3+
#   - Talos nodes have the iscsi-tools and util-linux-tools system
#     extensions installed and have been rebooted. Without these, the
#     longhorn-manager pods will CrashLoopBackOff with:
#       "Error starting manager: failed to check environment, please make
#        sure you have iscsiadm/open-iscsi installed on the host"
#   - Talos workers have a UserVolumeConfig mounting a dedicated data
#     disk at /var/mnt/longhorn (see infrastructure/talos/longhorn-uservolume.yaml).
#     Without this, Longhorn images + volumes pile onto the root
#     filesystem, trip DiskPressure, and instance-manager pods are
#     evicted in a loop. The pre-flight check below fails fast if
#     /var/mnt/longhorn is missing.
#
# To add the extensions via Omni:
#   Cluster → Machine Config Patches → add siderolabs/iscsi-tools and
#   siderolabs/util-linux-tools to every worker node, then reboot.
#
# To add via talosctl:
#   talosctl patch machineconfig --nodes <node-ips> --patch '[
#     {"op":"add","path":"/machine/install/extensions/-",
#      "value":{"image":"ghcr.io/siderolabs/iscsi-tools:v0.1.5"}},
#     {"op":"add","path":"/machine/install/extensions/-",
#      "value":{"image":"ghcr.io/siderolabs/util-linux-tools:2.40.4"}}
#   ]'
#
# To add the data-disk UserVolume via talosctl:
#   talosctl -n <worker-ips> patch machineconfig \
#     --patch @infrastructure/talos/longhorn-uservolume.yaml
#   # reboot each worker one at a time afterwards.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

NAMESPACE="longhorn-system"
REPO_NAME="longhorn"
REPO_URL="https://charts.longhorn.io"
RELEASE_NAME="longhorn"
CHART_VERSION="${LONGHORN_CHART_VERSION:-1.7.2}"

echo "Creating namespace ${NAMESPACE}..."
kubectl apply -f "${SCRIPT_DIR}/namespace.yaml"

echo "Adding Longhorn Helm repo..."
helm repo add "${REPO_NAME}" "${REPO_URL}" 2>/dev/null || true
helm repo update "${REPO_NAME}"

# Pre-flight: check that at least one worker node has iscsiadm available.
# We do this by running a short pod and looking for nsenter exit status.
# If you hit this check and are certain the extension is installed, set
# SKIP_PREFLIGHT=1 to bypass.
if [[ "${SKIP_PREFLIGHT:-0}" != "1" ]]; then
  echo "Pre-flight: checking for iscsi-tools on worker nodes..."
  WORKER=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}')
  if [[ -z "${WORKER}" ]]; then
    echo "No worker nodes found. Skipping pre-flight."
  else
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: longhorn-preflight
  namespace: longhorn-system
spec:
  nodeName: ${WORKER}
  hostPID: true
  restartPolicy: Never
  containers:
    - name: check
      image: alpine:3.20
      command: ["/bin/sh", "-c", "nsenter -t 1 -m -n -p -- iscsiadm --version || exit 42"]
      securityContext:
        privileged: true
  tolerations:
    - operator: Exists
EOF
    kubectl wait --for=condition=Ready pod/longhorn-preflight --timeout=60s -n longhorn-system >/dev/null 2>&1 || true
    for _ in {1..30}; do
      PHASE=$(kubectl get pod longhorn-preflight -n longhorn-system -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      [[ "${PHASE}" == "Succeeded" || "${PHASE}" == "Failed" ]] && break
      sleep 2
    done
    if [[ "$(kubectl get pod longhorn-preflight -n longhorn-system -o jsonpath='{.status.phase}')" != "Succeeded" ]]; then
      kubectl logs longhorn-preflight -n longhorn-system || true
      kubectl delete pod longhorn-preflight -n longhorn-system --ignore-not-found
      echo ""
      echo "❌ Pre-flight failed: iscsiadm not available on node ${WORKER}."
      echo "   Install the iscsi-tools Talos extension and reboot before continuing."
      echo "   (Set SKIP_PREFLIGHT=1 to bypass this check.)"
      exit 1
    fi
    kubectl delete pod longhorn-preflight -n longhorn-system --ignore-not-found
    echo "✓ iscsiadm available on ${WORKER}"
  fi
fi

# Pre-flight: check that /var/mnt/longhorn is a real mount (not just a
# root-fs directory). Without a dedicated data disk Longhorn images pile
# onto the root filesystem and DiskPressure evicts instance-manager pods.
if [[ "${SKIP_PREFLIGHT:-0}" != "1" ]]; then
  echo "Pre-flight: checking /var/mnt/longhorn data-disk mount..."
  WORKER=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}')
  if [[ -z "${WORKER}" ]]; then
    echo "No worker nodes found. Skipping data-disk pre-flight."
  else
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: longhorn-preflight-mount
  namespace: longhorn-system
spec:
  nodeName: ${WORKER}
  hostPID: true
  restartPolicy: Never
  containers:
    - name: check
      image: alpine:3.20
      command: ["/bin/sh", "-c", "nsenter -t 1 -m -n -p -- mountpoint -q /var/mnt/longhorn || exit 42"]
      securityContext:
        privileged: true
  tolerations:
    - operator: Exists
EOF
    for _ in {1..30}; do
      PHASE=$(kubectl get pod longhorn-preflight-mount -n longhorn-system -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
      [[ "${PHASE}" == "Succeeded" || "${PHASE}" == "Failed" ]] && break
      sleep 2
    done
    if [[ "$(kubectl get pod longhorn-preflight-mount -n longhorn-system -o jsonpath='{.status.phase}')" != "Succeeded" ]]; then
      kubectl delete pod longhorn-preflight-mount -n longhorn-system --ignore-not-found
      echo ""
      echo "❌ Pre-flight failed: /var/mnt/longhorn is not a mount on node ${WORKER}."
      echo "   Apply infrastructure/talos/longhorn-uservolume.yaml as a"
      echo "   Talos machineconfig patch to provision a dedicated data disk,"
      echo "   then reboot the worker. Without it, DiskPressure will evict"
      echo "   Longhorn instance-manager pods in a loop."
      echo "   (Set SKIP_PREFLIGHT=1 to bypass this check.)"
      exit 1
    fi
    kubectl delete pod longhorn-preflight-mount -n longhorn-system --ignore-not-found
    echo "✓ /var/mnt/longhorn mounted on ${WORKER}"
  fi
fi

echo "Installing Longhorn (chart version ${CHART_VERSION})..."
helm upgrade --install "${RELEASE_NAME}" \
  --namespace "${NAMESPACE}" \
  "${REPO_NAME}/longhorn" \
  --version "${CHART_VERSION}" \
  --values "${SCRIPT_DIR}/values.yaml" \
  --wait --timeout 10m

echo ""
echo "Waiting for Longhorn nodes to register..."
for _ in {1..30}; do
  # Tolerate transient apiserver flakes (proxy errors, TLS handshake) during
  # the helm rollout. Capture kubectl output first so a non-zero pipeline
  # exit (under pipefail) doesn't append `|| echo 0` onto wc's existing "0"
  # and produce a "0\n0" string that fails the arithmetic test.
  READY_OUT=$(kubectl get nodes.longhorn.io -n "${NAMESPACE}" -o jsonpath='{range .items[?(@.status.conditions[?(@.type=="Ready")].status=="True")]}{.metadata.name}{"\n"}{end}' 2>/dev/null) || READY_OUT=""
  TOTAL_OUT=$(kubectl get nodes.longhorn.io -n "${NAMESPACE}" --no-headers 2>/dev/null) || TOTAL_OUT=""
  READY=$(printf '%s' "${READY_OUT}" | grep -c . || true)
  TOTAL=$(printf '%s' "${TOTAL_OUT}" | grep -c . || true)
  [[ "${READY}" -gt 0 && "${READY}" == "${TOTAL}" ]] && break
  sleep 10
done

echo ""
echo "Longhorn nodes:"
kubectl get nodes.longhorn.io -n "${NAMESPACE}"
echo ""
echo "Longhorn storage classes:"
kubectl get storageclass

echo ""
echo "✓ Longhorn installed successfully."
echo "  Default StorageClass: longhorn"
echo "  UI: kubectl port-forward -n ${NAMESPACE} svc/longhorn-frontend 8080:80"
