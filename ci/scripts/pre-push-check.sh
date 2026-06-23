#!/usr/bin/env bash
# Pre-push gate — mirrors .github/workflows/ci.yaml + publish.yaml locally so a
# push that would redden CI fails on the developer's machine first.
#
# Run directly (`./ci/scripts/pre-push-check.sh`) or via the installed git hook
# (`make install-hooks` wires .githooks/pre-push to call this).
#
# Skips: actual GHCR push (uses an offline OCI layout instead) and the Node-based
# Copilot review. Everything else matches CI step-for-step.
#
# Escape hatch: `SKIP_PREPUSH=1 git push` bypasses the hook entirely.
set -euo pipefail

# Makefile dev-env gate is for interactive use; CI and this script bypass it.
export SKIP_JARVY_DOCTOR=1

cd "$(git rev-parse --show-toplevel)"

step() { printf '\n\033[1;34m▶ %s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31m✗ pre-push failed: %s\033[0m\n' "$1" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || fail "missing tool '$1' (brew install $1)"; }
for t in cue yq helm pluto oras; do need "$t"; done

# ── CI: validate-and-render ────────────────────────────────────────────────
step "cue vet ./..."
cue vet ./... || fail "cue vet"

step "Render preview cluster (UNIFI=true)"
make export-cluster CLUSTER=preview UNIFI=true || fail "render preview"

step "Raw-fallback — dispatcher coverage check"
./ci/scripts/test-raw-coverage.sh || fail "raw coverage"

step "Raw-fallback — post-processor unit tests"
./ci/scripts/test-postprocessors.sh || fail "post-processors"

step "validate-tool-name — prompt-injection classifier tests"
bash ./ci/scripts/tests/test-validate-tool-name.sh || fail "validate-tool-name"

step "tool-discovery quarantine — no-data-leak integration test"
bash ./ci/scripts/tests/test-quarantine-no-data-leak.sh || fail "quarantine no-data-leak"

step "autofix-dispatch — TRUST_BOUNDARY wrapping test"
bash ./ci/scripts/tests/test-autofix-trust-boundary.sh || fail "autofix trust-boundary"

step "Render raw-fallback (RAW_HELM=skip, both clusters)"
RAW_HELM=skip make export-raw CLUSTER=preview || fail "raw preview"
RAW_HELM=skip make export-raw CLUSTER=home || fail "raw home"

step "Verify raw output has no Crossplane residue"
for cluster in preview home; do
  if grep -rE '^(kind: X|kind: Composition$|kind: CompositeResourceDefinition$)' "clusters/${cluster}-raw/" 2>/dev/null; then
    fail "raw output for $cluster contains Crossplane resources"
  fi
done

step "Raw-export golden regression"
./ci/scripts/test-raw-export.sh || fail "raw golden"

step "Raw-export count parity"
./ci/scripts/test-raw-parity.sh || fail "raw parity"

step "Raw-export validity (kubeconform)"
./ci/scripts/test-raw-validity.sh || fail "raw validity"

step "Scan rendered manifests for deprecated/removed K8s APIs"
make lint-deprecated-apis || fail "deprecated APIs"

step "Render raw-fallback with helm template (smoke)"
make export-raw CLUSTER=home || fail "raw home helm smoke"

step "Verify helm-rendered output replaced HelmRenderRequest placeholders"
if grep -rh '^kind: HelmRenderRequest$' clusters/home-raw/ 2>/dev/null; then
  fail "HelmRenderRequest placeholders remain after helm template"
fi

# ── publish.yaml: offline publish dry-run ──────────────────────────────────
# CI pushes to GHCR; locally we push to an OCI layout in a temp dir, which
# exercises the exact `oras push` path publish.sh runs without needing auth.
step "Publish dry-run (offline OCI layout)"
tmp_oci="$(mktemp -d)"
trap 'rm -rf "$tmp_oci"' EXIT
CLUSTER=preview LOCAL_OUTPUT="$tmp_oci/oci-out" ./ci/scripts/publish.sh || fail "publish dry-run"

printf '\n\033[1;32m✓ pre-push checks passed — safe to push\033[0m\n'
