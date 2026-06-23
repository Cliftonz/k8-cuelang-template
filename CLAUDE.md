# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Validation Commands

```bash
make validate                          # cue vet ./... — validate all CUE schemas
make export                            # cue export ./export/ — render all cluster YAML
make export-cluster CLUSTER=new-dev    # render YAML for a single cluster
make export-raw CLUSTER=new-dev        # render flat k8s YAML (Crossplane-free fallback) into clusters/<name>-raw/
make apply-raw CLUSTER=new-dev         # render raw + kubectl apply -R against current context
make diff                              # dry-run export and diff against existing clusters/
make clean                             # clear CUE caches (cue.mod/pkg/, cue.mod/usr/)
```

**Two output modes:**
- Default `make export` / `make apply` ships XRDs + Compositions + claim CRs — target cluster needs Crossplane.
- `make export-raw` / `make apply-raw` ships flat Kubernetes manifests — target cluster needs only the operators that own the CRDs being referenced (ESO, MetalLB, Kyverno, etc.). See [docs/raw-fallback.md](docs/raw-fallback.md).

## Cluster Bootstrap

Bringing up a fresh cluster — phased, idempotent, retries on transient
etcd flakes. Each phase is a stability gate; phase N+1 only starts once
apiserver `/healthz` is green and previous resources are Ready.

```bash
ci/scripts/bootstrap-home.sh           # full bootstrap, paused between phases
                                       # (default — operator validates each
                                       # step before triggering the next
                                       # reconcile burst)
ci/scripts/bootstrap-home.sh --no-pause     # unattended (CI / watcher runs)
ci/scripts/bootstrap-home.sh --check-only   # preflight only, no installs
ci/scripts/bootstrap-preview.sh        # same flow for preview cluster
```

Phases: preflight → CP tuning ConfigPatches → Talos disk check → Longhorn
→ metrics-server → CNPG (auto-detected) → Crossplane + providers → CUE
render → apply (XRDs first, wait Established, then everything else) →
wait helm releases → ArgoCD CI bootstrap → manual-step summary.

CUE version is pinned to **v0.16.1** in `cue.mod/module.cue`. Module path: `github.com/k8-infra@v0`.

## Architecture

**Hub-and-spoke Crossplane model** with CUE-based validation and OCI artifact promotion.

- **Hub cluster** runs Crossplane (XRDs, Compositions, Providers) and provisions spoke clusters
- **Spoke clusters** (dev, staging, prod) consume pre-rendered manifests via Harness GitOps / ArgoCD
- **CUE** validates contracts and generates deterministic YAML at build time — no runtime CUE
- **Promotion flow**: Author claims → CI validates (`cue vet`) → CI renders (`cue export`) → package as OCI artifact → update digest in env repo → GitOps syncs to spoke

See `docs/architecture.md` for full design and `docs/adr/004-cue-artifact-promotion.md` for the decision record.

## Repository Layout

| Directory | Purpose |
| --- | --- |
| `platform/xrd/` | Crossplane XRDs (namespace, rbac, resourcequota, networkpolicy) — platform API schemas |
| `platform/compositions/` | Crossplane Compositions mapping XRD claims → Kubernetes Objects |
| `platform/policy/` | Tier-based policy constraints (quota limits, network policy defaults) |
| `libs/tiers/` | Tier definitions (dev/staging/production) implementing `#TierConfig` contract |
| `libs/k8s/` | Shared Kubernetes type schemas (metadata, namespace, rbac, resourcequota, networkpolicy) |
| `composites/{cluster}/` | Per-cluster desired state as composite inputs (CUE) |
| `export/` | CI entry point — `export/all.cue` aggregates all claims and renders manifests |
| `infrastructure/` | Version-pinned install manifests (Crossplane, Kyverno, Kubescape, ESO, Provider Helm) |
| `gitops/` | Harness GitOps Application/ApplicationSet definitions (hub + spoke) |
| `ci/` | Harness pipeline (`ci/pipelines/harness.yaml`) and rendering scripts |

## CUE Conventions

- **Module-scoped imports only**: `"github.com/k8-infra/libs/tiers"`, never file-relative
- **Single-module, multi-package** layout — each directory is a CUE package
- All XRDs use group `infra.k8`, version `v1alpha1`
- All resource names must match `^[a-z][a-z0-9-]*$`
- Tier values: `"dev"`, `"staging"`, `"production"`
- Provider values: `"rancher"`, `"eks"`, `"gke"`, `"aks"`
- Standard labels (`app.kubernetes.io/managed-by: k8-infra`, tier, cluster, owner) are enforced on all resources via `libs/k8s/metadata.cue`

## Tier System

Each tier (`libs/tiers/{tier}.cue`) implements `#TierConfig` with:

- **Resource quotas** — dev: 1cpu/1Gi req, 2cpu/2Gi limit; staging: 2/2Gi, 4/4Gi; prod: 4/4Gi, 8/8Gi
- **Kyverno mode** — dev: `Audit`; staging/prod: `Enforce`
- **Network policy** — all tiers deny ingress/egress by default, allow DNS; staging/prod also allow monitoring

## Adding a New Cluster

1. Create `composites/{cluster-name}/` with `cluster.cue`, `namespaces.cue`, `rbac.cue`, `resourcequotas.cue`, `networkpolicies.cue`
2. Update `export/all.cue` to import and aggregate the new cluster
3. Add `gitops/env-repos/{cluster-name}/artifact-digest.yaml`
4. Validate: `make validate && make export-cluster CLUSTER={cluster-name}`

See `docs/onboarding.md` for full steps.

## Key Rules

- **Never hand-edit `clusters/`** — it is CI-generated rendered YAML
- All CUE imports use the full module path
- Claims reference cluster metadata via `let C = cluster` pattern
- Infrastructure components (Kyverno, ESO, Kubescape) are installed via Crossplane Provider Helm; only Crossplane itself is installed directly
- CI checks infrastructure manifest freshness weekly against upstream Helm charts (`ci/scripts/check-infra-manifests.sh`)
- Before bumping a chart version, run `make helm-immutable-check CLUSTER=home` — a chart bump that changes an immutable k8s field (RoleBinding `roleRef`, workload `selector`, PVC size/class) makes `helm upgrade` fail and wedges the provider-helm Release. The guard flags it pre-apply; `make helm-immutable-fix CLUSTER=home CONFIRM=1` clears the offending objects. See [docs/helm-immutable-upgrades.md](docs/helm-immutable-upgrades.md). This also runs in CI on PRs touching `helmreleases.cue`.
