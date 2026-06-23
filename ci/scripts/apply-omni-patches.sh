#!/usr/bin/env bash
# Apply every Talos ConfigPatch payload under infrastructure/talos/configpatches/
# as Omni ConfigPatch resources for a given cluster. Idempotent — Omni
# diffs the spec and only triggers a kubelet/apiserver restart when the
# content actually changed.
#
# Why this exists:
#   Omni ConfigPatches don't carry through a cluster rebuild. The
#   kubelet-cert-rotation patch (authored 2026-05-06) was lost in the
#   2026-05-14 talos-home rebuild and not noticed until a stuck-
#   Terminating namespace exposed the gap on 2026-05-15.
#
#   This script makes the patch set version-controlled and re-applyable
#   in one command.
#
# Usage:
#   ./ci/scripts/apply-omni-patches.sh <cluster-name>
#
# Examples:
#   ./ci/scripts/apply-omni-patches.sh talos-home
#   ./ci/scripts/apply-omni-patches.sh talos-preview
#
# Prereqs:
#   - omnictl on PATH and authenticated (`omnictl get cluster` works)

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <cluster-name>" >&2
  exit 2
fi

cluster="$1"

command -v omnictl >/dev/null || { echo "omnictl not on PATH" >&2; exit 2; }

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
payload_dir="${repo_root}/infrastructure/talos/configpatches"

if [[ ! -d "$payload_dir" ]]; then
  echo "No payload dir at $payload_dir" >&2
  exit 2
fi

# Verify cluster exists in Omni
if ! omnictl get cluster "$cluster" >/dev/null 2>&1; then
  echo "Cluster '$cluster' not found in Omni. Run \`omnictl get cluster\` to list." >&2
  exit 2
fi

applied=0
for payload in "$payload_dir"/*.payload.yaml; do
  [[ -e "$payload" ]] || continue
  base=$(basename "$payload" .payload.yaml)
  id="${base}-${cluster}"

  # Build the ConfigPatch envelope. spec.data is a YAML block-scalar
  # containing the payload file contents — indent each line by 8 spaces
  # so it nests correctly under `data: |`.
  envelope_file=$(mktemp)
  trap 'rm -f "$envelope_file"' EXIT
  {
    echo "metadata:"
    echo "    namespace: default"
    echo "    type: ConfigPatches.omni.sidero.dev"
    echo "    id: ${id}"
    echo "    labels:"
    echo "        omni.sidero.dev/cluster: ${cluster}"
    echo "spec:"
    echo "    data: |"
    sed 's/^/        /' "$payload"
  } > "$envelope_file"

  echo "Applying ${id}..."
  omnictl apply -f "$envelope_file"
  applied=$((applied+1))
  rm -f "$envelope_file"
  trap - EXIT
done

echo ""
echo "Done: ${applied} patch(es) reconciled."
echo ""
echo "Verify with:"
echo "  omnictl get configpatch -l omni.sidero.dev/cluster=${cluster}"
