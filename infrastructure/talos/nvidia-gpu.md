# NVIDIA GPU Support on Talos

GPU workloads on Talos require **node-level system extensions** baked into
the boot image, plus an in-cluster **GPU Operator** Helm install with the
driver + container-toolkit components disabled (Talos owns those).

Reference: <https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/hardware-and-drivers/nvidia-gpu>

## Node prereqs (system extensions)

Talos cannot install kernel modules at runtime. The NVIDIA kernel driver
and the container toolkit ship as **schematic extensions** that are baked
into the boot image at <https://factory.talos.dev>. Pick **one** variant
across both extensions — `lts` and `production` are not interchangeable:

| Extension | LTS variant (recommended) | Production variant |
|---|---|---|
| Kernel module | `siderolabs/nonfree-kmod-nvidia-lts` | `siderolabs/nonfree-kmod-nvidia-production` |
| Container toolkit | `siderolabs/nvidia-container-toolkit-lts` | `siderolabs/nvidia-container-toolkit-production` |

### Building the schematic

```bash
curl -sS -X POST https://factory.talos.dev/schematics --data-binary @- <<'YAML'
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/nonfree-kmod-nvidia-lts
      - siderolabs/nvidia-container-toolkit-lts
YAML
# → returns { "id": "<schematic-hash>" }
```

Use that hash as the source for the Talos installer image:

```
factory.talos.dev/installer/<schematic-hash>:v1.13.x
```

### Applying via Omni

For Omni-managed clusters (this is how all clusters in this repo are run),
the schematic ID goes into the `ClusterTemplate` or per-machine override
in the Omni UI:

1. Omni → Cluster → **Machine Set** → edit the worker pool
2. Under **Image**, set the installer image to the factory URL with the
   schematic ID above
3. Save & sync — Omni will reboot the worker into the new image
4. Verify on the rebooted node:
   ```bash
   talosctl -n <worker-ip> read /proc/modules | grep nvidia
   talosctl -n <worker-ip> get extensions
   ```

### Applying via talosctl (non-Omni only)

```bash
talosctl upgrade --image factory.talos.dev/installer/<hash>:v1.13.x \
  --nodes <worker-ip> --preserve
```

### NodeFeatureDiscovery + label

The GPU Operator runs `node-feature-discovery` which auto-labels nodes
with `nvidia.com/gpu.present=true` once the kmod is loaded and a GPU is
visible to the kernel. No manual label is needed — but if you want to
restrict the operator's DaemonSets to specific nodes, set
`extraValues.nodeSelector` on the `XGpuOperator` claim (see
[composites/home/gpuoperators.cue](../../composites/home/gpuoperators.cue)).

## In-cluster install

Once the node is rebooted with the extensions:

1. Add a `gpu-operator` namespace to the cluster's `namespaces.cue` with
   PSS `privileged` (gpu-operator-validator + driver-validator pods need
   privileged + hostPath):
   ```cue
   {
       name:    "gpu-operator"
       tier:    C.tier
       cluster: C.name
       owner:   "platform-team"
       labels: {
           "pod-security.kubernetes.io/enforce": "privileged"
           "pod-security.kubernetes.io/audit":   "privileged"
           "pod-security.kubernetes.io/warn":    "privileged"
       }
   }
   ```
2. Enable the GPU operator in `composites/<cluster>/gpuoperators.cue`:
   ```cue
   gpuOperators: [{
       name:          "nvidia-gpu-operator"
       namespace:     "gpu-operator"
       chartVersion:  "v25.10.1"
       driverVariant: "lts"  // must match the Talos extension variant
       tier:    C.tier
       cluster: C.name
       owner:   "platform-team"
   }]
   ```
3. Render + apply:
   ```bash
   make export-cluster CLUSTER=home
   kubectl apply -R -f clusters/home
   ```

The XGpuOperator composition emits a Helm Release with:

- `driver.enabled=false` (kmod from Talos)
- `toolkit.enabled=false` (toolkit from Talos)
- `operator.runtimeClass=nvidia` (chart auto-creates the RuntimeClass)
- `operator.defaultRuntime=nvidia`

Workloads then schedule onto GPU nodes by setting:

```yaml
spec:
  runtimeClassName: nvidia
  containers:
    - resources:
        limits:
          nvidia.com/gpu: 1
```

## Verification

```bash
# Operator pods come up
kubectl -n gpu-operator get pods

# RuntimeClass is registered
kubectl get runtimeclass nvidia

# Node is labeled by NFD
kubectl get nodes -l nvidia.com/gpu.present=true

# End-to-end CUDA test
kubectl run cuda-vector-add --rm -it --restart=Never \
    --image=nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0 \
    --overrides='{"spec":{"runtimeClassName":"nvidia","containers":[{"name":"cuda-vector-add","image":"nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0","resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}'
```

## Gotchas

- **Schematic + kmod variant mismatch** — installing
  `nonfree-kmod-nvidia-lts` on the node but setting `driverVariant:
  "production"` on the XGpuOperator claim does not break anything by
  itself (the field only affects the skipped-mode placeholder text), but
  any external automation that reads it for image pinning will be
  inconsistent. Keep them aligned.
- **Container toolkit version skew** — the Talos extension's toolkit
  must be compatible with the chart version. Bump both together when
  upgrading the Talos image.
- **GPU Operator chart version** — pin in `chartVersion`. The chart's
  default values change between minor releases (e.g. defaultRuntime
  default flipped at one point). Test in a side cluster before bumping.
- **Single-node clusters** — gpu-operator-validator's CUDA test pod
  needs the node to be schedulable. If you're running an all-in-one
  control-plane-and-worker box, ensure the control-plane taint is
  tolerated or removed for the GPU pool.
