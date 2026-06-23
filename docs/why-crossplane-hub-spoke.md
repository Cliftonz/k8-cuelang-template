# Why Crossplane (vs Raw YAML) and the Hub-Spoke Pattern

Companion to [why-crossplane-cue.md](why-crossplane-cue.md). That doc compares
to Helm. This one answers two adjacent questions:

1. Why use Crossplane like this instead of just raw YAML like everyone else?
2. What if you run Crossplane at the seed level for the cluster and leverage
   it to deploy things on other clusters?

---

## 1. Why Not Raw YAML

### The pain raw YAML hides at scale

- **Repetition.** Every app needs a namespace, RBAC, ResourceQuota, and
  NetworkPolicy. Fifty apps means 200+ YAML files. Drift is inevitable.
- **No tier policy home.** Dev vs. staging vs. prod quota and Kyverno mode
  conventions live nowhere enforceable. Copy-paste guarantees inconsistency.
- **No contract.** A junior dev (or AI agent) forgets a NetworkPolicy and
  ships a namespace with no isolation. Nothing rejects the merge.

### Helm and Kustomize fix some of this, miss the rest

- **Helm** is string templating. No real type safety. `tier: prodution` typo
  ships and only fails at apply time.
- **Kustomize** is patch overlays. No validation, no policy, no claim model.
  Overlays diverge per-environment, and there is nothing to vet them
  against a contract.

### What Crossplane + CUE actually gives

- **Contract.** An `XNamespace` claim says `tier=dev, owner=foo`. The
  Composition expands to namespace + ResourceQuota + NetworkPolicy + RBAC.
  The operator literally cannot forget the pieces.
- **Tier policy enforced in CUE.** Dev/staging/prod quotas are defined once
  in [libs/tiers/](../libs/tiers/) and cannot drift across consumers.
- **Pre-merge validation.** `cue vet` catches typos, missing fields, and bad
  enums before the change reaches a cluster. Raw YAML waits for
  `kubectl apply` to fail.
- **Hub-spoke reconciliation.** The claim lives in git; Crossplane keeps the
  spoke matching it. Raw YAML is apply-and-pray with no drift correction.
- **OCI artifact promotion.** Render once, promote the digest from dev to
  staging to prod. Same bytes everywhere. Raw YAML environments diverge
  silently over time.

### Honest costs

- More moving parts: Crossplane providers, XRDs, and Compositions are extra
  things to debug.
- Real CUE learning curve.
- Solo operator at small scale, this is arguably overkill. It is justified
  here because preview clusters are spun up per-PR, the platform is
  multi-cluster, and AI agents author claims that need guardrails.

### TL;DR

Raw YAML scales linearly with `apps × clusters × envs`. This approach
scales with *kinds of things*. There are fewer kinds than apps, so the win
compounds at >1 cluster and >a-handful of apps.

---

## 2. Crossplane on a Seed Cluster Targeting Other Clusters

This is the canonical Crossplane "hub" play, already half-aimed at in
[architecture.md](architecture.md).

### How it works

- The seed cluster runs Crossplane plus `provider-kubernetes` and
  `provider-helm`.
- Each spoke kubeconfig is stored as a Secret on the seed. A
  `ProviderConfig` per spoke points at it.
- Claims tag `spec.targetCluster: prod-east`. The Composition selects the
  matching `ProviderConfig`. The composed `Object` lands on the spoke.
- One control plane, N targets, drift correction on all of them.

### Wins beyond single-cluster

- **Fleet uniformity.** An `XNamespace` claim renders identically on every
  spoke. No per-cluster Kustomize forks.
- **Cross-cluster composites.** One claim becomes a namespace on cluster A
  + a Cloudflare DNS record + a secret in OpenBao + an ESO mirror on
  cluster B. Atomic from the caller's view.
- **Spokes can be dumb.** No Crossplane, no ArgoCD, no Helm tiller on the
  spoke. Just a kubeconfig and RBAC for the seed. Disaster recovery is
  recreate the spoke and let the seed reconcile.
- **AI/automation safer.** Agents only write claims to seed-side git.
  Spokes have no inbound write path from the agents.

### Real costs (the ones that bite in production)

- **Seed is the blast radius.** If the seed dies, nothing reconciles
  anywhere. Need an HA seed or a fast rebuild path. Back up XRs and claims
  religiously.
- **Network reach.** The seed needs reachability to every spoke
  apiserver. VPN/tunnel sprawl follows. Or invert it (spoke pulls), but at
  that point you are just doing GitOps.
- **Credential rotation.** N spoke kubeconfigs to rotate. ESO with
  short-lived ServiceAccount tokens helps; it is still operational tax.
- **`provider-kubernetes` is chatty.** It watches every managed `Object` on
  every spoke. Memory and apiserver QPS scale `O(spokes × objects)`. Tune
  `--max-reconcile-rate` and shard providers per spoke if the fleet gets
  big.
- **Two-hop debugging.** Claim on seed → MR on seed → `Object` on seed →
  *actual* resource on spoke. The `kubectl describe` chain gets long.
- **Version skew.** `provider-kubernetes` vs spoke apiserver versions are
  usually fine, but edge cases bite.

### vs ArgoCD-per-spoke (the other option)

- **ArgoCD** is pull-based, declarative, simple, with no live credential
  flowing from hub to spoke.
- **Crossplane hub** is push-based and *programmable* — Compositions can
  compute things and react to status.
- Use Crossplane when claims need **logic** (compute, branch, lookup).
  Use ArgoCD when you just need "this YAML on that cluster."
- **Both is fine.** Crossplane on the seed renders and commits to an env
  repo, and ArgoCD on each spoke pulls. You get programmability plus
  pull-based safety. This repo is already trending that way (see
  [gitops/env-repos/](../gitops/env-repos/)).

### Recommendation at this repo's scale

- Solo operator with ephemeral preview clusters: full seed-to-spoke push
  is overkill if the spokes are short-lived. Pure ArgoCD pull is simpler.
- Seed pattern wins when there are long-lived spokes, cross-cluster
  composites (this repo has these — Cloudflare + OpenBao + multi-cluster
  ESO), or spokes you cannot put GitOps on (edge, customer-owned).
- The hybrid this repo is already drifting toward — Crossplane composes
  manifests on the seed, writes to an env repo, ArgoCD on the spoke
  pulls — is the pragmatic answer and gets the best of both.

---

## 3. Raw-YAML Fallback Mode

For spokes that cannot run Crossplane at all — managed K8s without
permission to install CRDs, customer-owned clusters, edge devices,
`kind`/CI smoke environments, air-gapped sites, or DR rebuild before
the seed is back — this repo also ships a **raw-fallback output mode**.
Same composite inputs, but each entry is rendered to the equivalent
flat Kubernetes manifest at export time:

```bash
make export-raw CLUSTER=home   # produces clusters/home-raw/
make apply-raw  CLUSTER=home   # render + kubectl apply -R
```

`clusters/<name>-raw/` contains plain `Namespace` / `NetworkPolicy` /
`ResourceQuota` / `Ingress` / etc. — no XRDs, no Compositions, no
Crossplane runtime needed on the target. Helm releases get inlined via
`helm template`. Resource types with no in-cluster equivalent
(`XObjectPatch`, `XNodeTaint`, `XHarborProject`) are surfaced in
`_skipped.md` with manual replacement guidance.

See [docs/raw-fallback.md](raw-fallback.md) for the full operational
guide and [docs/adr/005-raw-yaml-fallback.md](adr/005-raw-yaml-fallback.md)
for the design decision.
