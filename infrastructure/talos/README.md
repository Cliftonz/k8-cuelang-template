# Talos Machine Config Patches

Cluster-wide tuning patches for Talos Linux.

## Files

| File | Target | Purpose |
|---|---|---|
| [apiserver-tuning.yaml](apiserver-tuning.yaml) | Control planes | Raises kube-apiserver in-flight request caps and resource limits. Required before bootstrapping the preview cluster (Crossplane + Argo CD + CRD storm otherwise OOMKills the apiserver). **`ci/scripts/bootstrap-preview.sh` auto-applies this as Omni ConfigPatch `400-apiserver-tuning-${OMNI_CLUSTER}` and waits for Talos to roll the new static-pod manifest** — manual application below is only needed when bootstrapping outside that script. |
| [etcd-tuning.yaml](etcd-tuning.yaml) | Control planes | Raises etcd `heartbeat-interval` / `election-timeout` / `quota-backend-bytes` so etcd doesn't lose quorum when the CRD storm hits. Without it the apiserver-tuning patch alone leaves etcd as the next bottleneck — kube-scheduler + kube-controller-manager BackOff during install. **Auto-applied by `bootstrap-preview.sh` as Omni ConfigPatch `400-etcd-tuning-${OMNI_CLUSTER}` alongside apiserver-tuning.** |
| [longhorn-uservolume.yaml](longhorn-uservolume.yaml) | Workers | Provisions `/var/mnt/longhorn` on any attached data disk larger than 50 GiB. Keeps Longhorn volume data off the root filesystem. |
| [nvidia-gpu.md](nvidia-gpu.md) | GPU workers (image-level) | NVIDIA GPU support — system extensions (`siderolabs/nonfree-kmod-nvidia-*` + `siderolabs/nvidia-container-toolkit-*`) baked into the Talos image via factory schematic. Pairs with the [`XGpuOperator`](../../platform/xrd/gpuoperator.cue) XRD for the in-cluster GPU Operator install. |

## How to apply

### Via `bootstrap-preview.sh` (preferred — automatic for Talos+Omni)

`apiserver-tuning.yaml` is applied automatically by the bootstrap script in
Phase 1.5 (`phase_apiserver_tuning`). It:

1. Detects whether the kubectl context is a Talos cluster managed by Omni
   (osImage prefix + `omnictl get cluster`).
2. Wraps the patch in an `Omni ConfigPatches.omni.sidero.dev` resource
   labeled `omni.sidero.dev/cluster: ${OMNI_CLUSTER:-talos-${CLUSTER}}`,
   id `400-apiserver-tuning-${OMNI_CLUSTER}`.
3. `omnictl apply -f` — Omni rolls the new static-pod manifests; no node
   reboot is required for static-pod resource changes.
4. Polls `kube-apiserver` pods until every one reports
   `resources.limits.memory: 4Gi`.
5. Waits for `/healthz` to return `ok` before continuing.

Skip with `SKIP_APISERVER_TUNING=1` if you have already tuned out-of-band.
Override the Omni cluster label with `OMNI_CLUSTER=<name>` if it differs
from `talos-${CLUSTER}`.

For non-Talos clusters (where the machineconfig path doesn't exist), the
script auto-enables `BOOTSTRAP_PACE=slow`, which calls
`wait_apiserver_calm` between each heavy install (Longhorn → metrics-server
→ CNPG → Crossplane → render+apply). This trades wall-clock time for not
needing to tune the apiserver — installs serialize and wait for `/healthz`
to stay green between bursts.

### Via Omni UI (one-off / out-of-band)

1. Open the cluster in Omni
2. Cluster → **Config Patches** → **Add new patch**
3. Paste the contents of the patch file
4. Save & Sync
5. For `apiserver-tuning.yaml`: no reboot needed (static-pod manifest
   change). For `kubelet-cert-rotation.yaml` or
   `longhorn-uservolume.yaml`: rolling-reboot the affected nodes one at
   a time:
   ```bash
   talosctl -n <node-ip> reboot
   # wait for the node to come back and the cluster to be Ready before the next one
   ```

### Via talosctl (only if you have direct talosconfig — not Omni-proxied)

Note: `talosctl patch machineconfig` against an Omni-managed cluster will
return `PermissionDenied` because Omni proxies talosctl with limited perms.
Use the `omnictl apply` ConfigPatch flow above for Omni clusters.

```bash
# Apply to all control planes at once (direct talosctl only)
talosctl -n <cp-1-ip>,<cp-2-ip>,<cp-3-ip> \
  patch machineconfig --patch @infrastructure/talos/apiserver-tuning.yaml

# Reboot one at a time to avoid downtime
talosctl -n <cp-1-ip> reboot
# wait for Ready, then next
```

## Worker data disks for Longhorn

Each worker VM should have a dedicated data disk attached (in addition to
the 11 GiB root disk). The [longhorn-uservolume.yaml](longhorn-uservolume.yaml)
patch uses a disk selector (`disk.size > 50u*GiB && !system_disk`) to pick
up any attached disk larger than 50 GiB and mount it at `/var/mnt/longhorn`.

After applying the patch and rebooting each worker, verify the mount:

```bash
talosctl -n <worker-ip> get mounts | grep longhorn
# expected: /var/mnt/longhorn  xfs  rw,...
```

Longhorn's `values.yaml` sets `defaultSettings.defaultDataPath: /var/mnt/longhorn`
to match. If you already installed Longhorn with the default path, you
need to patch each `nodes.longhorn.io` resource to add a disk at the new
path and remove the old disk (see Longhorn docs on "Multiple Disks Support").

## Prerequisites

Patches set `resources.requests.memory: 1Gi` and `resources.limits.memory: 4Gi`
for kube-apiserver. The **VM itself must have enough RAM** to honor these
limits — Talos won't allocate more than the host exposes.

Recommended VM sizing for the preview cluster control plane:

| Role | vCPU | RAM |
|---|---|---|
| Control plane (each of 3) | 2 | 4 GiB |
| Worker (each of 3) | 2-4 | 4-8 GiB |

Workers hosting Longhorn volumes should get closer to 8 GiB so the
instance-manager pods have headroom.
