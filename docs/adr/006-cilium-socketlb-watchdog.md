# ADR 006: Cilium socket-LB watchdog DaemonSet

**Status:** Accepted — 2026-05-17
**Context cluster:** talos-home (Cilium 1.19.3, kube-proxy replacement)

## Context

After any node-level reboot (`talosctl reboot`, kubelet restart, host
power cycle) the cilium-agent pod on the affected node looks healthy
(`cilium-dbg status: OK`, Service map populated) but **Service VIP
routing from pods on that node silently fails**: pod→pod direct IPs
work, ClusterIP/Service DNS times out. Symptom traced 2026-05-14: the
BPF socket-LB hooks that cilium-agent installs into pod cgroups at
pod-create time are NOT re-attached when the node + its existing pods
come back from a reboot.

Manual fix is `kubectl -n kube-system delete pod cilium-<hash>` —
recorded in `feedback_cilium_node_reboot_recycle.md`. Triggered ≥3
times since the 2026-05-06 Flannel→Cilium migration; latest hit was
the ArgoCD `ComparisonError: connection refused to repo-server
ClusterIP` and apiserver `10.96.0.1:443` TLS-timeout incident on
talos-node-18.

## Decision

Ship a tiny node-local **`cilium-bpf-watchdog`** DaemonSet in
`kube-system` that:

1. Probes the kubernetes Service VIP (`10.96.0.1:443`) every 30s with
   a 5s connect timeout from inside a pod-network sidecar.
2. On 3 consecutive failures, deletes the cilium-agent pod on this
   node (identified via downward API `spec.nodeName`).
3. Re-probes after the new cilium-agent is Ready; resets the strike
   counter on success.

The watchdog ships as a plain YAML manifest under
`infrastructure/cilium/bpf-socketlb-watchdog.yaml` — same pattern as
the existing `ccnp-allow-*.yaml` policies — and is applied by
`infrastructure/cilium/install.sh` after the helm upgrade.

## Why this option (lowest blast radius)

- **Codifies a proven manual fix.** The recycle-the-cilium-agent
  remediation has worked every time it's been needed; the watchdog
  just automates the detection + action.
- **No Cilium config change.** We do not touch `socketLB`,
  `hostNamespaceOnly`, `hostLegacyRouting`, or bump the chart version
  — so no regression in any other code path. Upstream
  [cilium/cilium#17738](https://github.com/cilium/cilium/issues/17738)
  shows toggling `bpf-lb-sock-hostns-only` breaks apiserver reach for
  kube-system pods; we avoid that class of risk entirely.
- **No upstream-fix dependency.** The cgroup-attach failure is a
  known unresolved class of bugs (cilium/cilium#36789,
  cilium/cilium#43877). Waiting for an upstream fix is open-ended.
  A 1.19→1.20 jump has its own Talos regressions
  ([#45208](https://github.com/cilium/cilium/issues/45208),
  [#40421](https://github.com/cilium/cilium/issues/40421)).
- **Self-healing on every reboot**, not just the first one.
- **Idempotent + bounded blast radius:** the only action is "delete
  one cilium-agent pod on this node"; RBAC is scoped to that single
  verb on a single namespace-labeled subset.

## Alternatives considered

| Option | Why rejected |
|---|---|
| Bump Cilium to 1.20.x | Known Talos regressions (#45208, #40421); 1.19.3 is current 1.19.x patch; benefit unclear without upstream commit pointer |
| `socketLB.hostNamespaceOnly: false` | #17738 documents apiserver-reachability breakage for kube-system pods on kpr clusters; high regression risk |
| `bpf.hostLegacyRouting: false` toggle | Unrelated to cgroup-attach reattach; would not address the failure mode |
| Omni ConfigPatch ordering cilium-agent after kubelet | cilium-agent IS a kubelet-managed pod (DaemonSet); no ordering primitive exists at this layer |
| Stakater Reloader on `/sys/fs/cgroup` | Reloader watches Secrets/ConfigMaps for content changes, not filesystem events on host paths |

## Consequences

- Adds ~30 MiB RAM cluster-wide (4 nodes × ~7 MiB for a busybox
  + kubectl loop).
- One additional ServiceAccount + Role + RoleBinding in `kube-system`.
- Watchdog noise: emits a structured log line on every probe failure;
  recycle action announces `[cilium-watchdog] recycling cilium-<x> on
  <node>` so the action is grep-able in `kubectl logs`.
- If the watchdog itself is broken, the existing manual remediation
  still works — the watchdog is additive, not replacing.

## Reversal

Delete the DaemonSet + RBAC: `kubectl -n kube-system delete -f
infrastructure/cilium/bpf-socketlb-watchdog.yaml`. No Cilium state
changes.
