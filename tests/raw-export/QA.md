# Raw-Fallback QA Report

Coverage assessment for [docs/raw-fallback.md](../../docs/raw-fallback.md)
and [docs/adr/005-raw-yaml-fallback.md](../../docs/adr/005-raw-yaml-fallback.md).

## Test Suite

`make test-raw` runs the full suite locally. Each layer also runs in CI on
every PR via [.github/workflows/ci.yaml](../../.github/workflows/ci.yaml).

| Test | Script | Catches |
| --- | --- | --- |
| Schema validation | `cue vet ./...` (existing) | Type errors in renderers and dispatcher. |
| Dispatcher coverage | [test-raw-coverage.sh](../../ci/scripts/test-raw-coverage.sh) | New XRD added to `_xrdMap` without a renderer dispatch line in [export/raw.cue](../../export/raw.cue). |
| Post-processor unit tests | [test-postprocessors.sh](../../ci/scripts/test-postprocessors.sh) | Edge cases in [render-helm.sh](../../ci/scripts/render-helm.sh) and [strip-skipped.sh](../../ci/scripts/strip-skipped.sh): empty input, all-skipped, all-helm, `RAW_HELM=skip\|fail\|render\|garbage`, missing args. |
| Crossplane-residue grep | inline in CI | `kind: X*`, `kind: Composition`, `kind: CompositeResourceDefinition` slipping into raw output. |
| Golden regression | [test-raw-export.sh](../../ci/scripts/test-raw-export.sh) | Byte-level drift in raw output for either cluster. Goldens use `RAW_HELM=skip` for determinism. |
| Count parity | [test-raw-parity.sh](../../ci/scripts/test-raw-parity.sh) | Renderer dropped half the inputs silently. 60 assertions across home + preview, every composite-list field. |
| OpenAPI validity | [test-raw-validity.sh](../../ci/scripts/test-raw-validity.sh) | Output that is well-formed YAML but rejected by kube-apiserver. Uses `kubeconform` against real K8s schemas; CRDs without published schema fall through to `--ignore-missing-schemas`. |
| Helm-template smoke | inline in CI (`make export-raw CLUSTER=home`, no `RAW_HELM`) | `helm template` failures, network/chart-resolution issues, leaked `HelmRenderRequest` placeholders after rendering. |
| Bootstrap `--raw` plumbing | manual: `bootstrap-home.sh --check-only --raw` | Flag parsing, phase-skip wiring. |

## Bug Caught and Fixed During QA

[ci/scripts/strip-skipped.sh](../../ci/scripts/strip-skipped.sh) emitted a
stray `---` to stdout on empty input because `yq -s` materializes a single
empty document for a zero-byte stream. Fixed by short-circuiting on
empty input. Caught by `test-postprocessors.sh` test case 1.

## Numbers

Last green run, against working tree at writing time:

| Cluster | RAW_HELM | Manifests | Skipped | kubeconform Valid / Invalid / Errors | Skipped (no CRD schema) |
| --- | --- | --- | --- | --- | --- |
| home | skip | 145 | 2 | 79 / 0 / 0 | 66 |
| home | render | 361 | 2 | (covered by inline residue check, full kubeconform sweep deferred — chart output volume) | — |
| preview | skip | 103 | 2 | 44 / 0 / 0 | 59 |

Tests passing: **18** post-processor + **33** coverage + **60** count-parity
+ **2** golden + **2** validity = **115** assertions, in addition to
existing `cue vet` whole-repo type checking.

## Gaps Acknowledged but Not Yet Closed

These are documented and tracked rather than silently accepted.

### 1. Semantic parity with `crossplane render`

**What it would catch:** divergence between the CUE renderer and the
canonical Crossplane reconciler for the same composite input. The
renderer mirrors each Composition's patches by construction, but a hand-
authored renderer can drift from a hand-authored Composition without any
test catching it (only the rendered output is compared, and only against
its own past self).

**Status:** scaffold present in [test-raw-parity.sh](../../ci/scripts/test-raw-parity.sh)
under `=== semantic parity (crossplane render) ===`. Skipped silently
when `crossplane` binary is absent. Full implementation requires:
1. `crossplane render <claim> <composition> <functions.yaml>` against
   each composite instance.
