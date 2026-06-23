#!/usr/bin/env bash
# Install Upbound Universal Crossplane (UXP) on the target cluster.
# Ref: https://docs.upbound.io/manuals/uxp/howtos/uxp-deployment/
#
# Usage:
#   ./infrastructure/crossplane/install.sh
#
# Optional component flags (set to 1 to opt in, default off — keeps the
# install minimal for clusters that don't need them):
#   INSTALL_HARBOR=1     install crossplane provider-harbor (~150 MiB)
#   INSTALL_CNPG=1       install CloudNativePG operator (~150 MiB; needed
#                        by Apollo / preview's database stack)
#   INSTALL_EXTRA_RES=1  install function-extra-resources (~50 MiB; only
#                        needed if a Composition's pipeline references it)
#
# Rationale: bundling everything by default eats CP apiserver memory in
# small clusters (every CRD scales the watch cache). XRDs themselves are
# now usage-driven via export/all.cue's _xrdMap — see CLAUDE.md.
#
# Prerequisites:
#   - kubectl configured with cluster-admin access
#   - helm v3+

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CNPG_INSTALL="${SCRIPT_DIR}/../cloudnative-pg/install.sh"

if [[ "${INSTALL_CNPG:-0}" == "1" ]]; then
  if helm status cnpg -n cnpg-system >/dev/null 2>&1; then
    echo "CloudNativePG operator already installed — skipping"
  else
    echo "Installing CloudNativePG operator..."
    bash "${CNPG_INSTALL}"
  fi
else
  echo "Skipping CloudNativePG (set INSTALL_CNPG=1 to enable)"
fi

NAMESPACE="crossplane-system"
REPO_NAME="upbound-stable"
REPO_URL="https://charts.upbound.io/stable"
RELEASE_NAME="crossplane"
CHART_VERSION="${CROSSPLANE_CHART_VERSION:-2.2.0-up.4}"

echo "Creating namespace ${NAMESPACE}..."
kubectl apply -f "$(dirname "$0")/namespace.yaml"

echo "Adding Upbound Helm repo..."
# --force-update makes re-adding idempotent without swallowing real
# failures (the old `2>/dev/null || true` hid add errors, then the
# unscoped `helm repo update` died with "no repositories found" on a
# fresh machine — e.g. CI runners). Scope the update to this repo so it
# can't fail on unrelated/empty repo state.
helm repo add "${REPO_NAME}" "${REPO_URL}" --force-update
helm repo update "${REPO_NAME}"

PROVIDER_PATH="${SCRIPT_DIR}/providers/helm/provider.yaml"
PROVIDERCONFIG_PATH="${SCRIPT_DIR}/providers/helm/providerconfig.yaml"
HELM_RBAC_PATH="${SCRIPT_DIR}/providers/helm/rbac-cluster-admin.yaml"
K8S_PROVIDER_PATH="${SCRIPT_DIR}/providers/kubernetes/provider.yaml"
K8S_PROVIDERCONFIG_PATH="${SCRIPT_DIR}/providers/kubernetes/providerconfig.yaml"
K8S_PROVIDERCONFIG_CRD="providerconfigs.kubernetes.crossplane.io"
K8S_NODE_RBAC_PATH="${SCRIPT_DIR}/providers/kubernetes/rbac-node-patch.yaml"
HARBOR_PROVIDER_PATH="${SCRIPT_DIR}/providers/harbor/provider.yaml"
HARBOR_PROVIDERCONFIG_PATH="${SCRIPT_DIR}/providers/harbor/providerconfig.yaml"
PATCH_AND_TRANSFORM_FUNCTION_NAME="crossplane-contrib-function-patch-and-transform"
PATCH_AND_TRANSFORM_FUNCTION_PATH="${SCRIPT_DIR}/functions/patch-and-transform/function.yaml"
EXTRA_RESOURCES_FUNCTION_NAME="crossplane-contrib-function-extra-resources"
EXTRA_RESOURCES_FUNCTION_PATH="${SCRIPT_DIR}/functions/extra-resources/function.yaml"

# Skip helm upgrade if Crossplane is already installed and the upbound-
# crossplane-versions ConfigMap has been patched (the ConfigMap key conflict
# from phase 5.5 means a re-`helm upgrade` will fail with SSA conflict on
# .data.crossplaneVersion). Re-running providers/functions yamls below is
# idempotent and is the actual reason this script gets re-invoked.
if helm status "${RELEASE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "UXP already installed — skipping helm upgrade (re-applying providers + functions only)"
else
  echo "Installing UXP (chart version ${CHART_VERSION})..."
  helm upgrade --install "${RELEASE_NAME}" \
    --namespace "${NAMESPACE}" \
    "${REPO_NAME}/crossplane" \
    --version "${CHART_VERSION}" \
    --values "${SCRIPT_DIR}/values.yaml" \
    --devel \
    --wait --timeout 10m
fi

# Note: Helm requires the use of --devel flag for versions with suffixes, like v2.0.0-up.1.
# The Helm repository Upbound uses is the stable repository, so use of that flag is only a workaround.
# Pin CHART_VERSION to avoid picking up an unexpected latest release.
# The image tag defaults to the chart's appVersion, keeping them in sync.

echo "UXP installed successfully. Pods:"
kubectl -n "${NAMESPACE}" get pods

echo "Installing Provider Helm package..."
kubectl apply -f "${PROVIDER_PATH}"

