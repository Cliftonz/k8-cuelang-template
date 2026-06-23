#!/usr/bin/env bash
# Validate raw-fallback output against real Kubernetes OpenAPI schemas via
# kubeconform. Catches "syntactically valid CUE that produces YAML the
# apiserver would reject" — a class of bug the golden-file test alone
# cannot detect.
#
# Built-in core resources (Namespace, NetworkPolicy, ResourceQuota, …)
# get strict schema validation. CRDs without published schemas (kelos.dev,
# kyverno.io ClusterPolicy specifics, etc.) are accepted via
# --ignore-missing-schemas — these are still useful as a smoke that the
# apiVersion/kind/metadata.name shape is well-formed.
#
# Usage:
#   ./ci/scripts/test-raw-validity.sh                # both clusters
#   ./ci/scripts/test-raw-validity.sh home           # one cluster
#   KUBECONFORM_VERSION=v0.6.7 ./ci/scripts/test-raw-validity.sh
#
# Requires: kubeconform on PATH (or auto-installed to /tmp).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

CLUSTERS=("$@")
[[ ${#CLUSTERS[@]} -eq 0 ]] && CLUSTERS=(home preview)

KUBECONFORM_VERSION="${KUBECONFORM_VERSION:-v0.6.7}"
KUBE_VERSION="${KUBE_VERSION:-1.30.0}"

if ! command -v kubeconform >/dev/null 2>&1; then
	echo "kubeconform not on PATH — installing to /tmp"
	tmpdir="$(mktemp -d)"
	os="$(uname | tr '[:upper:]' '[:lower:]')"
	arch="$(uname -m)"
	case "$arch" in
		x86_64) arch=amd64 ;;
		aarch64|arm64) arch=arm64 ;;
	esac
	curl -fsSL "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-${os}-${arch}.tar.gz" \
		| tar -xz -C "$tmpdir"
	export PATH="$tmpdir:$PATH"
fi

fail=0
for cluster in "${CLUSTERS[@]}"; do
	out_dir="${REPO_ROOT}/clusters/${cluster}-raw"
	echo "==> kubeconform: $cluster"

	if [[ ! -d "$out_dir" ]]; then
		echo "    rendering (RAW_HELM=skip) into $out_dir..."
		RAW_HELM=skip make export-raw CLUSTER="$cluster" >/dev/null
	fi

	# Skip the human-readable skipped report.
	if ! find "$out_dir" -name '*.yaml' -not -name '_skipped.md' -print0 \
		| xargs -0 kubeconform \
			-strict \
			-summary \
			-ignore-missing-schemas \
			-kubernetes-version "$KUBE_VERSION" \
			-skip "RawExportSkipped,HelmRenderRequest"
	then
		echo "    FAIL"
		fail=1
	else
		echo "    OK"
	fi
done

exit "$fail"