2. Unwrap `kubernetes.crossplane.io/v1alpha2 Object` →
   `spec.forProvider.manifest`.
3. Diff against the matching raw-mode manifest, normalizing for
   owner-ref differences (raw mode has none).

**Why deferred:** non-trivial, and the count-parity + kubeconform +
golden tests already give substantial coverage of "the renderer
produces the right output for the right input."

### 2. End-to-end `kubectl apply --dry-run=server`

**What it would catch:** admission-webhook rejections (PSA, OPA Gatekeeper,
Kyverno) that kubeconform does not model.

**Status:** not implemented. CI does not stand up a kind cluster for
the raw bundle. The existing [.github/workflows/e2e.yaml](../../.github/workflows/e2e.yaml)
flow could be extended.

**Why deferred:** kubeconform catches the largest class of validity
bugs (apiVersion/kind/spec shape). Server-side dry-run requires a real
cluster and the operators that own the CRDs — the same prerequisites
the raw-fallback README lists. Adding this gate doubles CI time for
incremental insurance.

### 3. Helm-rendered output kubeconform sweep

**What it would catch:** chart bugs that produce invalid manifests.

**Status:** the helm-template smoke in CI verifies *rendering succeeds*
and *no HelmRenderRequest placeholders survive*, but does not run the
rendered output through kubeconform.

**Why deferred:** chart authors are the right people to catch chart
bugs; we would mostly be re-validating upstream charts (MetalLB, ESO,
ArgoCD). Cheap to add — just point [test-raw-validity.sh](../../ci/scripts/test-raw-validity.sh)
at the helm-rendered tree — but produces a lot of noise from
upstream-CRD-schema gaps.

### 4. Per-renderer fixture unit tests

**What it would catch:** regressions in a specific `#Render<Kind>`
template independent of whether composite inputs exercise that path.

**Status:** not implemented. Coverage relies on home + preview composites
exercising every renderer.

**Why deferred:** the count-parity test already asserts that each
`_xrdMap` entry produces the expected number of outputs in raw mode,
and the goldens lock in the byte-level output. Together these cover the
practical drift surface. Per-renderer fixtures would add a third copy of
the projection logic (input → expected output) without catching anything
the existing two layers miss — unless a future XRD has zero composite
instances on either cluster, in which case it would not be exercised
today. Easy to add later if such a case arises.

### 5. Fault injection for `helm template`

**What it would catch:** non-zero `helm template` exit (network outage,
typo in repo URL, version not found) bubbling correctly to make exit
code.

**Status:** not implemented.

**Why deferred:** straightforward, low priority. Could be added to
[test-postprocessors.sh](../../ci/scripts/test-postprocessors.sh)
with a stub `helm` binary on `PATH`.

## Running

```bash
# All raw-fallback tests, fast (no network):
make test-raw

# Individual layers:
make test-raw-coverage         # dispatcher coverage
make test-raw-postprocessors   # render-helm.sh + strip-skipped.sh edge cases
make test-raw-goldens          # byte-stable regression
make test-raw-parity           # count parity (renderer-vs-input)
make test-raw-validity         # kubeconform — installs to /tmp if missing

# Refresh goldens after intentional change to a renderer or composite:
UPDATE_GOLDENS=1 ./ci/scripts/test-raw-export.sh
```

## Verdict

The feature is well tested for the operational claims in
[docs/raw-fallback.md](../../docs/raw-fallback.md):

- Output is valid Kubernetes YAML (kubeconform).
- Output is byte-stable across runs (goldens).
- Output count matches input count for every composite type (parity).
- Crossplane CRs do not leak into raw output (residue check).
- Post-processors are correct on edge cases including empty/all-skipped
  streams and bad env-var values (post-processor units).
- Adding a new XRD without a renderer is caught at PR time
  (coverage check).
- The Helm-template path actually runs in CI and does not regress
  (helm-template smoke).

The remaining gaps are documented above and represent a defensible
tradeoff between insurance and CI runtime.
