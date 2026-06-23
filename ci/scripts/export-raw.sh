#!/usr/bin/env bash
# Render a cluster's Crossplane-free "raw fallback" manifests.
#
# Extracted from the Makefile so the render pipeline runs under
# `set -o pipefail`: if render-helm.sh (or any stage) fails — e.g. a Helm
# chart that cannot be pulled — the whole export fails loudly instead of the
# error being swallowed by the final split-manifests stage, which would
# otherwise silently drop the failed chart and every document after it.
#
# Usage: ci/scripts/export-raw.sh <cluster>
#   RAW_HELM env (render|skip|fail) is honored by render-helm.sh.
set -euo pipefail

cluster="${1:?Usage: export-raw.sh <cluster>}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "${script_dir}/../.." && pwd)"
cd "$root_dir"

out="clusters/${cluster}-raw"
rm -rf "$out"
mkdir -p "$out"

echo "Exporting ${cluster} (raw fallback mode)..."
cue export ./export/ -e manifestsRaw -t cluster="${cluster}" --out yaml \
  | yq '.[]' \
  | awk 'BEGIN{n=0} /^apiVersion:/{if(n)print "---"; n++} {print}' \
  | ./ci/scripts/render-helm.sh \
  | ./ci/scripts/strip-skipped.sh "$out" \
  | ./ci/scripts/split-manifests.sh "$out"
