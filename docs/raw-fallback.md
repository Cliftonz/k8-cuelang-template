# Raw-YAML Fallback Mode

Sister doc to [why-crossplane-cue.md](why-crossplane-cue.md) and
[why-crossplane-hub-spoke.md](why-crossplane-hub-spoke.md). This one
covers the operational mode in which the same CUE-authored composite
inputs render to plain Kubernetes YAML instead of Crossplane claims.

## When to Use

Default mode (`make export` / `make apply`) ships XRDs, Compositions, and
`X*` claim CRs. The target cluster needs Crossplane plus
`provider-kubernetes` and `provider-helm` to reconcile them.

Use **raw fallback mode** (`make export-raw` / `make apply-raw`) when the
target cluster cannot or will not run Crossplane:

- Managed Kubernetes services that do not allow installing arbitrary CRDs.
- Edge / customer-owned clusters where adding a control plane is
  out of scope.
- `kind` / CI smoke clusters where you want a one-shot apply.
- Disaster-recovery rebuild before the seed cluster is back up.
- Air-gapped environments where the Crossplane provider runtimes
  cannot pull their function images.

The Crossplane mode still has every advantage documented in the sister
docs — contracts, drift correction, hub-spoke composites, programmable
reconciliation. Raw mode is a pragmatic escape hatch for places where
those advantages do not apply.

## How It Works

```
composites/<cluster>/*.cue   ── single source of truth ──┐
                                                          ▼
                  ┌─────────────────────────────────────────────┐
                  │ export/all.cue   (default — Crossplane)     │
                  │ export/raw.cue   (fallback — flat YAML)     │
                  └─────────────────────────────────────────────┘
                            │                       │
                            ▼                       ▼
                  clusters/<name>/        clusters/<name>-raw/
                  (XRDs+Comps+Claims)     (Namespace/NetPol/...)
                            │                       │
                            ▼                       ▼
                    kubectl apply           kubectl apply
                  (needs Crossplane)      (vanilla cluster)
```

Each composite type has a `#Render<Kind>` definition in
[libs/render/](../libs/render/). The renderer takes the same input
shape consumers author in [composites/](../composites/) and emits the
equivalent flat manifest with the standard label block applied. The
[export/raw.cue](../export/raw.cue) entrypoint walks each cluster's
composite lists and dispatches each entry to its renderer. The
[Makefile](../Makefile)'s `export-raw` target runs `cue export`, pipes
through a Helm post-processor and a skipped-resource reporter, and
writes split per-resource files under `clusters/<name>-raw/`.

## Targets

| Command | What it does |
| --- | --- |
| `make export-raw CLUSTER=home` | Render flat YAML into `clusters/home-raw/`. |
| `make apply-raw CLUSTER=home` | Render then `kubectl apply -R`. |
| `RAW_HELM=skip make export-raw CLUSTER=home` | Leave HelmRenderRequest placeholders in place (no `helm template` call). |
| `RAW_HELM=fail make export-raw CLUSTER=home` | Error if any HelmRelease is present (clean apply requires they be replaced). |

## Coverage

Resource types fully expanded by raw mode:

- Core: `Namespace`, `NetworkPolicy`, `ResourceQuota`, `ServiceAccount`.
- RBAC: `RoleBinding`, `ClusterRole`, `ClusterRoleBinding`.
- ESO: `ExternalSecret`, `ClusterExternalSecret`, `ClusterSecretStore`.
- Workloads: `Job`, `CronJob`.
- Networking: `Ingress`, `Service` (via `XExposedService`),
  `Service` + `EndpointSlice` pair (via `XExternalBackend`),
  Traefik `ServersTransport`, MetalLB `IPAddressPool` + `L2Advertisement`.
- Storage: `StorageClass`.
- Cert-manager: `Certificate`.
- Argo: `EventBus`, `EventSource`, `Sensor`, `AppProject`, `ApplicationSet`.
- Kelos: `Workspace`, `AgentConfig`, `TaskSpawner`.
- Kyverno: `ClusterPolicy`.

Helm releases (`XHelmRelease`) are inlined via `helm template` by the
[ci/scripts/render-helm.sh](../ci/scripts/render-helm.sh) post-processor.

Resource types **not expanded** — listed in `clusters/<name>-raw/_skipped.md`
with manual replacement guidance:

- `XObjectPatch` — server-side-apply patches against resources owned by
  another controller. Replacement: `kubectl annotate` / `kubectl label`
  the target after applying the rest of the bundle.
- `XNodeTaint` — patches an existing Node object. Replacement:
  `kubectl taint nodes <node> key=value:effect`.
- `XHarborRegistry`, `XHarborProject` — external-API providers, no
  in-cluster equivalent. Replacement: manage in the Harbor UI or with
  `harbor-cli`.

## Prerequisites the Target Cluster Still Needs

Raw mode removes the **Crossplane** dependency. It does **not** remove
the operators that own the CRDs the rendered manifests reference:

- External Secrets Operator (`ExternalSecret`, `ClusterExternalSecret`,
  `ClusterSecretStore`).
- MetalLB (`IPAddressPool`, `L2Advertisement`).
- Kyverno (`ClusterPolicy`).
- Argo Events (`EventBus`, `EventSource`, `Sensor`).
- Argo CD (`AppProject`, `ApplicationSet`).
- Kelos (`Workspace`, `AgentConfig`, `TaskSpawner`).
- cert-manager (`Certificate`).
- Traefik (`ServersTransport`).

These have to be installed via Helm (or another path) before applying
the raw bundle. The `helm template` step inlines the operator manifests
themselves where their charts are referenced from `composites/<cluster>/helmreleases.cue`.

## Drift Between Modes

Output manifests should be identical between Crossplane mode and raw
mode for the same composite input, modulo:

- **Owner references.** Crossplane mode resources carry a Crossplane
  composite owner-ref; raw-mode resources have none. `kubectl delete -f`
  works in both, but cascading deletion semantics differ.
- **Field manager.** Crossplane mode uses provider-kubernetes' field
  manager; raw mode uses `kubectl-client-side-apply` (or whatever you
  set with `--field-manager`).

Phase 5 of the rollout adds an optional `crossplane render` cross-check
in CI to catch any unexpected semantic drift.

## Bootstrap Path

A vanilla cluster bring-up looks like:

```bash
# 1. Bring up the cluster (kind, talos, k3s, whatever).
kind create cluster --name raw-fallback

# 2. Install the operators that own the CRDs your composites reference.
#    Either via the rendered HelmReleases (if the chart bundle includes
#    them) or one-shot helm install. ESO and MetalLB are the common ones.
helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace

# 3. Render and apply.
make apply-raw CLUSTER=home

# 4. Read the skipped report and handle each entry manually.
cat clusters/home-raw/_skipped.md
```

## Implementation

- [libs/render/](../libs/render/) — per-resource render templates.
- [export/raw.cue](../export/raw.cue) — dispatcher.
- [ci/scripts/render-helm.sh](../ci/scripts/render-helm.sh) — Helm post-processor.
- [ci/scripts/strip-skipped.sh](../ci/scripts/strip-skipped.sh) — skipped-resource reporter.
- [Makefile](../Makefile) — `export-raw`, `apply-raw` targets.

See [docs/adr/005-raw-yaml-fallback.md](adr/005-raw-yaml-fallback.md) for
the design decision and rejected alternatives.
