# Cilium CNI on Talos

How to bring up a new home cluster (or rebuild an existing one) with
**Cilium** as the CNI + kube-proxy replacement, instead of Talos's default
Flannel + kube-proxy.

## Why

- eBPF datapath: kube-proxy replacement is faster than iptables for big
  service counts; cuts conntrack overhead.
- Native NetworkPolicy + identity-aware policies (CiliumNetworkPolicy
  beyond stock NetworkPolicy semantics).
- Hubble for live network observability without a separate sidecar.
- Path forward to BGP, eBPF-based load balancing, gateway-API.

Cost vs Flannel default:
- ~256 MiB RAM per node for cilium-agent.
- One extra step on bootstrap.
- A couple of Talos-specific Helm tweaks (handled in our values).

## Bootstrap order

The CNI MUST be in place before pods can schedule, so the order is:

1. **Apply Talos ConfigPatch** before bootstrapping the cluster.
   ```bash
   omnictl apply -f infrastructure/talos/cilium-cni-patch.yaml \
     --label omni.sidero.dev/cluster=<cluster-name>
   ```
   This sets `cluster.network.cni.name=none` and `cluster.proxy.disabled=true`.
2. **Bootstrap Talos / Omni** the normal way. Nodes come up `NotReady`
   (expected — no CNI is installed).
3. **Install Cilium**:
   ```bash
   ./infrastructure/cilium/install.sh
   ```
   Pulls helm chart `cilium/cilium` v1.19.3 with values tuned for Talos.
4. **Verify**:
   ```bash
   kubectl get nodes  # all Ready
   kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium status
   ```
5. **Continue** with the regular bootstrap (`ci/scripts/bootstrap-home.sh`)
   for Crossplane, ESO, Longhorn, etc.

## Talos-specific tweaks (already in [values.yaml](../infrastructure/cilium/values.yaml))

- `cgroup.autoMount.enabled: false` + `hostRoot: /sys/fs/cgroup` — Talos
  pre-mounts cgroupv2; let Cilium use it instead of trying to mount.
- `kubeProxyReplacement: true` paired with `k8sServiceHost: localhost` +
  `k8sServicePort: 7445` — KubePrism on Talos exposes the apiserver on
  every node at 127.0.0.1:7445, so Cilium doesn't need an external LB.
- Capability list omits `SYS_MODULE` — Talos blocks workloads from loading
  kernel modules.
- `bpf.masquerade: false` — works around CoreDNS conflict with Talos
  `forwardKubeDNSToHost=true`. Re-enable after disabling that flag.

## Known issues (per Sidero docs)

| Issue | Workaround |
|---|---|
| GCP internal LBs trip on Talos+Cilium routing | Use external LB or HAProxy in front |
| `bpf.masquerade=true` + Talos default DNS forwarding breaks CoreDNS | Either set `forwardKubeDNSToHost=false` in machine config or keep `bpf.masquerade=false` (our default) |
| `cilium connectivity test` fails on PSS baseline | Apply `pod-security.kubernetes.io/enforce=privileged` to the test ns |

## Switching an existing Flannel cluster to Cilium

This is **disruptive** — every pod restarts. Better to rebuild the cluster
when storage state isn't a concern. If you must switch in-place:

1. `omnictl apply -f infrastructure/talos/cilium-cni-patch.yaml`
2. Wait for Talos to reconcile machine configs.
3. `kubectl delete daemonset -n kube-system kube-flannel-ds kube-proxy`
4. Run `infrastructure/cilium/install.sh`.
5. `kubectl rollout restart deploy,ds,sts -A` to flip every pod into the
   Cilium datapath.

## Hubble UI (optional)

Off by default to keep RAM low. To turn on:

```bash
helm upgrade cilium cilium/cilium -n kube-system \
  --reuse-values \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true
```

Then port-forward or front it with an Ingress.

## Reference

- Sidero Labs: https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium
- Cilium chart: https://helm.cilium.io
- Latest stable: v1.19.3 (2026-04-15)
