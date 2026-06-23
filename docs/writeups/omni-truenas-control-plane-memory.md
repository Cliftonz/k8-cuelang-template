# When a Talos control-plane VM runs out of RAM: an Omni + TrueNAS sizing story (and why swap is a trap)

> **Status:** Draft write-up for the `omni-truenas` provider maintainer. Field report from a homelab running Omni-managed Talos on TrueNAS-backed VMs. Not a bug in the provider per se — a sizing/defaults/documentation gap that bit a real cluster, plus a few concrete asks at the end.

## TL;DR

A single control-plane Talos VM provisioned with **12 GB RAM** slowly walked into memory exhaustion. With Talos's no-swap design, the userspace OOM controller started SIGKILL-ing best-effort pods, etcd lost its fsync latency budget, and the whole control plane cascaded:

- etcd health flapping `OK ↔ context deadline exceeded` roughly every 60s
- `kube-scheduler` in CrashLoopBackOff (90+ restarts) — dies at "waiting for caches to sync"
- `kube-controller-manager` flapping (80+ restarts) — Deployment rollouts freeze (`observedGeneration` stuck)
- `kube-apiserver` intermittently returning `etcdserver: request timed out`
- Talos's own `ManifestApplyController` failing to acquire its etcd mutex

The etcd database itself was perfectly healthy (135 MB, no alarms). **This was not a defrag problem and not a disk problem — it was RAM.** And the instinct to "just add swap" is a dead end on Talos, and an anti-pattern on an etcd node regardless.

The ask for the provider: raise (or at least loudly document) the control-plane VM memory floor, surface the no-swap reality, default to fixed/non-ballooned memory reservations for control-plane VMs, and consider nudging users away from single-control-plane topologies.

---

## Environment

| Thing | Value |
| --- | --- |
| Control plane | Omni (SaaS) |
| OS | Talos Linux (client `v1.12.5`) |
| Kubernetes | `v1.36.1` |
| etcd | `3.6.11`, storage format `3.6.0` |
| Topology | **1 control-plane node + 4 workers** (single CP — SPOF) |
| CP VM | `talos-node-14`, **12 GB RAM, no swap** |
| Hypervisor | TrueNAS-backed VMs (provisioned via the `omni-truenas` provider) |
| Workload | Small homelab platform: Crossplane, ArgoCD, ESO, Longhorn, Traefik, MetalLB, plus app namespaces |

Nothing exotic. No app workloads were even scheduled onto the control-plane node — just the static control-plane components, CoreDNS, kube-proxy, and the Omni service exposer. The ~10.7 GB in use was essentially the control-plane stack's own working set growing over ~4.5 days of uptime.

---

## Symptoms (in the order they were noticed)

1. **A workload wouldn't roll.** A Deployment spec change applied cleanly all the way down — Crossplane XR, the provider-kubernetes `Object`, the ArgoCD `ApplicationSet`, the child `Application`, and finally the `Deployment` spec all carried the new value — but no new pod ever appeared. `Deployment.status.observedGeneration` was frozen one generation behind `metadata.generation`.

2. **`kubectl` was flaky.** Roughly one in three calls returned:
   ```
   Error from server (Timeout): the server was unable to return a response in the time allotted...
   ```

3. **The control-plane static pods were unhealthy:**
   ```
   kube-scheduler-talos-node-14            0/1   CrashLoopBackOff   93 restarts
   kube-controller-manager-talos-node-14   1/1   Running            83 restarts (flapping)
   ```
   The scheduler logs showed it booting, generating its self-signed cert, then hanging at `"Waiting for caches to sync"` and exiting `1` — never completing informer sync or holding its leader-election lease long enough to be useful.

`observedGeneration` stuck + scheduler down + controller-manager flapping is a tidy explanation for "my change is everywhere except in a running pod": with the Deployment controller (in `kube-controller-manager`) repeatedly losing its lease and the scheduler unable to place pods, **no rollout and no scheduling happens cluster-wide.**

---

## Diagnostic walkthrough

The useful part of this story is the path, because the first two "obvious" culprits were both wrong.

### Step 1 — Is etcd out of space / needs defrag? (No.)

