# Troubleshooting log — 2026-05-14 cluster recovery

End-to-end playthrough of a 14-hour debugging session covering full
cluster rebuild, Cilium migration, Velero restore, and tracking down a
NetworkPolicy port mismatch that masqueraded as Cilium being broken
across multiple nodes. Captured here so the next operator doesn't
repeat the dead ends.

---

## Context

Talos `home` cluster was recreated from Omni mid-day. The day's tasks
were supposed to be:

1. Move CloudNativePG operator from `infrastructure/cloudnative-pg/`
   bootstrap to a Crossplane-managed XHelmRelease.
2. Refresh OpenBao from last night's Velero backup.
3. Bring everything else back up.

Most of that worked smoothly. Two services — Coder and Goldilocks —
appeared to be blocked by deep Cilium bugs. After ~10 hours of
chasing the wrong cause, the actual issue turned out to be a
NetworkPolicy port mismatch I introduced when Coder was first
deployed.

---

## The dead ends (so you don't repeat them)

### Dead end 1: UniFi DNS interception (real bug, NOT the Coder blocker)

Cert-manager DNS01 propagation checks for `*.example.com` returned
NXDOMAIN even when querying public resolvers directly from inside the
cluster. Diagnosis: UniFi gateway intercepts outbound port-53 traffic,
serves `example.com` as authoritative because external-dns-unifi
publishes A records there, returns NXDOMAIN for any `_acme-challenge.*`
record it doesn't own.

**Fix**: in UniFi controller → Settings → Networks → DNS Records →
Domain Settings → forward `example.com` queries to `1.1.1.1`.

This was a legitimate bug worth fixing, but it had nothing to do with
Coder/Goldilocks being unreachable.

### Dead end 2: Stale Flannel kernel state (real but limited impact)

After the Flannel→Cilium migration, `cni0` bridge and dangling `vethN`
peers survived on 2 of 4 nodes. The migration script's Phase 6.5 only
deleted `flannel.1` previously. Pods whose veth peer was anchored to
`cni0` instead of Cilium's `lxc*` had silent packet drops.

**Fix**: extended `ci/scripts/migrate-cni-cilium.sh` Phase 6.5 to delete
`cni0` + `vethN*` along with `flannel.1`.

This was real and worth fixing, but only affected a subset of pods.
Coder happened to NOT be one of the pods with broken veth — its
backend was reachable via port-forward the entire time. I wasted
hours assuming this WAS the Coder blocker.

### Dead end 3: Persistent Cilium agent crashloop on talos-node-03

The Cilium agent on this node crashlooped with `PostStartHook failed`
+ `procReady not received`, 113+ restarts, survived `talosctl reboot`.
I assumed this was the Coder blocker because Coder kept landing on
that node.

**Actual fix**: re-image the node via Omni (or `talosctl reset
--graceful --reboot` to wipe the EPHEMERAL partition without a full
re-image — the lighter escalation step that I missed at the time).

Worth doing in its own right — that node WAS genuinely broken — but
moving Coder OFF that node didn't fix Coder, because the real bug was
elsewhere.

### Dead end 4: Full 4-node rolling reboot

Did `talosctl reboot` on every node serially. Cluster came back, most
services recovered, **but Coder + Goldilocks remained broken**. I
assumed at this point that Cilium 1.19.3 had a deep
cross-node-VXLAN bug on this cluster.

The reboot wasn't WRONG — the cluster's kernel state was tangled from
the migration and a reboot did clean up the network paths between
some node pairs. But it didn't fix the real Coder bug because the
real bug wasn't networking.

---

## The actual fix

**Symptom**: Traefik (same node OR different node) → Coder pod IP times
out. Coder pod → its own Service VIP returns HTTP 200.

**The clue I missed for hours**: Coder responds to its own Service
calls. If Cilium service-VIP routing were broken, that wouldn't work
either. Cilium WAS routing correctly; something at the destination was
silently dropping inbound packets.

**Root cause**: the `coder-traffic` NetworkPolicy I wrote when Coder
was first deployed allowed ingress from the `traefik` namespace on
**port 80**. But the Coder pod listens on port **8080** (the Service
does the `:80 → :8080` mapping).

Kubernetes NetworkPolicies, when enforced by Cilium, evaluate the
packet's destination port **AFTER Service DNAT**. So:

- Traefik forwards a request to `coder.coder.svc.cluster.local:80`
- Cilium's socket-LB does DNAT: dst becomes `10.244.x.y:8080`
- The packet arrives at the Coder pod's veth on port 8080
- The NetworkPolicy says "ingress from traefik allowed on port 80"
- Cilium evaluates the NP: dest port 8080 ≠ allowed port 80 → DROP
- The drop has no log entry visible in `cilium-dbg monitor --type drop`
  for the source pod, because the drop happens at the destination's
  enforcement point and isn't surfaced to the source

**One-line fix**:

