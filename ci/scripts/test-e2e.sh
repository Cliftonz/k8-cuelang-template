#!/usr/bin/env sh
set -eu

if [ -z "${CLUSTER:-}" ]; then
  echo "Usage: make test-e2e CLUSTER=new-dev" >&2
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required" >&2
  exit 1
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required" >&2
  exit 1
fi

if [ -n "${KIND_CLUSTER_NAME:-}" ]; then
  if ! command -v kind >/dev/null 2>&1; then
    echo "kind is required when KIND_CLUSTER_NAME is set" >&2
    exit 1
  fi
  # Clean up on exit, and delete any stale cluster left by a prior run
  # that died before its trap fired (self-hosted runners leak otherwise:
  # `kind create` then fails with "node(s) already exist").
  trap 'kind delete cluster --name "${KIND_CLUSTER_NAME}" 2>/dev/null || true' EXIT
  if kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER_NAME}"; then
    echo "Deleting stale kind cluster: ${KIND_CLUSTER_NAME}"
    kind delete cluster --name "${KIND_CLUSTER_NAME}"
  fi
  echo "Creating kind cluster: ${KIND_CLUSTER_NAME}"
  kind create cluster --name "${KIND_CLUSTER_NAME}"
fi

context="$(kubectl config current-context 2>/dev/null || true)"
if [ -z "$context" ]; then
  echo "No active kubectl context found" >&2
  exit 1
fi

echo "Using kubectl context: $context"

./infrastructure/crossplane/install.sh

if [ -d "clusters/${CLUSTER}/xrds" ]; then
  kubectl apply -R -f "clusters/${CLUSTER}/xrds"
  kubectl wait --for=condition=Established -f "clusters/${CLUSTER}/xrds" --timeout=120s
fi

kubectl apply -R -f "clusters/${CLUSTER}"

kinds="$(kubectl get crd -o jsonpath='{range .items[?(@.spec.group=="infra.k8")]}{.spec.names.kind}{"\n"}{end}')"
for kind in $kinds; do
  if kubectl get "$kind" -A --no-headers >/dev/null 2>&1; then
    if [ "$(kubectl get "$kind" -A --no-headers | wc -l | tr -d ' ')" -gt 0 ]; then
      kubectl wait --for=condition=Ready "$kind" --all --timeout=5m
    fi
  fi
done

echo "E2E checks completed"