On Talos, etcd is a host service, not a Kubernetes pod, so `kubectl -n kube-system get pod etcd-...` returns `NotFound`. Use `talosctl`:

```console
$ talosctl -n 192.168.1.54 service etcd
STATE    Running
HEALTH   OK
EVENTS   [Running]: Health check successful (16s ago)
         [Running]: Health check failed: context deadline exceeded (50s ago)
         [Running]: Health check successful (1m21s ago)
         [Running]: Health check failed: context deadline exceeded (1m50s ago)
         ... (oscillating every ~60s) ...
```

So etcd is *alive but intermittently unresponsive* — it can't answer a trivial health probe within the deadline. Classic "something is blocking etcd's event loop / fsync." The reflex is to suspect a bloated DB or fragmentation:

```console
$ talosctl -n 192.168.1.54 etcd status
DB SIZE   IN USE           LEADER   RAFT INDEX   RAFT APPLIED INDEX   ERRORS
135 MB    62 MB (46.23%)   <self>   9119967      9119935              <none>

$ talosctl -n 192.168.1.54 etcd alarm list
(no alarms)
```

135 MB is tiny. No `NOSPACE` alarm. Defrag would reclaim ~70 MB of nothing-in-particular. **etcd is not the problem; something underneath it is.**

### Step 2 — Is the disk bad? (No — it's memory.)

```console
$ talosctl -n 192.168.1.54 read /proc/meminfo
MemTotal:       12218068 kB    # ~11.65 GiB
MemFree:          626148 kB
MemAvailable:    1470968 kB    # ~1.4 GiB available
SwapTotal:             0 kB    # no swap
```

~1.4 GB available of ~12 GB, **zero swap**. And the kernel ring buffer told the rest of the story:

```console
$ talosctl -n 192.168.1.54 dmesg | grep -i oom
[talos] OOM controller triggered {"controller": "runtime.OOMController"}
[talos] Sending SIGKILL to cgroup {"cgroup": ".../kubepods/besteffort/pod3653405b-..."}
[talos] victim processes: {"processes": [106719]}
... (repeating in a tight loop) ...

$ talosctl -n 192.168.1.54 dmesg | tail
[talos] service[etcd](Running): Health check failed: context deadline exceeded
[talos] controller failed {"controller": "k8s.ManifestApplyController",
        "error": "error acquiring mutex for key talos:v1:manifestApplyMutex: etcdserver: request timed out"}
```

The OOM victim cgroup resolved to **`kube-proxy`** — a best-effort (no requests/limits) pod. But kube-proxy is the *victim*, not the cause: under node memory pressure Talos's userspace OOM controller kills the lowest-QoS cgroup it can find. The actual consumer was the control-plane working set itself; there were no app pods on the node to blame.

### Root cause

**The control-plane VM was under-provisioned on memory for its role.** 12 GB with no swap headroom is marginal for `kube-apiserver` + etcd + `kube-controller-manager` + `kube-scheduler` once watch caches and working sets grow over days of uptime. Once `MemAvailable` got low enough:

1. Talos's OOM controller began reaping best-effort cgroups (kube-proxy) on a loop.
2. Memory pressure + reclaim stalls blew etcd's fsync/health-check latency budget → etcd flapping.
3. A flapping etcd means slow/failed apiserver requests.
4. Slow apiserver means `kube-scheduler` and `kube-controller-manager` can't sync informer caches or renew their leader-election leases → CrashLoopBackOff.
5. No scheduler + no controller-manager → no scheduling, no Deployment rollouts, and `observedGeneration` freezes.

A single under-sized control-plane node turned a slow memory leak-by-accretion into a full control-plane brownout.

---

## Why "just add swap" is the wrong instinct

This was the natural next question, and it's worth writing down *why* it's a trap, because other users will ask it too.

1. **Talos doesn't support swap, by design.** Talos is an immutable, API-only OS with no shell. There's no `swapon`, no way to drop a swap file onto the managed partitions, and no machine-config field to enable it. `SwapTotal: 0` is not a setting you forgot to flip.

