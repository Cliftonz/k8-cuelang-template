# Cluster Setup

Step-by-step guide for bootstrapping a new hub cluster from scratch and exporting rendered manifests for spoke clusters.

## Prerequisites

- `kubectl` configured with cluster-admin access to the target hub cluster
- `helm` CLI (v3+)
- `cue` CLI (v0.16.1+)
- `yq` CLI (v4+)
- `make`

## 1. Install Upbound Universal Crossplane (UXP)

Crosplane/UXP must be installed first — it is the control plane that reconciles all other resources (XRDs, Compositions, Providers, and Claims). This repo uses [Upbound Universal Crossplane](https://docs.upbound.io/manuals/uxp/howtos/uxp-deployment/) (UXP), Upbound's enterprise distribution of Crossplane.

```bash
./infrastructure/crossplane/install.sh
```

The script creates the namespace, adds the Upbound Helm repo, and installs UXP with `helm upgrade --install`. It uses `--devel` because UXP versions use a `-up.N` suffix (e.g. `v2.0.0-up.1`) and `--wait` to block until pods are ready.

## 2. Install Providers + Functions

Provider Helm allows Crossplane to manage Helm releases as composite resources. Provider Kubernetes is required for Kubernetes `Object` resources (namespaces, network policies, node taints). This repo installs providers and required functions via manifest applies in the UXP install script.

```bash
# Provider Helm and functions are applied by the install script.
# Re-run the install script if you need to re-apply them.
./infrastructure/crossplane/install.sh
```

Wait for the provider to become healthy:

```bash
kubectl get providers -w
```

The `provider-helm` and `provider-kubernetes` should show `INSTALLED: True` and `HEALTHY: True`.

## 3. Apply Platform API (XRDs and Compositions)

Export the XRDs and Compositions, then apply them to the hub cluster:

```bash
# Export platform resources only (no claims)
make export-split CLUSTER=new-dev

# Apply XRDs first — Crossplane needs these before Compositions
kubectl apply -f clusters/new-dev/xrds/

# Then apply Compositions
kubectl apply -f clusters/new-dev/compositions/
```

Verify the XRDs are established:

```bash
kubectl get compositeresourcedefinitions
```

All XRDs should show `ESTABLISHED: True`.

## 4. Apply Composite Resources

Once the platform API is in place, apply the cluster composite resources (X* kinds):

```bash
# Apply all composite resource types
kubectl apply -f clusters/new-dev/nodes/
kubectl apply -f clusters/new-dev/policies/
kubectl apply -f clusters/new-dev/rbac/
kubectl apply -f clusters/new-dev/namespaces/
kubectl apply -f clusters/new-dev/helm/
```

Or apply everything at once:

```bash
kubectl apply -R -f clusters/new-dev/
```

Monitor Crossplane reconciliation:

```bash
kubectl get managed -A
```

## 5. Install Additional Infrastructure (Optional)

These components are managed via Provider Helm on the hub cluster. If you have HelmRelease claims for them, Crossplane will install them automatically. Otherwise, apply the static manifests:

```bash
# Kyverno (policy engine)
kubectl apply -f infrastructure/kyverno/

# Kubescape (security scanning)
kubectl apply -f infrastructure/kubescape/

# External Secrets Operator
kubectl apply -f infrastructure/external-secrets/
```

## Spoke Clusters

Spoke clusters do not run Crossplane. They receive pre-rendered manifests via GitOps (Harness / ArgoCD). The hub cluster provisions and manages spoke resources through Crossplane's remote provider capabilities.

For spoke cluster setup, see the GitOps configuration in `gitops/env-repos/`.

## Export Options

```bash
# Full export with XRDs + Compositions + Composites
make export-split CLUSTER=new-dev

# Composites only (no Crossplane platform resources)
make export-split CLUSTER=new-dev PLATFORM=false

# Single-file multi-doc export
make export-cluster CLUSTER=new-dev
```

## Troubleshooting

**XRDs not establishing:**
```bash
kubectl describe compositeresourcedefinition <name>
```

**Composite resources not reconciling:**
```bash
kubectl describe <composite-kind> <composite-name>
kubectl get events -n platform-system --sort-by='.lastTimestamp'
```

**Provider Helm not healthy:**
```bash
kubectl describe provider provider-helm
kubectl -n crossplane-system logs -l pkg.crossplane.io/revision
```

**Provider Kubernetes not healthy:**
```bash
kubectl describe provider provider-kubernetes
kubectl -n crossplane-system logs -l pkg.crossplane.io/revision
```
