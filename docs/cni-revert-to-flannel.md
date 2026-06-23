# Reverting the home cluster from Cilium back to Flannel

> Status: planning artifact authored 2026-05-20 after the third Cilium
> agent death-spiral incident in a week. See
> `feedback_cilium_to_flannel_decision.md` (auto-memory) for the
> decision rationale.

This doc mirrors `docs/cilium-cni.md` (forward path) and the existing
forward-migration script `ci/scripts/migrate-cni-cilium.sh`. The
reverse runs the same phases in mostly-the-same order, with one
operator-driven step (Omni-side ConfigPatch apply / rolling reboot)
that can't be scripted from the workstation.

## Decision summary

| Axis | Cilium today | Flannel after |
|---|---|---|
| Per-node memory footprint | ~250-400 MB (1 GiB cgroup limit) | ~50 MB |
| Pod-to-pod NetworkPolicy enforcement | Yes (eBPF) | None (Flannel doesn't implement NP) |
| kube-proxy | Replaced by eBPF | Stock iptables kube-proxy |
| Failure mode under busy nodes | Agent /healthz timeout → SIGKILL → cascade | Stable; flannel daemons rarely cycle |
| Operator burden per node reboot | Socket-LB hook re-attach dance | None |
| Observability | Hubble (unused) | None additional |

For this 5-node homelab with one operator and no compliance need for
in-cluster pod-to-pod policy, Flannel wins. Cilium would still be
right on production multi-tenant.

## What goes away

Code-side:
- `infrastructure/cilium/` directory (helm install + CCNPs + watchdog)
- `infrastructure/talos/cilium-cni-patch.yaml` ConfigPatch
- Cilium-specific CCNPs `allow-egress-to-kube-apiserver`, `allow-ingress-from-host`
- Cilium-specific BPF socket-LB watchdog CronJob
- `feedback_cilium_*` memories stay as historical record but no longer constrain new work

Cluster-side:
- DaemonSet `cilium`, Deployment `cilium-operator`, Hubble pods
- CRDs: `ciliumendpoints.cilium.io`, `ciliumidentities.cilium.io`,
  `ciliumnodes.cilium.io`, `ciliumclusterwidenetworkpolicies.cilium.io`,
  `ciliumnetworkpolicies.cilium.io`, etc.
- `cilium_*` kernel devices on each node
- BPF maps under `/sys/fs/bpf/`

Workload-side:
- Every `NetworkPolicy` becomes inert. The k8s NP API still accepts them; Flannel
  just doesn't enforce. Leave them in the repo as documentation; they're free.

## Migration phases

```
0  preflight       — kubectl/talosctl/omnictl/helm/jq present; etcd snapshot taken off-cluster
1  backup          — Velero + OpenBao + Talos etcd snapshot (same as forward script)
2  quiesce         — pause kelos taskspawners + ApplicationSet to reduce mid-flight pod churn
3  configpatch     — DELETE the Cilium ConfigPatch in Omni so Talos defaults take over
                     (cni.name=flannel + proxy.disabled=false on next boot)
4  rolling reboot  — Omni rolls workers one-at-a-time, Talos installs kube-flannel +
                     kube-proxy DaemonSets automatically during boot, nodes flip Ready
5  cilium teardown — once ALL nodes are on the new config:
                       helm uninstall cilium -n kube-system
                       kubectl delete ccnp <each>
                       kubectl delete crd ciliumendpoints.cilium.io ... (~10 CRDs)
6  kernel cleanup  — symmetric to forward Phase 6.5 (talosctl delete cilium_* devices
                     + bounce containerd-managed sandboxes). If you did a clean rolling
                     reboot in Phase 4, this is usually a no-op.
7  workload roll   — rollout restart every workload so it gets Flannel-issued IPs + fresh
                     pod-network plumbing. Kelos/argo-events sensors especially.
8  smoke tests     — in-cluster DNS, pod→apiserver, cross-node Service VIP, external egress,
                     ingress through Traefik. Same matrix as forward script's Phase 8.
9  un-quiesce      — restore kelos + ApplicationSet to normal cadence
10 cleanup files   — git rm infrastructure/cilium/, infrastructure/talos/cilium-cni-patch.yaml,
                     remove infrastructure references from bootstrap-home.sh
```

## Rollback (if Phase-8 smoke fails)

The Cilium teardown happens in Phase 5 AFTER all workers are rolled to Flannel.
Until that point, rollback is trivial:

```
omnictl apply -f infrastructure/talos/cilium-cni-patch.yaml \
  --label omni.sidero.dev/cluster=talos-home
# Omni rolls workers back to cni.name=none; existing Cilium install
# takes over again. No code-side rollback needed.
```

After Phase 5 (Cilium uninstalled), rollback would mean re-running the
forward migration script `ci/scripts/migrate-cni-cilium.sh`. Plan as if
forward.

## What stays the same

- KubePrism on `127.0.0.1:7445` (Talos default; not Cilium-specific even though we used it for Cilium)
- Longhorn, ESO, ArgoCD, OpenBao, kelos, all workloads
- All Service ClusterIPs (kube-proxy handles them now instead of eBPF)

## Operator command sequence

Run on the workstation; Omni-side steps are explicitly marked.

```bash
# Phase 0 + 1 + 2: same as forward script (or skip if you're confident)
./ci/scripts/migrate-cni-flannel.sh --phase=preflight
./ci/scripts/migrate-cni-flannel.sh --phase=backup
./ci/scripts/migrate-cni-flannel.sh --phase=quiesce

# Phase 3: drop the Cilium ConfigPatch in Omni.
#
#   OMNI-UI:  Cluster → Config Patches → delete `100-cilium-cni-<cluster>`
#   OR via omnictl:
#     omnictl delete ConfigPatches.omni.sidero.dev 100-cilium-cni-talos-home
#
# Talos won't immediately apply (CNI choice is bootstrap-time only).

# Phase 4: rolling reboot of workers one-at-a-time.
#
#   For each worker node (talos-{xil-8bb, k75-8g8, vgr-f2z, oxr-ifg}, then control plane):
#     kubectl cordon talos-<id>
#     kubectl drain talos-<id> --ignore-daemonsets --delete-emptydir-data
#     OMNI-UI:  Machines → talos-<id> → Reboot
#     # wait for Ready
#     kubectl uncordon talos-<id>
#     # Talos boots with Flannel + kube-proxy; CNI pods come up automatically

# Phase 5: tear down Cilium once all workers are on Flannel.
./ci/scripts/migrate-cni-flannel.sh --phase=teardown

# Phase 6: kernel state cleanup (idempotent — usually a no-op if Phase 4 was clean reboots).
./ci/scripts/migrate-cni-flannel.sh --phase=cleanup-kernel

# Phase 7-8: workload roll + smoke tests
./ci/scripts/migrate-cni-flannel.sh --phase=workload-roll
./ci/scripts/migrate-cni-flannel.sh --phase=smoke

# Phase 9: un-quiesce
./ci/scripts/migrate-cni-flannel.sh --phase=unquiesce

# Phase 10: file cleanup (commit after migration is fully validated)
git rm -r infrastructure/cilium/
git rm infrastructure/talos/cilium-cni-patch.yaml
# Update bootstrap-home.sh to remove the Cilium-install phase (Flannel + kube-proxy
# come up automatically when Talos boots with default config).
```

## Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| Kelos task pods lose connectivity during rolling reboot | High | Phase 2 quiesce pauses taskspawners; auto-recovers in Phase 9 |
| Longhorn volumes get stuck attaching during reboot | Medium | Same as forward migration's Phase 6.6 — bounce instance-managers if needed |
| Cross-node Service VIP traffic drops during the transition | High but brief | Roll workers one-at-a-time; each transition is ~3-5 min |
| Stale Cilium kernel state breaks Flannel after reboot | Low (reboot clears most) | Phase 6 cleanup script; worst case `talosctl reset` and rejoin a node |
| ArgoCD's preview-envs ApplicationSet auto-syncs mid-migration | Medium | Phase 2 quiesce sets the `migration-paused` label on the ApplicationSet |
| OpenBao seals on reboot | Medium (per memory) | Phase 9 includes an unseal step; auto-unseal CronJob also catches it |
| The Cilium-specific CCNPs leave stale BPF program references | Low | Phase 5 deletes CRDs which GCs their BPF maps; kernel cleanup is belt-and-suspenders |

## Time estimate

| Phase | Duration |
|---|---|
| 0-2 (preflight + backup + quiesce) | 5-10 min |
| 3 (configpatch removal in Omni) | <1 min |
| 4 (rolling reboot 5 nodes × ~5 min) | 25-35 min |
| 5 (cilium teardown) | 5 min |
| 6 (kernel cleanup, often a no-op) | <5 min |
| 7 (workload roll) | 10-15 min |
| 8 (smoke tests) | 5 min |
| 9 (un-quiesce) | <5 min |
| 10 (file cleanup + commit) | 5 min |
| **Total wall clock** | **~60-90 min** |

## After successful migration

- Update `MEMORY.md` index entry for `project_home_cluster.md` from
  "**Cilium CNI** since 2026-05-06" to "back to **Flannel CNI** since 2026-05-20"
- Update `feedback_cilium_*` memories to add a "**no longer applicable** — see [[feedback_cilium_to_flannel_decision]]" suffix
- Add a `feedback_flannel_no_np_enforcement.md` reminder so anyone authoring NetworkPolicies post-migration realizes they're documentation, not enforcement