2. **Even if you could, swap on an etcd/control-plane node is an anti-pattern.** etcd's performance model is dominated by fsync latency, and the upstream guidance is explicitly to disable swap. The instant etcd pages get swapped, its read/write latency spikes — which is *exactly* the "health check context deadline exceeded" flapping already in progress. You'd be converting hard OOM kills into sustained latency death. Strictly worse for the failure mode at hand.

Swap is not a memory-headroom safety net here. **More RAM is the only real lever.**

---

## The fix

- **Immediate stopgap:** reboot the control-plane node (`talosctl reboot`) to reclaim memory and restart the control-plane components fresh. On a single-CP cluster this is a ~1–2 minute full-API outage, but the node was already degraded, so the marginal risk is low.
- **Durable fix:** raise the control-plane VM's memory (this cluster: 12 GB → 24 GB) and reboot. Because the resize requires a reboot anyway, doing the resize *is* the stopgap — one outage fixes both the immediate pressure and the undersizing.
- **Structural fix:** move off a single control-plane node. One CP node means its etcd hiccup is a cluster-wide scheduling outage and any CP maintenance is a full outage.

---

## Asks for the `omni-truenas` provider

None of this is strictly a provider *bug* — but the provider is where the defaults and guidance live, and good defaults would have prevented the whole incident. In rough priority order:

1. **Raise or prominently document the control-plane memory floor.** 12 GB is enough to bootstrap and look healthy for days, then brown out. A control-plane/etcd VM default in the **16–24 GB** range (or at minimum a documented "do not go below X for control-plane roles, and here's why") would stop users from picking a number that works at install time and fails a week later. Consider distinguishing control-plane vs worker defaults explicitly.

2. **Surface the no-swap reality in the docs.** Users coming from generic Linux VMs assume swap is a backstop. A short note — "Talos has no swap; size control-plane RAM with headroom; etcd performance depends on it" — saves a lot of confused debugging.

3. **Default control-plane VMs to fixed, non-ballooned memory.** *This is the TrueNAS-specific one.* If the provider provisions VMs with memory ballooning / dynamic memory / host overcommit enabled, an etcd node is the worst possible place for it — the hypervisor reclaiming guest pages under host pressure produces precisely this fsync-stall failure mode, and it's invisible from inside the guest. Please default control-plane VMs to a **fixed memory reservation with ballooning disabled** (and document it for worker VMs as a tunable). If the provider already does this, saying so explicitly in the docs would be reassuring.

4. **Consider warning on single-control-plane topologies** at provision time, or making a 3-node control plane the documented "real cluster" default with single-CP flagged as lab-only.

5. **Optional, nice-to-have:** ship or document sane Talos `kubelet` reservations (`systemReserved` / `kubeReserved` / eviction thresholds) for control-plane nodes so best-effort pods like kube-proxy aren't the first thing the OOM controller reaps, and so the kubelet evicts gracefully before the node hits hard OOM.

If any of these are already handled and I just didn't find them in the docs, that itself is a docs-discoverability signal worth acting on.

---

## Appendix: quick reference for diagnosing this on Talos

```bash
N=<control-plane-node-ip>

# etcd is a host service, not a pod — check it via talosctl, not kubectl
talosctl -n $N service etcd          # flapping health = something starving etcd
talosctl -n $N etcd status           # DB size / alarms — rule out bloat/defrag
talosctl -n $N etcd alarm list

# memory pressure is the usual hidden cause
talosctl -n $N read /proc/meminfo    # MemAvailable + SwapTotal (0 on Talos)
talosctl -n $N dmesg | grep -i oom   # Talos OOMController SIGKILL loop?

# control-plane health from the k8s side
kubectl -n kube-system get pods -o wide | grep -E 'scheduler|controller-manager|apiserver'
# scheduler stuck at "waiting for caches to sync" + CrashLoopBackOff == apiserver/etcd too slow

# the tell that it's a control-plane brownout, not a workload bug:
kubectl get deploy <name> -o jsonpath='gen={.metadata.generation} observed={.status.observedGeneration}'
# observed < gen, frozen == controller-manager isn't reconciling
```

Rule of thumb: **flapping etcd health + small healthy DB + low MemAvailable + zero swap = under-sized control-plane RAM, not a defrag or disk problem.** Reach for more RAM, never swap.
