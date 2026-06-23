# ADR-002: CUE for Schema Validation and YAML Generation

**Status:** Accepted  
**Date:** 2024-09-20  
**Decision Makers:** Platform Team

## Context

Crossplane XRDs and Compositions are verbose YAML. We need a way to:

1. Validate inputs at build time (before applying to the cluster)
2. Generate deterministic YAML from structured inputs
3. Enforce contracts (tier defaults, naming conventions, required labels)
4. Avoid drift between environments

Options considered:

1. **Raw YAML + kustomize** — overlay-based, no schema validation
2. **Jsonnet** — functional language with templating, weak typing
3. **CUE** — typed configuration language with built-in validation and unification

## Decision

Adopt **CUE** for all schema definitions, validation, and YAML generation.

- CUE schemas define contracts (`#TierConfig`, `#ClusterConfig`, `#StandardMetadata`)
- `cue vet ./...` runs in CI to catch errors before render
- `cue export ./export/` generates the final YAML manifests
- CUE is build-time only; no CUE runs in the cluster

## Consequences

- **Positive:** Type-safe configuration with compile-time error detection
- **Positive:** Unification ensures inputs always satisfy tier constraints
- **Positive:** Single source of truth for both XRD schemas and composite inputs
- **Negative:** CUE has a learning curve, especially around unification semantics
- **Negative:** CUE tooling is less mature than Helm/kustomize ecosystems
