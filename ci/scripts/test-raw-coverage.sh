#!/usr/bin/env bash
# Dispatcher coverage check. Asserts that every composite type registered
# in `_xrdMap` (export/all.cue) has a corresponding `for ... in _c.<field>`
# clause in `export/raw.cue`. Catches the silent-gap regression where a
# dev adds a new XRD to the Crossplane path and forgets to wire a renderer
# for the raw fallback path.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

# Pull composite-list field names out of the _xrdMap struct.
xrd_keys=$(awk '
	/^_xrdMap: \{/        { in_map=1; next }
	in_map && /^}/        { in_map=0 }
	in_map && /^\t[a-zA-Z]+: \{/ { sub(/:.*/, ""); sub(/^\t/, ""); print }
' export/all.cue | sort -u)

# Pull dispatch keys out of raw.cue.
raw_keys=$(grep -oE 'for [a-zA-Z]+ in _c\.[a-zA-Z]+' export/raw.cue \
	| awk '{print $NF}' | sed 's|^_c\.||' | sort -u)

missing=$(comm -23 <(echo "$xrd_keys") <(echo "$raw_keys") || true)

if [[ -n "$missing" ]]; then
	echo "raw-coverage FAIL — composite types in _xrdMap but missing from export/raw.cue dispatcher:"
	echo "$missing" | sed 's/^/  - /'
	echo
	echo "Add a renderer in libs/render/<resource>.cue and a dispatch line"
	echo "in export/raw.cue for each, OR (if intentionally skipped) emit a"
	echo "RawExportSkipped placeholder via libs/render/skipped.cue."
	exit 1
fi

extra=$(comm -13 <(echo "$xrd_keys") <(echo "$raw_keys") || true)
if [[ -n "$extra" ]]; then
	echo "raw-coverage WARN — dispatch lines reference composite types not in _xrdMap:"
	echo "$extra" | sed 's/^/  - /'
fi

echo "raw-coverage OK — all $(echo "$xrd_keys" | wc -l | tr -d ' ') composite types have a renderer dispatch"
