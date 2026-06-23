#!/usr/bin/env sh
set -eu

if [ -z "${CLUSTER:-}" ]; then
  echo "Usage: make test-kyverno CLUSTER=new-dev" >&2
  exit 1
fi

if ! command -v chainsaw >/dev/null 2>&1; then
  echo "chainsaw is required (install from https://github.com/kyverno/chainsaw)" >&2
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required" >&2
  exit 1
fi

context="$(kubectl config current-context 2>/dev/null || true)"
if [ -z "$context" ]; then
  echo "No active kubectl context found" >&2
  exit 1
fi

echo "Using kubectl context: $context"

if ! kubectl get namespace kyverno >/dev/null 2>&1; then
  if [ -n "${KYVERNO_INSTALL_URL:-}" ]; then
    echo "Installing Kyverno from ${KYVERNO_INSTALL_URL}..."
    kubectl apply -f "${KYVERNO_INSTALL_URL}"
  elif [ -n "${KYVERNO_INSTALL_FILE:-}" ]; then
    echo "Installing Kyverno from ${KYVERNO_INSTALL_FILE}..."
    kubectl apply -f "${KYVERNO_INSTALL_FILE}"
  else
    echo "Kyverno namespace not found. Set KYVERNO_INSTALL_URL or KYVERNO_INSTALL_FILE." >&2
    exit 1
  fi
fi

if [ -d "clusters/${CLUSTER}/xrds" ]; then
  kubectl apply -R -f "clusters/${CLUSTER}/xrds"
  kubectl wait --for=condition=Established -f "clusters/${CLUSTER}/xrds" --timeout=120s
fi

kubectl apply -R -f "clusters/${CLUSTER}"

chainsaw test platform/policy/kyverno/tests
