#!/usr/bin/env bash
# Golden-file regression test for raw-fallback export.
# Re-renders clusters/<cluster>-raw/ via `make export-raw` and diffs against
# the committed snapshots under tests/raw-export/golden/<cluster>/. Helm
# rendering is intentionally bypassed (RAW_HELM=skip) so goldens stay
# deterministic across helm-chart upgrades — HelmRenderRequest placeholders
# are diffed instead.
#
# Usage:
#   ./ci/scripts/test-raw-export.sh                # check both home + preview
#   ./ci/scripts/test-raw-export.sh home           # check one cluster
#   UPDATE_GOLDENS=1 ./ci/scripts/test-raw-export.sh   # regenerate snapshots

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

CLUSTERS=("$@")
[[ ${#CLUSTERS[@]} -eq 0 ]] && CLUSTERS=(home preview)

GOLDEN_ROOT="${REPO_ROOT}/tests/raw-export/golden"
mkdir -p "$GOLDEN_ROOT"

fail=0
for cluster in "${CLUSTERS[@]}"; do
	echo "==> raw-export golden check: $cluster"
	RAW_HELM=skip make export-raw CLUSTER="$cluster" >/dev/null

	out_dir="${REPO_ROOT}/clusters/${cluster}-raw"
	golden_dir="${GOLDEN_ROOT}/${cluster}"

	if [[ "${UPDATE_GOLDENS:-0}" == "1" ]]; then
		rm -rf "$golden_dir"
		mkdir -p "$golden_dir"
		cp -R "$out_dir/." "$golden_dir/"
		echo "    UPDATED $golden_dir"
		continue
	fi

	if [[ ! -d "$golden_dir" ]]; then
		echo "    NO GOLDEN at $golden_dir — run with UPDATE_GOLDENS=1"
		fail=1
		continue
	fi

	if diff -r "$golden_dir" "$out_dir" >/dev/null; then
		echo "    OK"
	else
		echo "    DRIFT detected:"
		diff -r "$golden_dir" "$out_dir" | sed 's/^/      /'
		fail=1
	fi
done

exit "$fail"
