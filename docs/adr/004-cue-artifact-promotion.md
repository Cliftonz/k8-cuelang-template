# ADR-004: CUE Artifact Promotion via OCI

**Status:** Accepted  
**Date:** 2024-11-01  
**Decision Makers:** Platform Team

## Context

Rendered manifests need a reliable promotion path from CI to spoke clusters. Simply committing rendered YAML to Git works but has drawbacks:

1. Large diffs on every change make code review harder
2. No immutable artifact to reference or roll back to
3. Git-based promotion is hard to gate with approval workflows

Options considered:

1. **Git commit flow** — CI renders and commits YAML, GitOps pulls from branch
2. **OCI artifacts via ORAS** — CI renders, packages as OCI artifact, updates digest reference
3. **Helm chart packaging** — wrap rendered output in a chart and push to chart repo

## Decision

Adopt **OCI artifact promotion via ORAS**.

- CI renders manifests with `cue export`, packages them with `oras push`
- Each cluster's env repo has an `artifact-digest.yaml` referencing the OCI digest
- ArgoCD (or Harness GitOps) uses a CMP plugin to `oras pull` and apply
- Git commit flow is retained as a fallback until OCI source support is fully deployed

### Promotion Flow

```
Author claims → CI validates (cue vet) → CI renders (cue export)
→ Package as OCI artifact (oras push) → Update digest in env repo
→ GitOps syncs to spoke
```

## Consequences

- **Positive:** Immutable artifacts with content-addressable digests
- **Positive:** Smaller Git diffs (only digest changes, not full YAML)
- **Positive:** Natural gate point for approval workflows between environments
- **Negative:** Requires OCI registry infrastructure (Harbor provides this)
- **Negative:** ArgoCD needs CMP plugin for ORAS support until native OCI sources land
