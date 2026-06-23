# Using this template

This repo is a worked example you adapt, not a library you install. The fastest
path from fork to your-own-clusters is below.

## 1. Fork and rename

Click **Use this template** on GitHub (or fork). The CUE module path is
`github.com/k8-infra` (declared in [`cue.mod/module.cue`](../cue.mod/module.cue));
it is a stable identifier and does **not** need to match your GitHub URL, so you can
leave it as-is. If you prefer to rename it, change `module.cue` and run a
project-wide replace of the import prefix `github.com/k8-infra/` — there are ~190
import sites, so do it in one mechanical pass and re-run `make validate`.

## 2. Replace the placeholders

Every identifying value is a placeholder. The [README placeholder table](../README.md#placeholders-replace-before-use)
lists them all. The high-frequency ones:

```bash
# Example: point the template at your own domains and org
grep -rl 'example.com'      . | xargs sed -i '' 's/example\.com/yourcompany.com/g'
grep -rl 'example.internal' . | xargs sed -i '' 's/example\.internal/yourcompany.internal/g'
grep -rl 'example-org'      . | xargs sed -i '' 's/example-org/yourorg/g'
```

> On Linux use `sed -i` (no `''`). Re-run `make validate` after each sweep —
> resource names must still match `^[a-z][a-z0-9-]*$`.

Then update the network ranges (`192.168.1.x` / `.2.x` / `.3.x`), cluster names
(`talos-home`, `talos-preview`), and the opaque IDs to your real values.

## 3. Wire your secret store

No secret values live in git. Each `ExternalSecret` points at a path in a secret
store (the examples use OpenBao; any [ESO provider](https://external-secrets.io)
works). Two things to do:

1. Install ESO and a `ClusterSecretStore` (see `composites/*/clustersecretstores.cue`).
2. Populate the referenced paths in your store with your real values.

Full walkthrough: [secret-management.md](secret-management.md).

## 4. Learn from the example clusters

| Look at | To learn |
|---|---|
| `composites/home/namespaces.cue`, `rbac.cue`, `resourcequotas.cue`, `networkpolicies.cue` | The four core platform APIs and the tier system |
| `composites/home/ingresses.cue` + `helmreleases.cue` | Ingress/TLS and Helm-chart delivery through Crossplane |
| `composites/home/externalsecrets.cue` | Secret references via ESO |
| `composites/home/argocd.cue`, `argoevents.cue` | A GitOps + event-driven automation stack |
| `composites/preview/` | Ephemeral per-PR preview environments via ApplicationSets |
| `libs/tiers/*.cue` | How `dev` / `staging` / `production` change quotas + policy |

## 5. Add your own cluster

The mechanical steps (create `composites/<name>/`, register it in `export/all.cue`,
add a gitops digest, validate) are in [onboarding.md](onboarding.md).

The shortest possible cluster is just a `cluster.cue` (metadata + tier) plus one
composite list (e.g. `namespaces.cue`). Start there, render with
`make export-cluster CLUSTER=<name>`, and grow it.

## 6. Render and apply

```bash
make validate                       # always first
make export-cluster CLUSTER=<name>  # Crossplane mode (XRDs + Compositions + claims)
make export-raw  CLUSTER=<name>     # raw mode (flat manifests, no Crossplane)
make diff                           # see what would change vs clusters/
```

Pick the mode that matches your target ([raw-fallback.md](raw-fallback.md) explains
the trade-off). Wire `make export` (or the raw equivalent) into your CI so rendered
YAML is produced from validated CUE on every change.

## 7. Bootstrapping a fresh cluster

The `ci/scripts/bootstrap-*.sh` scripts show a phased, idempotent bring-up
(preflight → storage → operators → Crossplane → render → apply). They encode a
specific Talos/Omni homelab; treat them as a reference for sequencing your own
bootstrap rather than running them verbatim. See [cluster-setup.md](cluster-setup.md).
