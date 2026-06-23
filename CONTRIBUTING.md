# Contributing

Thanks for your interest in improving this template.

## Ground rules

- **Everything is CUE-first.** Author intent in `composites/`, `libs/`, and
  `platform/`. Never hand-edit rendered YAML under `clusters/` — it is generated.
- **Validate before you push.** `make validate` (CUE vet) and `make test-raw`
  (golden regression + lint) must pass. Install the pre-push hook with
  `make install-hooks`.
- **No secrets in git.** Secret *values* live in your secret store and are pulled
  by External Secrets Operator. Commit only `ExternalSecret` references, never the
  underlying credential. See [docs/secret-management.md](docs/secret-management.md).
- **Use the full module path for imports.** `github.com/k8-infra/libs/tiers`, never
  a file-relative import.

## Development loop

```bash
make setup            # install the pinned toolchain (cue, yq, helm, kubectl, …)
make validate         # cue vet ./...
make export-cluster CLUSTER=home   # render one cluster while iterating
make test-raw         # full raw-fallback suite before pushing
```

## Updating golden snapshots

If a deliberate change alters rendered output, regenerate the byte-stable goldens:

```bash
UPDATE_GOLDENS=1 ./ci/scripts/test-raw-export.sh
```

Review the diff carefully — an unexpected golden change usually means an
unintended change to a Composition or composite.

## Conventions

- Resource names match `^[a-z][a-z0-9-]*$`.
- All XRDs use group `infra.k8`, version `v1alpha1`.
- Standard labels (`app.kubernetes.io/managed-by`, tier, cluster, owner) are
  enforced via `libs/k8s/metadata.cue`.
- See [CLAUDE.md](CLAUDE.md) for the full command and convention reference.