```yaml
ingress:
  - from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: traefik
    ports:
      - port: 80
        protocol: TCP
      - port: 8080      # ← add this; pod's actual listen port
        protocol: TCP
```

---

## Diagnostic recipe for "Cilium silently drops"

Use this checklist BEFORE assuming Cilium itself is broken:

1. **Does the pod respond to its own Service?**
   ```bash
   kubectl -n <ns> exec deploy/<app> -- wget -qO- http://<app>.<ns>.svc.cluster.local
   ```
   If yes, Cilium service routing works. The issue is at the
   destination's ingress enforcement, not in Cilium's data plane.

2. **Does port-forward bypass the issue?**
   ```bash
   kubectl -n <ns> port-forward svc/<app> 18080:80
   curl http://localhost:18080
   ```
   port-forward goes via kubectl proxy, NOT Cilium's BPF socket-LB.
   If port-forward works but Service-VIP routing doesn't, you're
   either looking at an NP problem or a BPF socket-LB problem. The
   former is far more common.

3. **List every NetworkPolicy targeting the destination pod**:
   ```bash
   kubectl -n <ns> get networkpolicy
   kubectl -n <ns> describe networkpolicy <name>
   ```
   Cross-reference the policy's allowed ports against the pod's
   actual `containerPort` (which is what Cilium sees post-DNAT), NOT
   the Service's port.

4. **Same for CiliumNetworkPolicy / CiliumClusterwideNetworkPolicy**:
   ```bash
   kubectl get cnp -A
   kubectl get ccnp
   ```

5. **Only after confirming NPs are fine**: dig into Cilium BPF state,
   tunnel map, ipcache, endpoint state. Reach for `cilium-dbg
   monitor --type drop` and look for actual drop events on the
   destination's agent (not the source).

---

## Node-stability cheatsheet

If a specific cilium-agent pod is in CrashLoopBackOff:

| Restart count | First try | If that fails |
|---|---|---|
| 1-5 | `kubectl -n kube-system delete pod <agent>` | Wait + recheck |
| 5-20 | `talosctl reboot --nodes <ip>` | Step to next row |
| 20+ | `talosctl reset --graceful --reboot --nodes <ip>` (wipes EPHEMERAL, keeps OS, rejoins) | Re-image via Omni |
| 100+ | Re-image via Omni — disk/state corruption | (none) |

DO NOT skip ahead. `talosctl reboot` is a soft restart that preserves
`/var/lib/*` — if the corrupted state lives there, you'll waste
~5 min per cycle.

---

## What the cluster looks like 2026-05-15 ~09:00 EDT

- ✅ Coder, Dex, ArgoCD, OpenBao, Homepage, IT-Tools, Recipes, n8n,
  MeTube, OpenWebUI, Home-Assistant — all working
- ⏸️ Goldilocks — TLS handshake hangs (different bug, oauth-redirect
  middleware chain timeout, not the same NP issue as Coder)
- ⚠️ talos-node-09 + talos-node-15 — cilium-agent still showing 8-15
  restarts each over the past 14 hours; needs investigation
- ✅ Two fresh nodes (talos-node-08, talos-node-16) running clean,
  0 cilium-agent restarts since they joined

---

## Lessons

1. **Cilium NP drops are silent in source-side logs.** Look at the
   destination's BPF policy map first.
2. **Service DNAT changes the port the NP sees.** Always allow the
   pod's `containerPort`, not the Service port.
3. **When two services break together, find their common dependency**
   — Goldilocks and Coder both went through oauth-proxy. That should
   have been my first focus, not "everything is broken cross-node."
4. **`port-forward` is the cleanest "is the backend healthy"
   diagnostic.** If port-forward returns 200, the backend works; the
   issue is between Traefik and the backend.
5. **Don't reboot nodes to fix what's actually an NP rule.** I burned
   ~6 hours on Cilium state debugging when the fix was 8 lines of
   CUE.

---

## Memory entries this session created

- `feedback_provider_helm_chart_naming.md` — Coder ships `coder_helm_<ver>.tgz` instead of `coder-<ver>.tgz`; provider-helm bug fix via `chart.url`
- `feedback_cilium_migration_kernel_state.md` — cni0 + vethN must be cleaned post-Flannel
- `feedback_cilium_node_reboot_recycle.md` — cilium-agent socket-LB hooks don't re-attach post-reboot
- `feedback_cilium_agent_node_corruption.md` — talos-node-03 agent crashloop survived reboot; needs `talosctl reset` or Omni re-image
- `feedback_velero_fsb_restore_needs_pods.md` — restore PVC + Pod manifest together for kopia to run
- `feedback_cnpg_immutable_storage.md` — can't shrink Cluster.storage.size; full uninstall sequence
- `reference_unifi_dns_interception.md` — forward `example.com` to `1.1.1.1` at UniFi
- `project_home_recovery_runbook.md` — full validated rebuild procedure

…and one more pending: `feedback_cilium_np_port_post_dnat.md` (the actual root cause from this session).
