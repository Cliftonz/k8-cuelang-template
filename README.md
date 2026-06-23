# k8-cuelang-template

A production-shaped template for managing Kubernetes cluster infrastructure with
**[CUE](https://cuelang.org)** and **[Crossplane](https://crossplane.io)** in a
hub-and-spoke GitOps model. CUE validates every contract and renders deterministic
YAML at build time — there is no runtime CUE and no untyped Helm sprawl.

This repo is a **fully worked example**, not a skeleton. It ships two real example
clusters (`home`, `preview`), ~30 platform APIs (XRDs + Compositions), a tier-based
policy system, a raw-manifest fallback path, golden regression tests, and CI. Fork
it, replace the placeholder values, and point it at your own clusters.

> [!IMPORTANT]
> **All identifying values in this repo are placeholders.** Before deploying,
> replace them with your own. See [Placeholders](#placeholders-replace-before-use).

---

## Why CUE + Crossplane

- **Typed contracts, not string templates.** Every resource is validated against a
  CUE schema (`libs/`, `platform/xrd/`) before it can render. Bad input fails at
  `make validate`, not at `kubectl apply`.
- **Deterministic build-time rendering.** `cue export` produces byte-stable YAML.
  The same input always yields the same output, which makes golden tests and diff
  review trivial.
- **Hub-and-spoke with Crossplane.** A hub cluster runs the XRDs, Compositions, and
  Providers; spoke clusters consume pre-rendered manifests via GitOps.
- **Escape hatch built in.** `make export-raw` renders flat Kubernetes manifests
  (no Crossplane required on the target) for clusters that only run the underlying
  operators (ESO, MetalLB, Kyverno, Traefik, …). See [docs/raw-fallback.md](docs/raw-fallback.md).

See [docs/architecture.md](docs/architecture.md) for the full design and
[docs/adr/](docs/adr/) for the decision records.

## Repository layout

| Directory | Purpose |
|---|---|
| `platform/xrd/` | Crossplane XRDs — the platform API schemas (namespace, rbac, quota, ingress, helmrelease, externalsecret, …) |
| `platform/compositions/` | Compositions mapping XRD claims → Kubernetes `Object`s |
| `platform/policy/` | Tier-based policy constraints (quota limits, network-policy defaults) |
| `libs/tiers/` | Tier definitions — `dev`, `staging`, `production` |
| `libs/k8s/` | Shared Kubernetes type schemas (metadata, namespace, rbac, …) |
| `composites/{cluster}/` | Per-cluster desired state as composite inputs (CUE) — `home`, `preview`, `shared` |
| `export/` | CI entry point — `export/all.cue` aggregates all claims and renders manifests |
| `infrastructure/` | Version-pinned install manifests (Crossplane, ESO, Kyverno, provider Helm, …) |
| `gitops/` | GitOps `Application` / `ApplicationSet` definitions (hub + spoke) |
| `ci/` | Pipeline and rendering/bootstrap scripts |
| `tests/` | Golden snapshots + Kyverno/chainsaw/e2e tests |
| `docs/` | Architecture, ADRs, runbooks, and how-to guides |

## Quick start

Requires `cue` (v0.16.x), `yq`, `jq`, `helm`, and `kubectl`. The repo pins its
toolchain in [`jarvy.toml`](jarvy.toml); `make setup` installs everything.

```bash
make validate                          # cue vet ./... — validate all schemas
make export                            # render all cluster YAML (XRDs + Compositions + claims)
make export-cluster CLUSTER=home       # render one cluster
make export-raw CLUSTER=home           # render flat k8s YAML (Crossplane-free fallback)
make test-raw                          # full raw-fallback test suite (goldens, lint, parity)
make diff                              # dry-run render and diff against clusters/
```

Two output modes:

- **Default** (`make export` / `make apply`) ships XRDs + Compositions + claim CRs —
  the target cluster needs Crossplane.
- **Raw** (`make export-raw` / `make apply-raw`) ships flat manifests — the target
  needs only the operators that own the referenced CRDs.

## The example clusters

| Cluster | Role | What it demonstrates |
|---|---|---|
| `composites/home/` | A rich single-site cluster | Ingress + TLS, ESO/OpenBao secrets, Argo CD + Argo Events pipelines, CronJobs, Velero backups, network policy, Traefik middleware |
| `composites/preview/` | Ephemeral PR-preview environments | ApplicationSets, per-PR namespaces, shared secrets, ExternalDNS webhook |
| `composites/shared/` | Cross-cluster resources | Resources rendered into every cluster |

These are the **examples** — read them to learn the patterns, then model your own
cluster on them. See [docs/using-this-template.md](docs/using-this-template.md).

## Placeholders — replace before use

This template was scrubbed of all real infrastructure detail. Search-and-replace the
following before deploying:

| Placeholder | Meaning | Replace with |
|---|---|---|
| `example.com` | Public DNS zone / ingress hostnames | your public domain |
| `example.internal` | Internal DNS zone | your internal domain |
| `example-org` | GitHub org / GHCR namespace / `owner` labels | your org slug |
| `example-bot` | GitHub bot/automation account | your bot username |
| `example-app` | GitHub App name / private-key filename | your GitHub App |
| `admin@example.com`, `eng-admin@example.com` | Operator emails | your emails |
| `192.168.1.x` / `192.168.2.x` / `192.168.3.x` | LAN / load-balancer / second-site subnets | your network ranges |
| `talos-home`, `talos-preview` | Talos/Omni cluster names | your cluster names |
| `your-netbox-tenant`, `your-gcp-project` | NetBox Cloud tenant / GCP project | your values |
| `0123456789abcdef…`, `fedcba9876543210…` | Opaque IDs (OAuth client, R2 account, CF zone) | your real IDs (keep them in a secret store, not in git) |

**Secrets are never stored in git.** This repo uses External Secrets Operator (ESO):
every `ExternalSecret` references a path in a secret store (OpenBao/Vault) — see
[docs/secret-management.md](docs/secret-management.md). Wire your store and the
placeholder paths resolve to your real values at runtime.

## Documentation

- [Architecture](docs/architecture.md) · [ADRs](docs/adr/) · [Why Crossplane + CUE](docs/why-crossplane-cue.md)
- [Using this template](docs/using-this-template.md) · [Onboarding a cluster](docs/onboarding.md) · [Cluster setup](docs/cluster-setup.md)
- [Raw-manifest fallback](docs/raw-fallback.md) · [Secret management](docs/secret-management.md)
- [Feature pipeline](docs/feature-pipeline.md) · [Diagrams](docs/diagrams.md)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security policy: [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE).
