#!/usr/bin/env bash
# Stream filter for raw-fallback export. Reads multi-doc YAML on stdin,
# writes multi-doc YAML on stdout. For each `kind: HelmRenderRequest` doc,
# runs `helm template` with the embedded chart spec and substitutes the
# rendered manifests. All other docs pass through unchanged.
#
# Behavior controlled by RAW_HELM env var:
#   RAW_HELM=render (default) — render via helm template; fail if helm absent.
#   RAW_HELM=skip             — leave HelmRenderRequest docs intact.
#   RAW_HELM=fail             — error if any HelmRenderRequest is present.
#
# Used by: Makefile target `export-raw`.

set -euo pipefail

mode="${RAW_HELM:-render}"

case "$mode" in
	skip)
		cat
		exit 0
		;;
	render|fail) ;;
	*)
		echo "render-helm.sh: unknown RAW_HELM=$mode (want render|skip|fail)" >&2
		exit 1
		;;
esac

if [[ "$mode" == "render" ]] && ! command -v helm >/dev/null 2>&1; then
	echo "render-helm.sh: helm binary not found on PATH. Install helm or set RAW_HELM=skip." >&2
	exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

input="$tmpdir/input.yaml"
cat > "$input"

# Split into per-doc files, then process each.
yq -s '"'"$tmpdir"'/doc-" + ($index | tostring) + ".yaml"' "$input" >/dev/null

shopt -s nullglob
for doc in "$tmpdir"/doc-*.yaml; do
	kind="$(yq -r '.kind // ""' "$doc")"

	if [[ "$kind" != "HelmRenderRequest" ]]; then
		cat "$doc"
		echo "---"
		continue
	fi

	if [[ "$mode" == "fail" ]]; then
		name="$(yq -r '.metadata.name' "$doc")"
		echo "render-helm.sh: HelmRenderRequest '$name' present and RAW_HELM=fail" >&2
		exit 1
	fi

	name="$(yq -r '.metadata.name' "$doc")"
	ns="$(yq -r '.metadata.namespace' "$doc")"
	chart="$(yq -r '.spec.chart.name' "$doc")"
	repo="$(yq -r '.spec.chart.repository' "$doc")"
	version="$(yq -r '.spec.chart.version' "$doc")"
	values="$tmpdir/values-$name.yaml"
	yq '.spec.values' "$doc" > "$values"

	echo "# rendered by helm template: $name (chart=$chart version=$version)"
	if [[ "$repo" == oci://* ]]; then
		# OCI registry: the chart reference is the full <repository>/<name>
		# path and there is NO --repo flag. Passing --repo with an oci://
		# value makes helm treat it as a classic HTTP repo index and fail
		# with "not a valid chart repository or cannot be reached".
		helm template "$name" "${repo}/${chart}" \
			--version "$version" \
			--namespace "$ns" \
			-f "$values" \
			--include-crds
	else
		# Classic HTTP(S) chart repository: chart name + --repo URL.
		helm template "$name" "$chart" \
			--repo "$repo" \
			--version "$version" \
			--namespace "$ns" \
			-f "$values" \
			--include-crds
	fi
	echo "---"
done
