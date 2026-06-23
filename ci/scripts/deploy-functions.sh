#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "${script_dir}/../.." && pwd)"

patch_and_transform_path="${root_dir}/infrastructure/crossplane/functions/patch-and-transform/function.yaml"
extra_resources_path="${root_dir}/infrastructure/crossplane/functions/extra-resources/function.yaml"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required" >&2
  exit 1
fi

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
    echo "Timed out waiting for an active FunctionRevision for ${name}." >&2
    exit 1
  fi
}

echo "Applying function package manifests..."
kubectl apply -f "${patch_and_transform_path}"
kubectl apply -f "${extra_resources_path}"

wait_for_function "crossplane-contrib-function-patch-and-transform"
wait_for_function "crossplane-contrib-function-extra-resources"
