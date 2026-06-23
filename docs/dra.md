# Dynamic Resource Allocation (DRA) on Talos

DRA is the K8s-native API for scheduling pods onto specialized hardware
(GPUs, FPGAs, NICs) using `ResourceClaim` / `ResourceClaimTemplate` /
`DeviceClass` primitives instead of the legacy `extended resources` model
(`nvidia.com/gpu: 1`). This guide shows how to enable DRA on a Talos
cluster + install the NVIDIA DRA driver to expose GPUs.

## Why DRA over extended resources

| | Extended resources | DRA |
|---|---|---|
| **Granularity** | Whole device per pod | Per-device, sharable, attribute-aware |
| **Sharing** | None (1 pod = 1 GPU) | Multiple pods share, MIG slices, time-slice |
| **Selection** | Resource name only (`nvidia.com/gpu`) | Filter by attributes (memory, arch, MIG profile) |
| **Pluggability** | Device-plugin sidecar per kind | Single DRA driver per vendor, vendor-defined classes |
| **Status** | Stable since 1.10 | Beta (1.32+), default-on (1.34+), GA-track |

## Prerequisites

- Talos cluster running K8s **1.32 or newer**.
- At least one node with NVIDIA GPU + the NVIDIA Talos system extension
  installed via image factory. See `infrastructure/talos/nvidia-gpu.md`.
- kubectl + helm on PATH, kubeconfig pointed at target cluster.

## Step 1 — apply the DRA feature-gate ConfigPatch

```bash
omnictl apply -f infrastructure/talos/dra-feature-gates-patch.yaml \
  --label omni.sidero.dev/cluster=<cluster-name>
```

This sets `feature-gates: DynamicResourceAllocation=true` on:
- kubelet (per-node)
- kube-apiserver
- kube-controller-manager
- kube-scheduler

Talos rolls each component sequentially; allow ~5 min for a fresh
cluster, longer for the home cluster's HDD-bound etcd.

**K8s 1.34+ note**: DRA is beta default-on starting 1.34, and slated GA
in 1.35. The patch is harmless on those versions (gate is ignored when
the feature is GA) but explicit, which is preferable to "we hope it's
on by default."

## Step 2 — install the NVIDIA DRA driver

```bash
./infrastructure/nvidia-dra-driver/install.sh
```

What the script does:
1. Verifies the feature gate is reflected in kubelet's `configz`.
2. Adds `nvidia` Helm repo, installs `nvidia-dra-driver-gpu` chart into
   the `nvidia-dra-driver-gpu` namespace.
3. Pins driver root at `/usr/local` (where the Talos NVIDIA extension
   installs the userspace libs).
4. Force-enables `resources.gpus.enabled` for older K8s feature flags.
5. Confirms `ResourceSlice` objects appear (one per GPU per node).

Override version: `DRA_VERSION=v25.4.0 ./install.sh`.

## Step 3 — smoke test

```bash
kubectl create ns dra-gpu-share-test
kubectl label ns dra-gpu-share-test \
  pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl apply -f infrastructure/nvidia-dra-driver/example-pod.yaml

kubectl -n dra-gpu-share-test logs pod -c ctr0
kubectl -n dra-gpu-share-test logs pod -c ctr1
```

Both containers print `GPU 0: <name> (UUID: GPU-<...>)` with the SAME
UUID — confirming DRA-mediated GPU sharing.

Cleanup:
```bash
kubectl delete ns dra-gpu-share-test
```

## Authoring DRA-aware workloads

Three primitives:

```yaml
# Vendor-defined — installed by the DRA driver chart.
apiVersion: resource.k8s.io/v1
kind: DeviceClass
metadata:
  name: gpu.nvidia.com
spec:
  selectors:
    - cel:
        expression: device.driver == "gpu.nvidia.com"
```

```yaml
# Per-namespace template — defines what a claim looks like.
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: single-gpu
  namespace: my-app
spec:
  spec:
    devices:
      requests:
        - name: gpu
          exactly:
            deviceClassName: gpu.nvidia.com
            # Filter further (optional):
            # selectors:
            #   - cel:
            #       expression: device.attributes["gpu.nvidia.com"].productName == "A100"
```

```yaml
# In a Pod / Deployment / Job spec:
spec:
  containers:
    - name: app
      image: ...
      resources:
        claims:
          - name: gpu
  resourceClaims:
    - name: gpu
      resourceClaimTemplateName: single-gpu
```

## Known issues

| Issue | Workaround |
|---|---|
| `cilium connectivity test` (or any privileged-needy validator) fails on baseline PSS | `kubectl label ns <ns> pod-security.kubernetes.io/enforce=privileged --overwrite` |
| API drift in older docs (alpha resource shapes) | Use `resource.k8s.io/v1` (the beta+GA group); ignore `v1alpha2` / `v1alpha3` examples |
| Driver pod CrashLoopBackOff with "no NVIDIA devices" | Confirm node has `nvidia.com/gpu.present=true` label; the node selector in `values.yaml` requires it |

## Reference

- Sidero: https://docs.siderolabs.com/kubernetes-guides/advanced-guides/dynamic-resource-allocation
- NVIDIA DRA driver: https://github.com/NVIDIA/k8s-dra-driver-gpu
- KEP-3063 (DRA): https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/3063-dynamic-resource-allocation
