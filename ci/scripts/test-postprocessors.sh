#!/usr/bin/env bash
# Unit tests for the raw-fallback post-processors:
#   ci/scripts/render-helm.sh
#   ci/scripts/strip-skipped.sh
#
# Exercises the edge cases the goldens don't cover: empty input,
# all-skipped streams, RAW_HELM=skip|fail|garbage, missing outdir arg,
# pass-through fidelity, and exit codes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

pass=0
fail=0

assert() {
	local desc="$1" actual="$2" expected="$3"
	if [[ "$actual" == "$expected" ]]; then
		echo "  PASS: $desc"
		pass=$((pass + 1))
	else
		echo "  FAIL: $desc"
		echo "    expected: $expected"
		echo "    actual:   $actual"
		fail=$((fail + 1))
	fi
}

assert_contains() {
	local desc="$1" haystack="$2" needle="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		echo "  PASS: $desc"
		pass=$((pass + 1))
	else
		echo "  FAIL: $desc — expected to contain '$needle'"
		echo "    actual: $haystack"
		fail=$((fail + 1))
	fi
}

# ---------------------------------------------------------------------------
echo "=== render-helm.sh ==="

# 1. RAW_HELM=skip: empty stdin → empty stdout
out="$(printf '' | RAW_HELM=skip ./ci/scripts/render-helm.sh 2>&1)"
assert "skip mode, empty stdin → empty stdout" "$out" ""

# 2. RAW_HELM=skip: non-Helm doc passes through
ns_doc='apiVersion: v1
kind: Namespace
metadata:
  name: foo'
out="$(printf '%s' "$ns_doc" | RAW_HELM=skip ./ci/scripts/render-helm.sh 2>/dev/null)"
assert_contains "skip mode passthrough" "$out" "kind: Namespace"

# 3. RAW_HELM=skip: HelmRenderRequest passes through (not rendered)
hrr='apiVersion: k8-infra/raw-fallback/v1alpha1
kind: HelmRenderRequest
metadata:
  name: test
  namespace: default
spec:
  chart:
    name: nothing
    repository: https://example.invalid
    version: 0.0.0
  values: {}'
out="$(printf '%s' "$hrr" | RAW_HELM=skip ./ci/scripts/render-helm.sh 2>/dev/null)"
assert_contains "skip mode preserves HelmRenderRequest" "$out" "kind: HelmRenderRequest"

# 4. RAW_HELM=fail with HelmRenderRequest → exit nonzero
printf '%s' "$hrr" | RAW_HELM=fail ./ci/scripts/render-helm.sh >/dev/null 2>&1
ec=$?
assert "fail mode with HelmRenderRequest exits nonzero" "$ec" "1"

# 5. RAW_HELM=fail without HelmRenderRequest → pass through, exit 0
printf '%s' "$ns_doc" | RAW_HELM=fail ./ci/scripts/render-helm.sh >/dev/null 2>&1
ec=$?
assert "fail mode without HelmRenderRequest exits 0" "$ec" "0"

# 6. Bogus RAW_HELM value → exit nonzero
RAW_HELM=garbage ./ci/scripts/render-helm.sh </dev/null >/dev/null 2>&1
ec=$?
assert "unknown RAW_HELM mode exits nonzero" "$ec" "1"

# ---------------------------------------------------------------------------
echo "=== strip-skipped.sh ==="

tmpout="$(mktemp -d)"
trap 'rm -rf "$tmpout"' EXIT

# 1. Empty stdin → empty stdout, report says nothing skipped
out="$(printf '' | ./ci/scripts/strip-skipped.sh "$tmpout/empty" 2>/dev/null)"
assert "empty stdin → empty stdout" "$out" ""
assert_contains "empty stream report" "$(cat "$tmpout/empty/_skipped.md")" "All resources rendered"

# 2. Non-skipped stream → passes through, report says nothing skipped
out="$(printf '%s\n---\n' "$ns_doc" | ./ci/scripts/strip-skipped.sh "$tmpout/none" 2>/dev/null)"
assert_contains "non-skipped passthrough" "$out" "kind: Namespace"
assert_contains "non-skipped stream report" "$(cat "$tmpout/none/_skipped.md")" "All resources rendered"

# 3. Stream with RawExportSkipped → stripped, report has entry
skipped='apiVersion: k8-infra/raw-fallback/v1alpha1
kind: RawExportSkipped
metadata:
  name: my-patch
spec:
  originalKind: XObjectPatch
  reason: test reason
  replacement: |
    do the manual thing'
mixed="$ns_doc"$'\n---\n'"$skipped"
out="$(printf '%s\n' "$mixed" | ./ci/scripts/strip-skipped.sh "$tmpout/mixed" 2>/dev/null)"
assert_contains "mixed stream keeps non-skipped" "$out" "kind: Namespace"
if [[ "$out" == *"RawExportSkipped"* ]]; then
	echo "  FAIL: mixed stream leaked RawExportSkipped doc to stdout"
	fail=$((fail + 1))
else
	echo "  PASS: mixed stream strips RawExportSkipped"
	pass=$((pass + 1))
fi
assert_contains "mixed report includes original kind" "$(cat "$tmpout/mixed/_skipped.md")" "XObjectPatch"
assert_contains "mixed report includes name" "$(cat "$tmpout/mixed/_skipped.md")" "my-patch"
assert_contains "mixed report includes replacement" "$(cat "$tmpout/mixed/_skipped.md")" "do the manual thing"

# 4. All-skipped stream → empty stdout, report has entry
out="$(printf '%s\n' "$skipped" | ./ci/scripts/strip-skipped.sh "$tmpout/all" 2>/dev/null)"
if [[ "$out" =~ [^[:space:]] ]]; then
	echo "  FAIL: all-skipped stream produced non-empty stdout: $out"
	fail=$((fail + 1))
else
	echo "  PASS: all-skipped stream produces empty stdout"
	pass=$((pass + 1))
fi
assert_contains "all-skipped report has entry" "$(cat "$tmpout/all/_skipped.md")" "XObjectPatch"

# 5. Missing outdir arg → exit nonzero
./ci/scripts/strip-skipped.sh </dev/null >/dev/null 2>&1
ec=$?
assert "missing outdir arg exits nonzero" "$ec" "1"

# ---------------------------------------------------------------------------
echo
echo "$pass passed, $fail failed"
exit "$fail"