echo "Installing Provider Kubernetes package..."
kubectl apply -f "${K8S_PROVIDER_PATH}"

if [[ "${INSTALL_HARBOR:-0}" == "1" ]]; then
  echo "Installing Provider Harbor package..."
  kubectl apply -f "${HARBOR_PROVIDER_PATH}"
else
  echo "Skipping Provider Harbor (set INSTALL_HARBOR=1 to enable)"
fi

echo "Applying Provider Helm cluster-admin RBAC..."
kubectl apply -f "${HELM_RBAC_PATH}"

echo "Applying Provider Kubernetes node RBAC..."
kubectl apply -f "${K8S_NODE_RBAC_PATH}"

echo "Installing patch-and-transform function package..."
kubectl apply -f "${PATCH_AND_TRANSFORM_FUNCTION_PATH}"

if [[ "${INSTALL_EXTRA_RES:-0}" == "1" ]]; then
  echo "Installing extra-resources function package..."
  kubectl apply -f "${EXTRA_RESOURCES_FUNCTION_PATH}"
else
  echo "Skipping function-extra-resources (set INSTALL_EXTRA_RES=1 to enable)"
fi

echo "Waiting for provider-helm to be healthy..."
kubectl wait --for=condition=Healthy provider/provider-helm --timeout=5m

echo "Waiting for provider-kubernetes to be healthy..."
kubectl wait --for=condition=Healthy provider/provider-kubernetes --timeout=5m

if [[ "${INSTALL_HARBOR:-0}" == "1" ]]; then
  echo "Waiting for provider-harbor to be healthy..."
  kubectl wait --for=condition=Healthy provider/provider-harbor --timeout=5m
fi

HARBOR_PROVIDERCONFIG_CRD="providerconfigs.harbor.crossplane.io"

wait_for_function() {
  local name="$1"

  echo "Waiting for ${name} to be healthy..."
  kubectl wait --for=condition=Healthy "function/${name}" --timeout=5m

  echo "Waiting for active FunctionRevision for ${name}..."
  for _ in {1..60}; do
    if kubectl get functionrevisions -o jsonpath='{range .items[?(@.spec.desiredState=="Active")]}{.metadata.ownerReferences[0].name}{"\n"}{end}' | grep -q "^${name}$"; then
      break
    fi
    sleep 5
  done

  if ! kubectl get functionrevisions -o jsonpath='{range .items[?(@.spec.desiredState=="Active")]}{.metadata.ownerReferences[0].name}{"\n"}{end}' | grep -q "^${name}$"; then
    echo "Timed out waiting for an active FunctionRevision for ${name}."
    exit 1
  fi
}

wait_for_function "${PATCH_AND_TRANSFORM_FUNCTION_NAME}"
if [[ "${INSTALL_EXTRA_RES:-0}" == "1" ]]; then
  wait_for_function "${EXTRA_RESOURCES_FUNCTION_NAME}"
fi

PROVIDERCONFIG_CRD="providerconfigs.helm.crossplane.io"

echo "Waiting for ${PROVIDERCONFIG_CRD} to be established..."
for _ in {1..60}; do
  if kubectl get crd "${PROVIDERCONFIG_CRD}" >/dev/null 2>&1; then
    kubectl wait --for=condition=Established "crd/${PROVIDERCONFIG_CRD}" --timeout=2m
    break
  fi
  sleep 5
done

if ! kubectl get crd "${PROVIDERCONFIG_CRD}" >/dev/null 2>&1; then
  echo "Timed out waiting for ${PROVIDERCONFIG_CRD}."
  exit 1
fi

echo "Applying ProviderConfig for Provider Helm..."
kubectl apply -f "${PROVIDERCONFIG_PATH}"

echo "Waiting for ${K8S_PROVIDERCONFIG_CRD} to be established..."
for _ in {1..60}; do
  if kubectl get crd "${K8S_PROVIDERCONFIG_CRD}" >/dev/null 2>&1; then
    kubectl wait --for=condition=Established "crd/${K8S_PROVIDERCONFIG_CRD}" --timeout=2m
    break
  fi
  sleep 5
done

if ! kubectl get crd "${K8S_PROVIDERCONFIG_CRD}" >/dev/null 2>&1; then
  echo "Timed out waiting for ${K8S_PROVIDERCONFIG_CRD}."
  exit 1
fi

echo "Applying ProviderConfig for Provider Kubernetes..."
kubectl apply -f "${K8S_PROVIDERCONFIG_PATH}"

if [[ "${INSTALL_HARBOR:-0}" == "1" ]]; then
  echo "Waiting for ${HARBOR_PROVIDERCONFIG_CRD} to be established..."
  for _ in {1..60}; do
    if kubectl get crd "${HARBOR_PROVIDERCONFIG_CRD}" >/dev/null 2>&1; then
      kubectl wait --for=condition=Established "crd/${HARBOR_PROVIDERCONFIG_CRD}" --timeout=2m
      break
    fi
    sleep 5
  done

  if ! kubectl get crd "${HARBOR_PROVIDERCONFIG_CRD}" >/dev/null 2>&1; then
    echo "Timed out waiting for ${HARBOR_PROVIDERCONFIG_CRD}."
    exit 1
  fi

  echo "Applying ProviderConfig for Provider Harbor..."
  kubectl apply -f "${HARBOR_PROVIDERCONFIG_PATH}"
fi
