#!/usr/bin/env bash
# Stream filter for raw-fallback export. Pulls every `kind: RawExportSkipped`
# doc out of stdin and writes a human-readable report to
# clusters/<cluster>-raw/_skipped.md. The remaining docs pass through to
# stdout for the normal apply pipeline.
#
# Usage: yq stream | strip-skipped.sh <output-dir>
#   The first arg is the directory where _skipped.md is written.

set -euo pipefail

outdir="${1:?usage: strip-skipped.sh <output-dir>}"
mkdir -p "$outdir"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

input="$tmpdir/input.yaml"
cat > "$input"

skipped_file="$outdir/_skipped.md"

# Empty input — write the report and exit clean. yq -s on a zero-byte
# stream creates a single empty doc, which then trips the kind-empty
# branch in the loop and emits a stray `---`. Short-circuit here.
if [[ ! -s "$input" ]]; then
	echo "_All resources rendered. Nothing skipped._" > "$skipped_file"
	echo "strip-skipped.sh: 0 skipped, report at $skipped_file" >&2
	exit 0
fi
{
	echo "# Resources Not Rendered (raw-fallback mode)"
	echo
	echo "These resource types have no kubectl-applyable equivalent. Apply the"
	echo "rest of the bundle, then handle each entry below manually."
	echo
} > "$skipped_file"

# Split into per-doc files.
yq -s '"'"$tmpdir"'/doc-" + ($index | tostring) + ".yaml"' "$input" >/dev/null

skipped_count=0
shopt -s nullglob
for doc in "$tmpdir"/doc-*.yaml; do
	kind="$(yq -r '.kind // ""' "$doc")"

	if [[ "$kind" != "RawExportSkipped" ]]; then
		cat "$doc"
		echo "---"
		continue
	fi

	skipped_count=$((skipped_count + 1))
	name="$(yq -r '.metadata.name' "$doc")"
	original="$(yq -r '.spec.originalKind' "$doc")"
	reason="$(yq -r '.spec.reason' "$doc")"
	replacement="$(yq -r '.spec.replacement' "$doc")"

	{
		echo "## $original \`$name\`"
		echo
		echo "**Reason:** $reason"
		echo
		echo "**Replacement:**"
		echo
		echo '```'
		echo "$replacement"
		echo '```'
		echo
		if yq -e '.spec.details' "$doc" >/dev/null 2>&1; then
			echo "**Details:**"
			echo
			echo '```yaml'
			yq '.spec.details' "$doc"
			echo '```'
			echo
		fi
	} >> "$skipped_file"
done

if [[ "$skipped_count" -eq 0 ]]; then
	# No skipped resources — replace report with a single-line note.
	echo "_All resources rendered. Nothing skipped._" > "$skipped_file"
fi

echo "strip-skipped.sh: $skipped_count skipped, report at $skipped_file" >&2
