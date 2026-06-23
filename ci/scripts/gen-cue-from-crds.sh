#!/usr/bin/env bash
# Generate CUE definitions from Kubernetes CRDs in a given API group.
#
# For every CRD whose group matches GROUP_FILTER, extracts the
# OpenAPIV3Schema for each served version and converts it to CUE via
# `cue import jsonschema:`. Writes one CUE file per (kind, version)
# pair into OUT_DIR.
#
# Usage:
#   ./ci/scripts/gen-cue-from-crds.sh kelos.dev libs/k8s/kelos/generated
#   ./ci/scripts/gen-cue-from-crds.sh metallb.io libs/k8s/metallb/generated
#
# Re-run after upgrading an upstream operator to refresh the CUE schemas.
# Commit the diff so PRs show CRD shape changes explicitly.

set -euo pipefail

GROUP_FILTER="${1:-}"
OUT_DIR="${2:-}"
PACKAGE_NAME="${3:-generated}"

if [[ -z "$GROUP_FILTER" || -z "$OUT_DIR" ]]; then
  echo "Usage: $0 <group-filter> <out-dir> [package-name]" >&2
  echo "  group-filter   Kubernetes API group to match (e.g. kelos.dev)" >&2
  echo "  out-dir        Output directory for CUE files" >&2
  echo "  package-name   CUE package declaration (default: generated)" >&2
  exit 2
fi

command -v kubectl >/dev/null 2>&1 || { echo "kubectl required" >&2; exit 1; }
command -v cue     >/dev/null 2>&1 || { echo "cue required"     >&2; exit 1; }
command -v jq      >/dev/null 2>&1 || { echo "jq required"      >&2; exit 1; }

mkdir -p "$OUT_DIR"

crds=$(kubectl get crd -o json \
  | jq -r --arg g "$GROUP_FILTER" '.items[] | select(.spec.group == $g) | .metadata.name')

if [[ -z "$crds" ]]; then
  echo "no CRDs found in group $GROUP_FILTER" >&2
  exit 1
fi

written=0
for crd in $crds; do
  raw=$(kubectl get crd "$crd" -o json)
  group=$(jq -r '.spec.group' <<<"$raw")
  kind=$(jq -r '.spec.names.kind' <<<"$raw")

  versions=$(jq -r '.spec.versions[] | select(.served == true) | .name' <<<"$raw")
  for ver in $versions; do
    schema=$(jq --arg v "$ver" '.spec.versions[] | select(.name == $v) | .schema.openAPIV3Schema' <<<"$raw")
    [[ "$schema" == "null" || -z "$schema" ]] && {
      echo "skip $crd@$ver (no schema)"
      continue
    }

    tmpjson=$(mktemp)
    echo "$schema" > "$tmpjson"

    out_file="$OUT_DIR/$(echo "${kind}_${ver}" | tr '[:upper:]' '[:lower:]').cue"
    label="#${kind}:"

    cue import -f jsonschema: "$tmpjson" \
      -p "$PACKAGE_NAME" \
      -l "$label" \
      --outfile="$out_file"

    tmpcue=$(mktemp)
    cat > "$tmpcue" <<HEADER
// Code generated from CRD ${crd} (${group}/${ver}); DO NOT EDIT.
// Source: kubectl get crd ${crd} -o json
// Regenerate: ./ci/scripts/gen-cue-from-crds.sh ${GROUP_FILTER} ${OUT_DIR}
HEADER
    cat "$out_file" >> "$tmpcue"
    mv "$tmpcue" "$out_file"

    rm -f "$tmpjson"
    written=$((written+1))
    echo "  → $out_file"
  done
done

echo ""
echo "Wrote $written CUE definitions to $OUT_DIR"
echo "Run 'cd \$(git rev-parse --show-toplevel) && cue vet ./...' to validate."
