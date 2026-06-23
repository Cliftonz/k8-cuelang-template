# Onboarding

## Add a New Cluster

1. Create a new folder in `composites/` (for example, `composites/dev-02/`).
2. Add `cluster.cue` with the cluster metadata.
3. Add claim files for namespaces, RBAC, quotas, and network policies.
4. Update `export/all.cue` to include the new cluster entry.
5. Add or update the environment repo digest reference for the new cluster.

## Validate and Export

```bash
make validate
make export
```

## Promotion

1. Publish the rendered OCI artifact.
2. Update the digest reference in the target environment repo.
3. Allow GitOps to sync and validate health.
