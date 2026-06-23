# ADR-005: Raw-YAML Fallback Mode for Crossplane-free Clusters

**Status:** Accepted  
**Date:** 2026-04-28  
**Decision Makers:** Platform Team

## Context

The default export pipeline produces Crossplane XRDs, Compositions, and
`X*` claim CRs that require Crossplane plus `provider-kubernetes` and
`provider-helm` on the target cluster to reconcile into real Kubernetes
objects.

There are operational situations where running Crossplane on the target
cluster is not viable:

1. Managed Kubernetes services that disallow installing arbitrary CRDs.
2. Edge or customer-owned clusters where adding a control plane is
   out of scope.
3. `kind` / CI smoke clusters where a one-shot apply is preferable to
   a reconciliation loop.
4. Disaster-recovery rebuild before the seed cluster is back up.
5. Air-gapped environments where the Crossplane provider runtimes
   cannot pull function images.

We needed a way to keep the existing CUE-authored composite inputs as
the single source of truth while also being able to ship vanilla
Kubernetes YAML that any cluster can apply with `kubectl`.

## Options Considered

1. **Run `crossplane render` CLI offline.** Use the canonical
   Crossplane CLI to expand each claim against its Composition.
   - **Pros:** semantic fidelity to the runtime reconciler; future-proof
     against patch-and-transform changes.
   - **Cons:** adds an external binary dependency in CI; requires the
     `function-patch-and-transform` runner to be installable locally;
     output still needs unwrapping (provider-kubernetes `Object` →
     inner manifest); breaks the CUE-only export determinism.

2. **Generic CUE-side patch-and-transform interpreter.** Reimplement
   the patch types (`FromCompositeFieldPath`, `CombineFromComposite`,
   `MergeObjects`, `Optional`) as CUE definitions that walk the
   Composition spec.
   - **Pros:** stays in CUE; integrates with existing `cue vet` and
     `cue export` toolchain.
   - **Cons:** CUE has no native dotted-path-with-bracket-notation
     parser, so the implementation requires a tokenizer plus recursive
     `#Set` definitions; significant complexity for what is essentially
     reverse-engineering a Crossplane internal API.

3. **Per-resource render templates in CUE.** Author a
   `#Render<Kind>` definition for each composite type that maps the
   composite input directly to the expanded manifest.
   - **Pros:** trivially readable CUE; type-checked end-to-end; no
     path parsing; integrates with existing toolchain; each renderer
     is independently testable.
   - **Cons:** duplicates the projection logic that already lives in
     `platform/compositions/<resource>.cue` patches; the two paths
     can drift.

## Decision

Adopt **option 3 — per-resource render templates** under
[libs/render/](../../libs/render/), one `#Render<Kind>` definition per
composite type, plus an `export/raw.cue` dispatcher and an
`export-raw` Makefile target. Drift between the rendered output and
the Composition is caught by golden-file tests committed under
`tests/raw-export/golden/` and validated in CI.

### Rationale

The drift risk is real but bounded. The renderers are short
(~30 lines each); the Compositions they mirror are also short; both
are audited side-by-side in code review when either changes. Golden
tests that compare the two outputs for a fixed set of composite
inputs catch any divergence before merge.

The complexity of options 1 and 2 — adding an external binary or
building a path-parser-plus-patch-interpreter in CUE — is not justified
for a fallback mode. Option 3 is the simplest design that delivers the
feature, leaves the default Crossplane mode untouched, and reuses the
existing CUE-export determinism.

### What Ships in Raw Mode

| Category | Coverage |
| --- | --- |
| In-cluster Object wrappers (~95% of XRDs) | Expanded to the inner manifest. |
| Helm releases | Inlined via `helm template` post-processor. |
| Server-side-apply patches (`XObjectPatch`, `XNodeTaint`) | Skipped, surfaced in `_skipped.md` with manual replacement guidance. |
| External-API providers (`XHarborRegistry`, `XHarborProject`) | Skipped, surfaced in `_skipped.md`. |

### What Stays Out of Scope

- Replacing Crossplane mode. The default `make export` /`make apply`
  targets are unchanged.
- Reimplementing the entire `function-patch-and-transform` spec. Only
  the patch behaviors actually used in this repo are mirrored.

## Consequences

**Positive:**

- Spokes that cannot run Crossplane can now be brought up from the same
  CUE source.
- The fallback path is fast: no Crossplane install, no provider runtime,
  no reconciliation hop. Apply is deterministic.
- CI validates both modes against the same composites, so contract
  drift is detected at PR time.

**Negative:**

- A new resource type requires changes in two places: the Composition
  in `platform/compositions/` and a renderer in `libs/render/`.
- Operators have two output directories (`clusters/<name>/` and
  `clusters/<name>-raw/`) and have to know which one their target
  cluster expects. Mitigated by directory naming and CLAUDE.md
  documentation.

## Implementation

- [libs/render/](../../libs/render/) — per-resource render templates.
- [export/raw.cue](../../export/raw.cue) — dispatcher.
- [ci/scripts/render-helm.sh](../../ci/scripts/render-helm.sh) — Helm post-processor.
- [ci/scripts/strip-skipped.sh](../../ci/scripts/strip-skipped.sh) — skipped-resource reporter.
- [Makefile](../../Makefile) — `export-raw`, `apply-raw` targets.
- [docs/raw-fallback.md](../raw-fallback.md) — operational guide.

## References

- [docs/why-crossplane-cue.md](../why-crossplane-cue.md)
- [docs/why-crossplane-hub-spoke.md](../why-crossplane-hub-spoke.md)
- [ADR-001: Crossplane Hub-and-Spoke](001-crossplane-hub-and-spoke.md)
- [ADR-004: CUE Artifact Promotion via OCI](004-cue-artifact-promotion.md)
