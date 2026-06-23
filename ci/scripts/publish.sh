#!/usr/bin/env sh
set -eu

if [ -z "${CLUSTER:-}" ]; then
  echo "Usage: make publish CLUSTER=new-dev OCI_REF=registry.example.com/k8-infra/manifests:tag" >&2
  exit 1
fi

if [ -n "${DOCKER_REF:-}" ] && [ -z "${OCI_REF:-}" ]; then
  OCI_REF="${DOCKER_REF}"
fi

if [ -z "${OCI_REF:-}" ] && [ -z "${LOCAL_OUTPUT:-}" ]; then
  echo "Usage: make publish CLUSTER=new-dev OCI_REF=registry.example.com/k8-infra/manifests:tag" >&2
  echo "   or: make publish CLUSTER=new-dev DOCKER_REF=localhost:5000/k8-infra/manifests:tag" >&2
  echo "   or: make publish CLUSTER=new-dev LOCAL_OUTPUT=oci-out [LOCAL_TAG=manifests]" >&2
  exit 1
fi

if ! command -v oras >/dev/null 2>&1; then
  echo "oras is required (brew install oras)" >&2
  exit 1
fi

if [ ! -d "clusters/${CLUSTER}" ]; then
  echo "clusters/${CLUSTER} does not exist. Run export first." >&2
  exit 1
fi

if [ -n "${LOCAL_OUTPUT:-}" ]; then
  local_tag="${LOCAL_TAG:-manifests}"
  oras push --oci-layout "${LOCAL_OUTPUT}:${local_tag}" "clusters/${CLUSTER}/" \
    --artifact-type application/vnd.kubernetes.manifest.v1+yaml
  echo "Wrote OCI layout to ${LOCAL_OUTPUT} (tag: ${local_tag})"
else
  oras push "${OCI_REF}" "clusters/${CLUSTER}/" \
    --artifact-type application/vnd.kubernetes.manifest.v1+yaml
  echo "Published ${OCI_REF}"
fi
