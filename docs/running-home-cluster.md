# Running a Production Home Kubernetes Cluster on HDD-Only Storage

> A deep dive into operating a Talos+Omni cluster on TrueNAS-backed VMs
> with no SSDs available. Covers the architectural decisions forced by
> slow disk, the failure modes we hit during 4 days of bootstrap-and-burn,
> the tuning that actually moved the needle, and the operating procedures
> that emerged from the post-mortems.

---

## Table of Contents

1. [The Setup — Hardware We Had to Work With](#the-setup)
2. [Cold Open — Why HDD-Backed Kubernetes Is Hard](#cold-open)
3. [Decision One: Drop From 3 CPs to 1](#decision-one)
4. [Decision Two: Tune etcd for HDD Reality](#decision-two)
5. [Decision Three: Trim Crossplane XRDs](#decision-three)
6. [The Bootstrap Order Matters (A Lot)](#bootstrap-order)
7. [Pod Security Standards: The Silent Killer](#pss-trap)
8. [Longhorn: 10-Minute Boot Choreography](#longhorn-dance)
9. [OpenBao: The Bootstrap Chain](#openbao-chain)
10. [UniFi DNS and the Rotating API Key](#unifi-dns)
11. [The Sibling Service Pattern](#sibling-service)
12. [Multi-Zone Traefik and DNS Targeting](#multi-zone-traefik)
13. [HTTPS Backends: Home Assistant Self-Signed](#https-backends)
14. [Crossplane Recovery Playbook](#crossplane-recovery)
15. [The Bootstrap Script: 30 Minutes vs. 4 Hours](#bootstrap-script)
16. [Common Gotchas Cheat Sheet](#gotchas)
17. [Maintenance and Backup](#maintenance)
18. [Lessons in One Line Each](#lessons)

---

<a id="the-setup"></a>
## 1. The Setup — Hardware We Had to Work With

| Component | Spec |
|---|---|
| Hypervisor | TrueNAS SCALE on a household-tier server (Linux KVM) |
| Storage | **HDD pool only — zero SSDs** |
| Control plane | 1 VM (single — see §3 for why) |
| Workers | 3 VMs |
| Per-CP | 4 GiB RAM, 2 vCPU, 5–20 GiB root disk |
| Per-worker | 4 GiB RAM, 2 vCPU, 5 GiB root + 100 GiB Longhorn data disk |
| Network | Single VLAN (vlan10, 192.168.1.0/24) |
| Cluster manager | Sidero Omni (cloud-hosted) |
| Distro | Talos Linux 1.13.0 |
| Kubernetes | v1.36.0 |

### Verified Stable Spec (per VM, after several iterations)

The 4 GiB / 2 vCPU starting point flapped under bootstrap load on this
cluster (HDD-bound etcd + Crossplane reconcile burst). After scaling up
the per-VM resources we got **stable, no-flap operation**:

| Knob | Value | Notes |
|---|---|---|
| vCPU | **8** | Burst headroom for apiserver + etcd compaction + Longhorn manager |
| Memory min | **6 GiB** | TrueNAS VM "minimum allocation" — guaranteed floor |
| Memory max | **12 GiB** | TrueNAS VM "maximum allocation" — burst ceiling under reconcile load |
| Memory steady | **~8 GiB** | What the VM typically sits at |

The asymmetric min/max takes advantage of TrueNAS's KVM ballooning:
the VM holds 6 GiB at all times (so it can't be starved by other VMs)
but can grow to 12 GiB when apiserver watch-caches expand or Longhorn
manager spikes. Under steady-state household-services load the VM
floats around 8 GiB.

Each of the 4 VMs (1 CP + 3 workers) gets this spec → ~32 GiB
guaranteed / 48 GiB burst / 32 vCPU across the cluster. That's the
floor where bootstrap completes cleanly without `etcdserver: request
timed out` cascades or apiserver OOMs.

If you have less RAM available, the realistic minimum is 4 GiB / 2 vCPU
per VM but expect to need pauses between bootstrap phases (the script's
default mode) and likely manual recovery if Crossplane bursts cause
apiserver to flap.

**The crucial number is "HDD-only"**. Every architectural decision
downstream of that constraint is forced by it. If you have SSDs, your
cluster will tolerate things ours did not. Read this guide as
"engineering inside a constraint", not "best practices for everyone".

The cluster runs always-on household services: Home Assistant, Traefik
proxying to a fleet of NAS apps (n8n, recipe manager, web UIs), Longhorn
for persistent volumes, OpenBao for secret storage, plus the full preview
cluster's ArgoCD + ArgoEvents + Kelos AI pipeline merged in (because we
didn't have spare hardware for a second cluster).

That workload is "boring" in steady state — maybe 10 reqs/sec to apiserver
on a quiet day. But during bootstrap, **the simultaneous installation of
Crossplane (39 XRDs), External Secrets Operator, Longhorn (4 nodes
joining), and 9 helm releases** drives apiserver writes into the
hundreds-per-second range. That's where HDD storage falls apart.

---

<a id="cold-open"></a>
## 2. Cold Open — Why HDD-Backed Kubernetes Is Hard

Open the etcd documentation and you'll find this line buried in the
hardware recommendations:

> "etcd writes data to disk and persists proposals on disk. Slow disks
> will increase etcd request latency and potentially hurt cluster
> stability. **etcd's storage performance is bound by p99 fsync latency
> below 10ms.**"

A modern SSD does fsync in 0.1–1 ms. A 7200 RPM SATA HDD under no load
does maybe 5 ms. **Under load it spikes to 50–200 ms.** That's 10–20×
over etcd's threshold.

Here's what happens when etcd misses its fsync window:

```
[etcd peer 1]  write request → fsync starts → ... 80ms ...
[etcd peer 2]  heartbeat sent at t=0          ← peer 1 doesn't ack in time (default 100ms)
[etcd peer 3]  ↑ assumes peer 1 is dead, requests election
[etcd peer 1]  fsync completes → "wait, who's leader?" → requests election
              → all three are now electing simultaneously → no leader for ~5s
```

While there's no leader, every apiserver request returns:

```
etcdserver: leader changed
etcdserver: request timed out
```

Now the cascade:

1. `kube-apiserver` retries failed requests, backs up the request queue
2. `kube-controller-manager` can't renew its leader-election lease (5s
   default deadline) → process exits → kubelet restarts the static pod →
   crashloop
3. `kube-scheduler` same story
4. kubelet's `node-status-update` tries to PATCH the node object →
   apiserver times out → kubelet marks itself "unhealthy" to Omni
5. Omni shows the CP node as `READY: false`
6. Operator (you) panics

We watched this exact cascade for hours. **It looked like 30 different
problems**: apiserver crashlooping, CM crashlooping, kubelet flapping,
"Omni shows the cluster as not ready", "Crossplane resources stuck
synced=false". They were all one problem: etcd couldn't keep up with
disk fsync.

The rest of this article is everything we did to make a Crossplane-heavy
cluster usable on HDD storage.

---

<a id="decision-one"></a>
## 3. Decision One: Drop From 3 CPs to 1

We started with the textbook 3-CP HA setup. **It does not work on
HDD-backed storage with a Crossplane-heavy workload.**

Why HA makes things worse, not better:

### Multi-CP etcd writes are 3× the disk work

Every Kubernetes write goes through etcd's Raft consensus:

1. Leader receives write
2. Leader proposes to followers
3. Each follower **fsyncs the proposal to its own disk** before ACKing
4. Once majority (2/3) ACKs, leader commits and **fsyncs again**

So a single Kubernetes write = 4 fsync events across 3 disks. On SSD
that's 4×0.5ms = 2ms. On HDD under load that's 4×100ms = 400ms PER
write. With 100 writes/sec target, you'd need 40 seconds of disk per
second. The math doesn't work.

### Peer disagreement spirals

When peer 1 is fsync'ing slowly, peers 2 and 3 think it died and trigger
elections. Now peer 1 finishes its fsync and sees an election it didn't
join → it triggers its own election → all three are electing
simultaneously → leader churn.

Single-CP etcd has no peers. **No consensus. No election. Each write
fsyncs once and commits.** It's "tolerant of slow disk" by design.

### What you give up with single CP

- HA. If the CP node dies, the cluster can't accept new workloads or
  update existing ones until you reboot.
- Workers continue serving traffic during a CP outage (they don't need
  the CP for already-running pods). So Longhorn volumes stay accessible,
  Traefik keeps routing, etc. — only the *control plane* is down.

For a home cluster where "the CP is down for 5 minutes" is acceptable,
this is the right trade. For production with 99.9% uptime SLA, get SSDs
or accept 3 CPs on different storage tiers.

### Promotion path

If you later get SSD or move CP to faster storage:

```bash
# In Omni: Cluster → Machine Sets → talos-home-control-planes → Replicas: 3
# Talos automatically joins 2 more CP nodes to the etcd cluster.
# No data loss, ~10 min rolling join.
```

You go from 1 CP to 3 CPs without rebuilding anything.

---

<a id="decision-two"></a>
## 4. Decision Two: Tune etcd for HDD Reality

Even with single-CP, default etcd settings assume SSD-class disk. We had
to bump every timing-sensitive parameter.

### Default vs. HDD-tuned values

| Parameter | Default | HDD-tuned | Why |
|---|---|---|---|
| `--heartbeat-interval` | 100ms | **500ms** | HDD fsync routinely >100ms; heartbeat must absorb this |
| `--election-timeout` | 1000ms | **5000ms** | etcd guidance: 10× heartbeat |
| `--auto-compaction-mode` | unset | `periodic` | run compaction on a fixed schedule |
| `--auto-compaction-retention` | unset | `30m` | smaller DB = faster fsync per write |
| `--quota-backend-bytes` | 2 GiB | **4 GiB** | Crossplane + ESO push past 2 GiB on first install |
| `--snapshot-count` | 100000 | 100000 (kept) | how many revisions before snapshot — bigger value = fewer (huge) snapshot fsyncs |

These are applied via `infrastructure/talos/etcd-tuning.yaml`:

```yaml
cluster:
  etcd:
    extraArgs:
      heartbeat-interval: "500"
      election-timeout: "5000"
      auto-compaction-mode: periodic
      auto-compaction-retention: "30m"
      quota-backend-bytes: "4294967296"
      snapshot-count: "100000"
```

### The CP-only scoping trap

This patch **must be scoped to control planes only**. Talos rejects
`cluster.etcd:` on worker machines with this error:

```
v1alpha1.Config: 1 error occurred:
  * etcd config is only allowed on control plane machines
```

Workers then can't merge their machine config and get stuck in
maintenance mode. They show up in Omni as `configuptodate: false`.

Omni's `ConfigPatch` resource scopes via labels. The pattern that
**doesn't work**:

```yaml
labels:
  omni.sidero.dev/cluster: talos-home
  omni.sidero.dev/role-controlplane: ""   # <-- DOES NOT match ConfigPatches
```

`role-controlplane` is set on `ClusterMachine` resources but isn't a
label-selector key for `ConfigPatch`. We learned this by watching the
patch get applied to all 7 machines despite the label.

The pattern that **works**:

```yaml
labels:
  omni.sidero.dev/cluster: talos-home
  omni.sidero.dev/machine-set: talos-home-control-planes   # <-- correct
```

The `machine-set` label is set on every ClusterMachine and ConfigPatch
matches it. Workers have `omni.sidero.dev/machine-set: talos-home-workers`
so they're not selected.

### Apiserver tuning (cluster-wide, no etcd)

The companion patch `infrastructure/talos/apiserver-tuning.yaml` covers
kube-apiserver, controller-manager, and scheduler. It's safe on workers
because Talos silently ignores `apiServer:` / `controllerManager:` /
`scheduler:` blocks on non-CP nodes.

Key values:

```yaml
cluster:
  apiServer:
    extraArgs:
      max-requests-inflight: "1500"          # default 400 — handle burst
      max-mutating-requests-inflight: "700"  # default 200
      watch-cache-sizes: "compositeresourcedefinitions.apiextensions.crossplane.io#500,releases.helm.crossplane.io#500"
      request-timeout: "2m0s"                # default 1m — slower etcd needs longer
    resources:
      requests: {cpu: 500m, memory: 1Gi}
      limits:   {memory: 2500Mi}              # was 1Gi default — XRDs blow past
  controllerManager:
    extraArgs:
      kube-api-qps: "25"           # default 100 — flood reduction
      kube-api-burst: "40"         # default 200
      leader-elect-lease-duration: 60s   # default 15s
      leader-elect-renew-deadline: 40s   # default 10s — survive fsync spikes
      leader-elect-retry-period:    5s   # default 2s
      node-monitor-grace-period: 60s     # default 40s — don't mark nodes NotReady on apiserver blips
  scheduler:
    extraArgs:
      kube-api-qps: "25"
      kube-api-burst: "40"
      # same leader-elect bump as CM
```

### Why `kube-api-qps: 25` (down from default 100)

Each CM request → apiserver write → etcd fsync. At 100 qps × 2 controllers
× 3 CPs (in HA) you'd push 600 writes/sec to etcd just for the
controllers' background reconciles. On HDD that's overload by an order
of magnitude.

25 qps cuts background load 4×. Real workload throughput isn't affected
because actual reconciles are bursty, not sustained.

### Why `leader-elect-renew-deadline: 40s` (default 10s)

On HDD, etcd commits routinely take 5–15s during compaction or heavy
write bursts. A 10s deadline is missed → CM exits → static-pod
crashloops → kubelet restarts → CM starts up → tries to renew → misses
again → loop forever.

40s absorbs the worst fsync spikes. The trade-off: if a CM truly dies,
recovery takes 40s instead of 10s. For our use case that's fine.

### Apiserver memory: 1 GiB → 2.5 GiB

The default 1 GiB limit gets OOMKilled when there are 27+ XRDs because
each CRD's watch cache and informer state lives in apiserver memory.

Rough budget on a 4 GiB CP node:

| Component | Steady | Peak |
|---|---|---|
| kernel + system | 200–300 MiB | 400 MiB |
| containerd + kubelet | 200 MiB | 300 MiB |
| etcd | 500 MiB | 1 GiB (during compaction) |
| kube-apiserver | 1.5 GiB | 2 GiB (during reconcile burst) |
| controller-manager | 300 MiB | 500 MiB |
| scheduler | 150 MiB | 250 MiB |
| flannel + kube-proxy | 100 MiB | 100 MiB |
| **total** | **~3 GiB** | **~4.5 GiB** |

That's the limit on what a 4 GiB CP can carry. There is zero room to
also run pods on the CP — and we don't (workers carry all workloads).

### kubelet patch (separate, cluster-wide)

```yaml
machine:
  kubelet:
    extraArgs:
      node-status-update-frequency: 30s   # default 10s
```

Each kubelet status tick is one apiserver write per node. With 4 nodes
that's 24 writes/min at default. Bumping to 30s cuts kubelet's
background etcd load by 3×.

This patch is safe cluster-wide (kubelet runs everywhere), so it doesn't
need machine-set scoping.

### Verifying the patch took effect

```bash
omnictl get configpatches --selector omni.sidero.dev/cluster=talos-home

# Per-machine verification
omnictl get clustermachinestatus --selector omni.sidero.dev/cluster=talos-home

# Look for: configuptodate: true on every machine
# Watch: kubectl -n kube-system get pods | grep apiserver
# After patch rolls: 0 restarts, mem-limit reflects new value
kubectl -n kube-system get pod kube-apiserver-talos-X -o jsonpath='{.spec.containers[0].resources.limits.memory}'
# Should print: 2500Mi
```

A clean roll takes ~5 minutes per CP — Talos rewrites the static-pod
manifest, kubelet restarts the apiserver pod with the new spec, etcd
restarts last (most disruptive). Plan for ~15 min total downtime on
3-CP, ~5 min on 1-CP.

---

<a id="decision-three"></a>
## 5. Decision Three: Trim Crossplane XRDs

This was the single biggest stability improvement we made. **Bigger than
any tuning patch.**

### The XRD Memory Tax

Every CompositeResourceDefinition (XRD) you install creates a CRD in the
cluster. Each CRD costs apiserver:

- A watch cache (configurable, default 100 entries × ~10 KB each = 1 MB)
- An informer goroutine
- An admission validation handler
- Schema validation memory for every API call to that resource
- Storage in etcd (negligible until you create instances)

Crossplane adds another tax: every XRD spawns a corresponding `Composition`
controller goroutine that watches the XRD's resources and reconciles.

Repository default: render **all 39 XRDs** to every cluster, even if the
cluster only uses 12 of them. Why? Because preview cluster wanted them
all. Easier to render the union than parameterize.

The cost on home cluster (single CP, 4 GiB): apiserver memory under
load was hitting the 1 GiB default limit and OOMing. Watch caches alone
were ~400 MB of that.

### The fix: usage-driven XRD rendering

We added an `_xrdMap` data structure in `export/all.cue` that pairs each
composite list field name (e.g. `helmReleases`, `argoSensors`) with its
XRD definition and its standard Composition.

```cue
_xrdMap: {
    helmReleases:    {definition: xrd.xHelmRelease,    composition: ...helmReleaseComposition}
    argoSensors:     {definition: xrd.xArgoSensor,     composition: ...argoSensorComposition}
    kelosWorkspaces: {definition: xrd.xKelosWorkspace, composition: ...kelosWorkspaceComposition}
    // ... 30 entries
}
```

Then for each cluster, we compute which composite list types are
non-empty:

```cue
_clusterUsedFields: {
    for _name, _c in _allClusters {
        (_name): [for k, _ in _xrdMap if len(_c[k]) > 0 {k}]
    }
}
```

`_platformXRDsPerCluster[home]` is then the list of XRDs whose
corresponding composite field is populated on the home cluster.

### Results

| Cluster | Before | After |
|---|---|---|
| home (pre-merge) | 39 | **12** (saved ~250 MB apiserver memory) |
| home (post-merge with preview) | 39 | **27** |
| preview | 39 | **24** |

When you stop using a resource type, the XRD drops out automatically on
next render. When you add a new type to a composite, the XRD auto-includes.

### Caveat: don't trim XRDs that XRs reference

If a cluster has any composite resource (XR) of a given type, that
type's XRD must be present. The CUE filter handles this correctly
because it counts list length — non-empty list means at least one XR,
means the XRD ships.

The XRDs that are NEVER rendered now (across all clusters):
xHTTPRoute, xWorkloadIdentity, xNamespacePolicy, xBackupPolicy,
xDatabase, xRedis, xBucket, xServiceMonitor, xLogSink, xRuntimeClass,
xSecretStore. They exist in `platform/xrd/` for future use but no
composite references them yet.

### What "watch-cache-sizes" does

The apiserver tuning patch includes:

```yaml
watch-cache-sizes: "compositeresourcedefinitions.apiextensions.crossplane.io#500,releases.helm.crossplane.io#500"
```

This raises the cache size for two specific types from default 100 to
500. Why these two: they're the ones Crossplane provider-helm hits most
during reconcile. A bigger cache = fewer cache misses = fewer etcd
fetches. Tradeoff: 400 extra entries × ~50 KB (helm releases are big)
≈ 20 MB of apiserver memory. Worth it for the etcd write reduction.

---

<a id="bootstrap-order"></a>
## 6. The Bootstrap Order Matters (A Lot)

Bursting all manifests in one `kubectl apply -R -f clusters/home/`
overwhelms etcd on HDD. Apiserver returns proxy errors mid-apply, some
resources get partially created, finalizers get stuck, and you spend
the next hour cleaning up half-formed Crossplane Objects.

The bootstrap script `ci/scripts/bootstrap-home.sh` walks 9 phases with
health gates between each. **Default mode is paused** — operator
presses ENTER to advance after verifying state. Pass `--no-pause` for
unattended runs.

### The phase order, with reasoning

#### Phase 1: Preflight

Verifies `kubectl`, `helm`, `cue`, `yq`, `jq`, `omnictl`, `talosctl`
are installed. Warns if `bao`, `cloudflared`, `argocd` are missing
(used in later manual steps). Confirms `kubectl cluster-info`
reachable.

If anything's missing, fix it now. Bootstrap won't recover from a
missing `cue` half-way through.

#### Phase 1.5: Talos ConfigPatches

Applies `400-apiserver-tuning-talos-home` and `400-etcd-tuning-talos-home`
ConfigPatches to Omni. Waits for kube-apiserver pods to roll with the
new memory limit (signals Talos has propagated the patch).

Then waits for `kubectl get --raw='/healthz'` to return `ok` (etcd
healthy after restart).

This phase is **idempotent and fast on re-run**: if the patch is already
applied at the same version, Omni no-ops.

#### Phase 2: Talos data-disk check

Loops node IPs, runs `talosctl get volumestatus -n <ip>`, verifies
the `u-longhorn` volume is `ready`. This volume is provisioned by
`infrastructure/talos/longhorn-uservolume.yaml` (a UserVolumeConfig
that picks any disk >50 GiB and formats it XFS at `/var/mnt/longhorn`).

Without this, Longhorn would store volume data on the root disk. The
root disk is small (5–20 GiB), Longhorn images alone consume 2 GiB,
and a single Longhorn volume snapshot fills the rest. DiskPressure
evicts the manager pod. Cluster pretends Longhorn is broken.

Skip this phase only if you've verified the disks elsewhere
(`SKIP_TALOS_CHECK=1`).

#### Phase 3: Longhorn install

Runs `infrastructure/longhorn/install.sh` which `helm upgrade`s the
chart at version 1.7.2 and waits for the StorageClass to register.

Skip the iscsi pre-flight on Talos (`SKIP_PREFLIGHT=1`) because Talos
PID 1 has no shell — the nsenter probe in install.sh can't run. The
extension is verified separately via Phase 2.

Wait condition: `kubectl get storageclass longhorn` returns success.
This typically takes 8–15 min on slow disk because the chart has many
manager + CSI pods and they race the conversion-webhook coming up.

#### Phase 3.5: metrics-server

Optional. Only useful if `infrastructure/talos/kubelet-cert-rotation.yaml`
is applied as a machine config patch + nodes rebooted. Without that,
metrics-server can't talk to kubelets without `--kubelet-insecure-tls`
and you get warnings.

We skip this on home (no monitoring stack on this cluster).

#### Phase 4: CloudNativePG

Auto-skipped if no rendered manifest references CNPG. Home has no
databases via XDatabase, so skip.

The detection uses `grep -l 'XDatabase\|cnpg.io' clusters/home/`.
Override with `INSTALL_CNPG=1` to force install.

#### Phase 5: Crossplane UXP + providers + functions

Runs `infrastructure/crossplane/install.sh`. Order matters within:

1. UXP helm release (Crossplane core)
2. provider-helm package
3. provider-kubernetes package
4. provider-harbor (only if `INSTALL_HARBOR=1` — auto-detects from XRDs)
5. function-patch-and-transform (always required)
6. function-extra-resources (only if a composition uses it)
7. ProviderConfigs (after CRDs from providers are Established)

Wait condition: `kubectl wait --for=condition=Healthy provider/...`
returns for each installed provider, plus active FunctionRevision for
each function.

**This phase often takes 5+ minutes** because Crossplane downloads
provider images on first install (each ~200 MB) and the function
controllers do schema validation on first revision.

#### Phase 6: CUE render

`make validate && make export-cluster CLUSTER=home`. CUE vets, then
renders ~190 manifests into `clusters/home/`. Local-only, no cluster
calls.

#### Phase 7: Apply

The complex one. Order:

1. `clusters/home/xrds/` — apply all XRDs. Wait `--for=condition=Established`.
2. `clusters/home/compositions/` — apply Compositions (must wait on XRD
   Establishment first or compositions reference unknown types).
3. `clusters/home/namespaces/` — XNamespace resources. Crossplane
   reconciles → provider-kubernetes Object → real Namespace.
4. `clusters/home/policies/` — ResourceQuotas + NetworkPolicies.
5. `clusters/home/rbac/` — ClusterRoles, RoleBindings, ServiceAccounts.
6. `clusters/home/helm/` — XHelmRelease resources. Crossplane reconciles
   → provider-helm Release → helm install. This is the heaviest phase.
7. Top-level XRs (XExternalBackend, XServersTransport, XExposedService,
   XIngress, XJob, XCronJob, XKelosWorkspace, etc.).

Each kubectl apply call is wrapped in `kubectl_apply_with_retry` which
retries on these specific errors:
- `etcdserver: request timed out`
- `proxy error`
- `TLS handshake timeout`
- `connection reset by peer`
- `no endpoints available`

Real validation/RBAC errors fail fast.

#### Phase 8: Wait for HelmReleases

```bash
kubectl wait --for=condition=Ready release.helm.crossplane.io --all \
  --timeout=15m
```

If any release is stuck "uninstalling" (see §14 for recovery), this
will time out. The script logs a warning and continues.

#### Phase 9: Manual instructions

Prints:
1. OpenBao seed via `~/k8-infra-openbao-backup-*/reseed.sh`
2. UniFi key re-seed (the one in the backup file is rotated)
3. Cloudflare tunnel registration
4. ESO sync verification
5. Smoke test commands

You run these by hand. Bootstrap is "done" but the cluster isn't fully
useful until secrets are seeded.

### `pace()` — the secret weapon

Between heavy phases the script calls `pace()`:

```bash
pace() {
  [[ "${BOOTSTRAP_PACE:-}" == "slow" ]] || return 0
  log "pace: waiting for kube-apiserver /healthz to stay green"
  wait_apiserver_calm || true
}
```

`BOOTSTRAP_PACE=slow` is auto-enabled when the cluster isn't Talos+Omni
(can't apply tuning patches remotely). On Talos+Omni it's off by
default — the patches handle the headroom.

`wait_apiserver_calm` polls `kubectl get --raw='/healthz'` every 5s
until it returns `"ok"`. If etcd is the failing check, `/healthz`
returns `[-]etcd failed` and we keep waiting.

Default timeout: 5 minutes. If apiserver doesn't calm in 5 min, log a
warning and continue anyway (the next phase might still succeed if it's
a transient blip).

---

<a id="pss-trap"></a>
## 7. Pod Security Standards: The Silent Killer

Two of our most important DaemonSets — Longhorn manager and MetalLB
speaker — need privileged Pod Security Standards (PSS). Both
namespaces start with the cluster default (which is `baseline` on
modern Kubernetes), and both rejected the pods at creation time:

```
Error creating: pods "longhorn-manager-xxx" is forbidden: violates
PodSecurity "baseline:latest": hostPath volumes (volumes "boot", "dev",
"proc", "longhorn"), privileged (container "longhorn-manager" must not
set securityContext.privileged=true)

Error creating: pods "metallb-speaker-yyy" is forbidden: violates
PodSecurity "baseline:latest": non-default capabilities (container
"speaker" must not include "NET_RAW" in securityContext.capabilities.add),
host namespaces (hostNetwork=true), hostPort (container "speaker" uses
hostPorts 7472, 7946)
```

What you see in `kubectl get pods -n longhorn-system`: nothing. Zero
manager pods. The DaemonSet controller logs are silent because the
events are at namespace level. You only catch this by:

```bash
kubectl get events -n longhorn-system --sort-by=.lastTimestamp
# look for: "FailedCreate" + "violates PodSecurity"
```

Cluster appears broken. Longhorn says "no nodes". You poke at MetalLB,
it says "no speakers, can't ARP-announce". You blame networking.

### The fix

Label the namespace with privileged PSS:

```yaml
metadata:
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit:   privileged
    pod-security.kubernetes.io/warn:    privileged
```

Once the label lands, the DaemonSet controller's next reconcile creates
the pods. **No need to delete the DaemonSet** — controller retries
automatically.

### Expressing this in CUE

We extended the `XNamespace` XRD with an optional `labels` field:

```cue
spec: {
    name:    "longhorn-system"
    tier:    "production"
    cluster: "home"
    owner:   "platform-team"
    labels: {
        "pod-security.kubernetes.io/enforce": "privileged"
        "pod-security.kubernetes.io/audit":   "privileged"
        "pod-security.kubernetes.io/warn":    "privileged"
    }
}
```

The composition's patch uses `policy.toFieldPath: MergeObjects` so the
caller-supplied labels merge **on top of** the platform-managed ones
(`app.kubernetes.io/managed-by`, `infra.k8/cluster`, etc.) instead of
replacing them.

This was non-obvious. Our first attempt:

```cue
policy: {
    fromFieldPath: "Optional"
    mergeOptions: keepMapValues: true   // <-- WRONG
}
```

Crossplane patch-and-transform v1beta1 doesn't have `mergeOptions`. The
correct field is `policy.toFieldPath: MergeObjects` — a single value
that says "merge into the destination map instead of replacing it".

### The Helm + XNamespace race

Provider-helm's chart install creates the namespace before Crossplane's
XNamespace Object reconciles. Helm's namespace doesn't have our labels.
Two paths:

1. **CUE-driven (what we do)**: XNamespace's `spec.labels` lands seconds
   after the namespace exists. The DaemonSet controller's next reconcile
   creates pods. Acceptable but means a brief window where the DS is
   blocked.
2. **Runtime kubectl annotate**: immediate but doesn't survive cluster
   wipe. Don't do this — it bites you on rebuild.

Path 1 is what we ship. The time gap is sub-minute on a healthy cluster.

---

<a id="longhorn-dance"></a>
## 8. Longhorn: 10-Minute Boot Choreography

Longhorn is the most complex install in the stack. First boot involves
many pods coming up in a specific order, with multiple race conditions
that are normal-but-scary.

### The dependency chain

```
1. longhorn-ui (Deployment)              ← starts immediately, doesn't matter
2. longhorn-manager (DaemonSet, N pods)  ← needs PSS=privileged
   ↓
3. longhorn-conversion-webhook (Service) ← managers register CRDs through it
   ↓
4. longhorn-driver-deployer (Job)        ← waits for manager Service
   ↓ creates:
5. csi-attacher / csi-provisioner / csi-resizer / csi-snapshotter
   csi-plugin (DaemonSet)
   ↓
6. nodes.longhorn.io (custom resources)  ← managers register their nodes
   ↓
7. StorageClass "longhorn"               ← finally usable
   ↓
8. PVC "data-openbao-0" can bind         ← downstream waits start unblocking
```

Total time: **8–15 minutes on HDD** for a 4-node cluster. Don't poke
at it before then.

### Common scary-but-normal states

#### longhorn-manager pods at 1/2 with restart count 3+

```
NAME                     READY   STATUS             RESTARTS
longhorn-manager-7qwt9   1/2     CrashLoopBackOff   3 (1m ago)
longhorn-manager-9kdrv   1/2     ContainerCreating  0
```

Why: managers race the conversion-webhook coming up. The first manager
to start tries to register CRDs through a webhook that doesn't exist
yet → crashes → restarts → by then webhook is up → succeeds.

This is normal during first boot. After 5 min if any manager is still
in CrashLoopBackOff, look at the logs:

```bash
kubectl -n longhorn-system logs longhorn-manager-XXX --previous | tail -20
```

#### "Failed to check endpoint conversion-webhook"

Same race. The manager waits up to 60s for webhook then exits with
`Error starting manager: conversion webhook service is not accessible`.
Talos kubelet restarts it, on retry the webhook is usually up.

#### "csi-attacher CrashLoopBackOff"

driver-deployer ran but CSI plugins are coming up. Check pod count
trend — if `Running` count is growing, you're fine.

#### nodes.longhorn.io with `Ready: False` for a long time

```
NAME            READY   ALLOWSCHEDULING   SCHEDULABLE   AGE
talos-node-05   False   true              True          4m
```

Manager registered the node but instance-manager isn't running yet.
`Ready: True` requires instance-manager (the per-node component that
creates volumes) to be live. instance-manager pulls images, those are
big, takes a couple minutes per node.

### When it actually breaks

#### DiskPressure evicts everything

The single most common cause of "Longhorn doesn't work". Symptoms:

```
$ kubectl get events -n longhorn-system --sort-by=.lastTimestamp | tail -5
Warning   Evicted   pod/instance-manager-xxx   The node had condition: [DiskPressure]
```

Cause: Talos default ephemeral partition is **2.8 GiB**. Container
images (longhorn-manager, longhorn-engine, longhorn-instance-manager,
longhornio/csi-*, etc.) sum to about 3 GiB. Plus volume snapshots stored
on the node's local storage. Total exceeds the partition → kubelet
triggers DiskPressure → evicts pods to recover space → CSI plugins die
→ cluster pretends Longhorn doesn't exist.

The fix is in `infrastructure/talos/longhorn-uservolume.yaml`:

```yaml
apiVersion: v1alpha1
kind: UserVolumeConfig
name: longhorn
provisioning:
  diskSelector:
    match: "!system_disk && disk.size > 50u*GiB"
  minSize: 50GiB
  grow: true
filesystem:
  type: xfs
```

This patch makes Talos format any non-system disk >50 GiB as XFS,
mount it at `/var/mnt/longhorn`, and label it `u-longhorn`. Longhorn's
`defaultDataPath` (set in our chart values) is `/var/mnt/longhorn`, so
all volume data lands on the dedicated disk instead of the root
partition.

**Apply this BEFORE installing Longhorn**, otherwise data is on the
root disk and you have to re-install after fixing storage.

#### Talos extensions missing

Longhorn requires `iscsi-tools` and `util-linux-tools` Talos system
extensions. Without them, manager pods crashloop with:

```
Error starting manager: failed to check environment, please make sure
you have iscsiadm/open-iscsi installed on the host
```

Add via Omni: Cluster → Machine Config Patches → add
`siderolabs/iscsi-tools` and `siderolabs/util-linux-tools` to all
worker nodes. Reboot.

The bootstrap script's Phase 2 verifies extensions are present and
warns if not.

#### "Helm release stuck uninstalling"

A separate failure mode. Covered in §14 because it's a Crossplane
recovery procedure, not Longhorn-specific.

---

<a id="openbao-chain"></a>
## 9. OpenBao: The Bootstrap Chain

OpenBao is HashiCorp Vault's open-source fork — API compatible.
Standalone file-storage on a 10 GiB Longhorn PVC. Bootstrapped by a
one-shot Job that does init/unseal/auth-method/policy setup.

### Boot order

```
1. OpenBao StatefulSet (openbao-0)        ← waits on PVC
2. PVC binds                               ← waits on Longhorn StorageClass
3. openbao-0 starts (sealed, uninitialized)
4. openbao-bootstrap Job                   ← Job's curl loop polls /v1/sys/health
5. Job sees openbao-0 reachable
6. Job: bao operator init (single unseal key)
7. Job: bao operator unseal
8. Job: enable kv v2 secrets engine
9. Job: enable kubernetes auth method
10. Job: write eso-home-read policy
11. Job: create external-secrets role
12. Job complete
```

Total: 5–10 min after Longhorn is ready.

### The eso-home-read policy

After we merged preview's ExternalSecrets into home (which still
reference `secret/data/preview/*` paths, see §10), the ESO read policy
needs **both** path scopes:

```hcl
path "secret/data/home/*" { capabilities = ["read"] }
path "secret/metadata/home/*" { capabilities = ["read", "list"] }
path "secret/data/preview/*" { capabilities = ["read"] }
path "secret/metadata/preview/*" { capabilities = ["read", "list"] }
```

This is encoded in the bootstrap Job script
(`composites/home/jobs.cue`). Without `preview/*`, all the merged
ExternalSecrets fail with "permission denied".

### The openbao-keys Secret

The Job creates this secret in the `openbao` namespace with two fields:

| Field | What |
|---|---|
| `unseal-key` | Single Shamir share to unseal OpenBao after restart |
| `root-token` | Full admin access |

**Back this up immediately**:

```bash
kubectl get secret openbao-keys -n openbao -o yaml > openbao-keys-backup.yaml
# Encrypt + store offline. Lose this and every secret in OpenBao is gone.
```

If openbao-0 ever restarts (pod evicted, node reboot, helm upgrade),
the Job re-runs. It's idempotent — it sees the Secret already exists,
reads the unseal-key, unseals OpenBao, exits. No data loss.

### Seeding secrets

Use the bundled reseed script:

```bash
kubectl port-forward -n openbao svc/openbao 8200:8200 &
export BAO_ADDR=http://localhost:8200
export BAO_TOKEN=$(kubectl get secret openbao-keys -n openbao \
  -o jsonpath='{.data.root-token}' | base64 -d)
cd ~/k8-infra-openbao-backup-20260416-125740
./reseed.sh
```

The script reads every `preview_*.json` file in the directory, converts
filename to OpenBao path (e.g. `preview_github-pat.json` →
`secret/preview/github-pat`), and seeds every key as a separate field.

Then re-seed `secret/home/unifi` separately because the UniFi key in
the backup is stale (see §10):

```bash
bao kv put secret/home/unifi \
  host='https://192.168.1.1' \
  api_key='<NEW_UNIFI_ADMIN_KEY>' \
  external='false'
```

### Verifying ESO sync

```bash
kubectl get externalsecrets -A
# look for: STATUS=SecretSynced, READY=True

kubectl get clusterexternalsecrets
# look for: STATUS=Ready

# If anything's stuck SecretSyncedError:
kubectl describe externalsecret <name> -n <ns>
# common: "Secret does not exist" — you forgot to seed that key
# common: "permission denied" — policy doesn't grant access to that path
```

Force an immediate refresh:

```bash
kubectl annotate externalsecret <name> -n <ns> \
  force-sync=$(date +%s) --overwrite
```

ESO refreshes within 5 seconds.

---

<a id="unifi-dns"></a>
## 10. UniFi DNS and the Rotating API Key

`external-dns` doesn't have a native UniFi provider. We use
`kashalls/external-dns-unifi-webhook` v0.8.2 — a sidecar in the same
pod that translates external-dns API calls to UniFi controller API
calls.

### Architecture

```
Ingress / LoadBalancer Service
     ↓ (status.loadBalancer.ingress[].ip)
external-dns controller (sidecar 1)
     ↓ (gRPC over localhost:8888)
external-dns-unifi-webhook (sidecar 2)
     ↓ (HTTPS to https://192.168.1.1/proxy/network/v2/api/site/default/static-dns)
UniFi controller
     ↓
DNS records served to LAN clients
```

The webhook authenticates with an API key generated in UniFi → Settings
→ Admins → (admin user) → Create New API Key. The key gets stored in
OpenBao at `secret/home/unifi`, synced via ESO into a Kubernetes Secret
named `external-dns-unifi-secret`, mounted into the webhook pod via
env vars.

### Why the API key was always wrong

The first time we hit this:

```
{"level":"ERROR", "msg":"error getting records",
 "error":"failed to fetch DNS records: failed to fetch DNS records from
 UniFi: API error during GET to
 https://192.168.1.1/proxy/network/v2/api/site/default/static-dns/
 (status 401):"}
```

Status 401 means UniFi rejected the API key.

Cause: **UniFi controller rotates API keys periodically** (security
feature, no warning). The key in our backup file
`~/k8-infra-openbao-backup-*/preview_unifi.json` was 11 days stale and
no longer valid.

The backup is still useful for `host=...` and `external=...` fields,
but the `api_key` must be regenerated each time you bootstrap.

### Step-by-step UniFi key refresh

1. Open UniFi controller in browser → Settings → Admins
2. Find the admin account used by external-dns (or create a new one
   with Full Management access)
3. Click "Create New API Key" → copy the key immediately (UniFi only
   shows it once)
4. In your terminal:
   ```bash
   bao kv put secret/home/unifi \
     host='https://192.168.1.1' \
     api_key='<paste here>' \
     external='false'
   ```
5. Force ESO refresh:
   ```bash
   kubectl annotate externalsecret -n external-dns external-dns-unifi-secret \
     force-sync=$(date +%s) --overwrite
   ```
6. Within 1 minute, external-dns picks up the new Secret. Verify:
   ```bash
   kubectl -n external-dns logs -l app.kubernetes.io/name=external-dns -c webhook --tail=10
   # should NOT see "401" anymore
   ```
7. Verify a record publishes:
   ```bash
   dig @192.168.1.1 it-tools.example.internal
   # expected: 192.168.1.235 (the Traefik internal LB IP)
   ```

### Why records that already exist stay live

When the api_key goes stale, external-dns can't read or write to UniFi.
But records UniFi already has remain in its DNS server. So
`it-tools.example.internal` keeps resolving even while
`home-assistant.example.internal` (newly added) doesn't get published.

This bit us hard. We thought "DNS works", checked it-tools, all good.
Then noticed the new hostnames didn't resolve. Spent an hour debugging
external-dns config. Eventually saw the 401s in webhook logs.

Now we know: if **some but not all** hostnames resolve via UniFi DNS,
suspect a stale API key first.

---

<a id="sibling-service"></a>
## 11. The Sibling Service Pattern

Omni's workload-proxy lets you click a link in the Omni UI and reach
in-cluster services without VPN/port-forward. It works via annotations
on Service resources:

```yaml
metadata:
  annotations:
    omni-kube-service-exposer.sidero.dev/port:   "50082"  # node port to bind
    omni-kube-service-exposer.sidero.dev/label:  "Longhorn (home)"
    omni-kube-service-exposer.sidero.dev/prefix: "longhornhome"  # subdomain prefix
```

The `omni-kube-service-exposer` DaemonSet runs on every node, watches
Services with these annotations, and binds the configured port on each
node's interface. Omni's edge tunnels traffic from
`https://<prefix>-<account>.workload.<region>.omni.siderolabs.io`
through the SideroLink mesh to the bound port.

### The annotation-clobber problem

We initially annotated chart-managed Services directly:

```bash
kubectl -n longhorn-system annotate svc longhorn-frontend \
  omni-kube-service-exposer.sidero.dev/port=50082 \
  omni-kube-service-exposer.sidero.dev/label='Longhorn' \
  omni-kube-service-exposer.sidero.dev/prefix=longhorn
```

This works **until the next helm upgrade**. Helm sees the Service has
fields it didn't set (our annotations) and one of two things happens:
- helm 3 with --reset-values: clobbers annotations on upgrade
- helm 3 default: preserves them (sometimes — depends on field-manager
  conflict resolution)

In practice we saw clobbering during chart upgrades and also during
helm rollbacks (e.g. when a Crossplane Release CR got recreated).
Result: we'd ship a fix, helm would upgrade overnight, annotations
gone, Omni proxy URL 404s.

### The fix: a sibling Service

Create a separate ClusterIP Service that we own outright. Same selector
as the chart's. Helm doesn't touch it because it has no `meta.helm.sh/`
labels.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: longhorn-frontend-omni    # different from chart's longhorn-frontend
  namespace: longhorn-system
  annotations:
    omni-kube-service-exposer.sidero.dev/port:   "50082"
    omni-kube-service-exposer.sidero.dev/label:  "Longhorn (home)"
    omni-kube-service-exposer.sidero.dev/prefix: "longhornhome"
spec:
  type: ClusterIP
  selector:
    app: longhorn-ui   # same as chart's longhorn-frontend selector
  ports:
    - {name: http, port: 80, targetPort: 8000, protocol: TCP}
```

The sibling Service routes to the same pods but is owned by Crossplane
(via `XExposedService` XRD), so helm has no claim on it.

### The `XExposedService` XRD

```cue
exposedServices: [
    {
        name:       "longhorn-frontend-omni"
        namespace:  "longhorn-system"
        selector: {app: "longhorn-ui"}
        port:       80
        targetPort: 8000
        omniPort:   50082
        omniLabel:  "Longhorn (home)"
        omniPrefix: "longhornhome"
        tier:       C.tier
        cluster:    C.name
        owner:      "platform-team"
    },
]
```

Renders as an XR which Crossplane translates to a provider-kubernetes
Object → real Service.

### Composition gotcha: float64 in patch fmt

Crossplane's patch-and-transform unmarshals JSON numbers as `float64`,
even integers like the port number. Our first composition used:

```cue
combine: {
    variables: [{fromFieldPath: "spec.omniPort"}]
    strategy: "string"
    string: fmt: "%d"   // <-- WRONG for float64
}
```

Result: the port annotation came out as `%!d(float64=50082)` (Go's
"format specifier mismatch" sentinel string).

Fix: use `%v` (universal format verb, prints float64 as int when
integer-valued):

```cue
string: fmt: "%v"
```

### The dash-in-prefix rule

Omni's prefix annotation must match `^[a-z][a-z0-9]*$`. We tried:

```yaml
omni-kube-service-exposer.sidero.dev/prefix: "longhorn-home"   # WRONG
```

Result: machine reported `apidavailable: false`, services didn't show
up in Omni's `omnictl get exposedservices`. No clear error in logs;
exposer silently ignored the annotation.

Fix:

```yaml
omni-kube-service-exposer.sidero.dev/prefix: "longhornhome"   # OK
```

We use `traefikhome`, `longhornhome`, `openbaohome` — single-word
disambiguator suffixes.

---

<a id="multi-zone-traefik"></a>
## 12. Multi-Zone Traefik and DNS Targeting

Home cluster is multi-tenant in the network sense: it serves traffic
both to the DMZ (vlan50, `192.168.2.0/24`) and to the internal LAN
(vlan10, `192.168.1.0/24`). Traefik is configured with two
LoadBalancer Services, one per zone:

| Service | Pool | LB IP | Selector |
|---|---|---|---|
| `traefik` (chart-default) | `lan-dmz` | `192.168.2.240` | traefik pods |
| `traefik-internal` (extraObjects) | `lan-internal` | `192.168.1.235` | traefik pods |

Both Services route to the same Traefik pods. MetalLB allocates a
distinct IP per Service from the matching pool.

### MetalLB pool config

```cue
metallbPools: [
    {
        name:       "lan-dmz"
        addresses:  ["192.168.2.240-192.168.2.250"]
        autoAssign: false  // opt-in via service annotation only
        ...
    },
    {
        name:       "lan-internal"
        addresses:  ["192.168.1.235-192.168.1.239"]
        autoAssign: false
        ...
    },
]
```

`autoAssign: false` means a Service must explicitly request a pool
via `metallb.universe.tf/address-pool: <pool-name>` annotation. This
prevents random workload Services from grabbing DMZ IPs by accident.

### Traefik Service annotations

In the chart values:

```yaml
service:
  type: LoadBalancer
  annotations:
    metallb.universe.tf/address-pool: "lan-dmz"
    metallb.universe.tf/loadBalancerIPs: "192.168.2.240"

extraObjects:
  - apiVersion: v1
    kind: Service
    metadata:
      name: traefik-internal
      namespace: traefik
      annotations:
        metallb.universe.tf/address-pool: "lan-internal"
        metallb.universe.tf/loadBalancerIPs: "192.168.1.235"
    spec:
      type: LoadBalancer
      selector:
        app.kubernetes.io/instance: traefik-traefik
        app.kubernetes.io/name: traefik
      ports:
        - {name: web, port: 80, targetPort: web, protocol: TCP}
        - {name: websecure, port: 443, targetPort: websecure, protocol: TCP}
```

`metallb.universe.tf/loadBalancerIPs` pins the specific IP within the
pool — useful when DNS is hard-coded.

### The external-dns "wrong IP" trap

Ingress objects have `status.loadBalancer.ingress[]` populated by the
ingress controller (Traefik). When external-dns reads an Ingress, it
takes the **first** entry of that array as the DNS target.

Traefik populates the array in chart-Service order. The chart's primary
Service (DMZ at `.50.240`) is always first, so external-dns publishes:

```
it-tools.example.internal → 192.168.2.240
```

But internal LAN clients can't reach `.50.240` (different VLAN, blocked
by UniFi firewall). They timeout.

### The fix: target annotation

```yaml
metadata:
  annotations:
    external-dns.alpha.kubernetes.io/target: "192.168.1.235"
```

Forces external-dns to publish that IP regardless of `status.loadBalancer`.

### Expressing in CUE

We extended the `XIngress` XRD with optional `annotations` field:

```cue
ingresses: [
    {
        name:             "it-tools"
        namespace:        "it-tools"
        host:             "it-tools.example.internal"
        serviceName:      "it-tools-backend"
        servicePort:      80
        ingressClassName: "traefik"
        annotations: {
            "external-dns.alpha.kubernetes.io/target": "192.168.1.235"
        }
        ...
    },
]
```

The composition merges via `MergeObjects` so it doesn't clobber any
chart-set annotations.

### Verifying external-dns target works

```bash
# 1. Check Ingress has the annotation
kubectl get ingress -n it-tools it-tools -o jsonpath='{.metadata.annotations}'

# 2. Check external-dns webhook records (port-forward to webhook port)
POD=$(kubectl -n external-dns get pods \
  -l app.kubernetes.io/name=external-dns -o jsonpath='{.items[0].metadata.name}')
kubectl -n external-dns port-forward $POD 8888:8888 &
curl -sH 'Accept: application/external.dns.webhook+json;version=1' \
  http://localhost:8888/records | jq

# Look for: targets: ["192.168.1.235"] for it-tools.example.internal

# 3. Confirm UniFi has the right A record
dig @192.168.1.1 it-tools.example.internal
# expected: 192.168.1.235
```

---

<a id="https-backends"></a>
## 13. HTTPS Backends: Home Assistant Self-Signed

Home Assistant serves on port 30103 over HTTPS with a self-signed cert.
Traefik talks HTTP to backends by default. Routing
`https://home-assistant.example.internal/` returns 502 with no useful
backend logs because Traefik gets connection-reset trying to speak HTTP
to a TLS endpoint.

### Two-part fix

**Part 1**: tell Traefik the backend is HTTPS:

```yaml
# On the Service object
metadata:
  annotations:
    traefik.ingress.kubernetes.io/service.serversscheme: https
```

**Part 2**: tell Traefik to skip cert verification (because HA's cert
is self-signed):

```yaml
# Define a ServersTransport CRD
apiVersion: traefik.io/v1alpha1
kind: ServersTransport
metadata:
  name: insecure-skip-verify
  namespace: home-assistant
spec:
  insecureSkipVerify: true
```

```yaml
# On the Service object, point at the ServersTransport
metadata:
  annotations:
    traefik.ingress.kubernetes.io/service.serversscheme: https
    traefik.ingress.kubernetes.io/service.serverstransport: insecure-skip-verify@kubernetescrd
```

### The `@kubernetescrd` suffix gotcha

The annotation `traefik.ingress.kubernetes.io/service.serverstransport`
takes a Traefik provider-qualified name. ServersTransport defined as
a CRD must use `@kubernetescrd`. Without that suffix, Traefik searches
its file provider (which has nothing) and silently 404s the route.

If you see `404 Not Found` from Traefik with no backend logs, this is
usually why.

### Expressing in CUE: XServersTransport + XExternalBackend

```cue
// composites/home/serverstransports.cue
serversTransports: [
    {
        name:               "insecure-skip-verify"
        namespace:          "home-assistant"
        insecureSkipVerify: true
        ...
    },
]

// composites/home/externalbackends.cue
externalBackends: [
    {
        name:       "home-assistant-backend"
        namespace:  "home-assistant"
        port:       443
        targetPort: 30103
        protocol:   "TCP"
        portName:   "https"
        addresses:  ["192.168.1.148"]
        annotations: {
            "traefik.ingress.kubernetes.io/service.serversscheme":   "https"
            "traefik.ingress.kubernetes.io/service.serverstransport": "home-assistant-insecure-skip-verify@kubernetescrd"
        }
        ...
    },
]
```

`XExternalBackend` renders both a Service (with these annotations) and
an EndpointSlice pointing at the external IP+port. We use it for every
backend that lives outside the cluster (NodePorts on other VMs, NAS
apps, etc.).

---

<a id="crossplane-recovery"></a>
## 14. Crossplane Recovery Playbook

When Crossplane gets confused about external state, manual recovery is
required. Four common stuck states:

### State 1: Object stuck "external-create-pending"

Symptom:

```
$ kubectl describe object.kubernetes.crossplane.io it-tools-XXXXXX
...
Status:
  Conditions:
    Reason:   ReconcileError
    Status:   False
    Message:  cannot determine creation result - remove the
              crossplane.io/external-create-pending annotation if it
              is safe to proceed
```

Cause: provider-kubernetes attempted to `Create` the underlying resource
and apiserver returned a transient error (etcd timeout, proxy error)
before Crossplane could confirm whether the resource was created.
Crossplane freezes the Object to avoid double-creates.

Fix:

```bash
kubectl annotate object.kubernetes.crossplane.io <name> \
  crossplane.io/external-create-pending- --overwrite
```

The trailing dash removes the annotation. Crossplane re-attempts
creation on next reconcile. If the resource was actually created in the
first attempt, provider-kubernetes adopts it (matches by name).

We hit this every time apiserver flapped during a bulk apply. The
bootstrap script's `kubectl_apply_with_retry` reduces the rate of this,
but doesn't eliminate it.

### State 2: Helm release stuck "uninstalling"

Symptom:

```
$ kubectl get release.helm.crossplane.io
NAME       STATE          REVISION   DESCRIPTION
longhorn   uninstalling   1          Deletion in progress (or silently failed)
```

The release stays in this state forever. Crossplane retries
`helm uninstall` but helm refuses because the release Secret is in a
terminal state (`pending-uninstall` or `failed`).

This happens when:
- `helm install` failed during pre-install hooks (often because etcd
  was overloaded and the hook Job timed out)
- a `helm rollback` was attempted while another operation was in flight
- the operator deleted the namespace/PVC manually mid-reconcile

Fix (full sequence):

```bash
# 1. Clear Crossplane's finalizer so the Release CR can actually delete
kubectl patch release.helm.crossplane.io <name> --type=merge \
  -p '{"metadata":{"finalizers":[]}}'

# 2. Delete the underlying helm release Secret (the state-holder)
kubectl -n <namespace> delete secret sh.helm.release.v1.<name>.v1

# 3. Delete the Crossplane Release CR
kubectl delete release.helm.crossplane.io <name>

# 4. Crossplane sees the XHelmRelease still wants this resource
#    and recreates a fresh Release CR, which provider-helm installs cleanly
kubectl annotate xhelmrelease.infra.k8 <name> \
  reconcile.crossplane.io/timestamp=$(date +%s) --overwrite
```

### State 3: Composition revision pinning

Symptom: you update a Composition (e.g. add a new patch), `make
export-cluster` produces the new YAML, `kubectl apply` succeeds, but
existing XRs don't pick up the change.

Cause: Crossplane creates a new `CompositionRevision` for each unique
content hash of a Composition. XRs reference a specific revision via
`spec.crossplane.compositionRevisionRef`. With `compositionUpdatePolicy:
Automatic` (default), they should pick up the latest. With `Manual`,
you have to update them by hand.

Verify:

```bash
kubectl get compositionrevisions -l crossplane.io/composition-name=<name>
# expect: multiple revisions with different ages

kubectl get xnamespace.infra.k8 <name> -o yaml | grep compositionRevisionRef
# should reference the latest revision name
```

If pinned to old revision: re-annotate to trigger reconcile:

```bash
kubectl annotate xnamespace.infra.k8 <name> \
  reconcile.crossplane.io/timestamp=$(date +%s) --overwrite
```

### State 4: Provider stuck Unhealthy after upgrade

Less common but bites on first install if etcd flakes during package
download. Provider's controller goes `Unhealthy` and never recovers.

Fix:

```bash
# Look at the ProviderRevision (each version is a revision)
kubectl get providerrevisions

# If the latest is Inactive while an older is Active, the package install
# bombed. Delete the failed revision:
kubectl delete providerrevision <failed-revision-name>

# Crossplane reinstalls automatically.
```

---

<a id="bootstrap-script"></a>
## 15. The Bootstrap Script: 30 Minutes vs. 4 Hours

`ci/scripts/bootstrap-home.sh` is the single most important operational
asset for this cluster. Without it, every reset took us 3–4 hours of
manual `kubectl apply` + debugging. With it, a clean reset is ~30
minutes of mostly-automated time.

### Anatomy

810 lines of bash. Key building blocks:

#### `log()` / `ok()` / `warn()` / `die()`

Colored output for phase boundaries. Useful when output is captured
to a file — easy to grep for `==>` (phase markers) and `✗` (fatal).

#### `detect_talos_omni()`

Probes whether the current kubectl context is a Talos cluster managed
by Omni. Caches result in `IS_TALOS_OMNI`. Drives behavior in Phase
1.5: on Talos+Omni we apply ConfigPatches for permanent tuning; on
non-Talos we fall back to `BOOTSTRAP_PACE=slow` (wait for /healthz
between phases).

#### `wait_apiserver_calm()`

Polls `kubectl get --raw='/healthz'` every 5s until it returns
`"ok"` or hits the timeout (default 5min). Used as a gate between
heavy installs.

The function returns 0 on success, 1 on timeout. **Caller should
warn-and-continue, not die**. Transient etcd flakes resolve on their
own and the next phase will retry.

#### `kubectl_apply_with_retry()`

Wraps `kubectl apply` with retry-on-known-transient-errors. The
errors it retries:
- `etcdserver: request timed out`
- `proxy error`
- `TLS handshake timeout`
- `connection reset by peer`
- `no endpoints available`

Uses exponential backoff (10s, 20s, 40s, ...) up to 5 attempts.
Real validation/RBAC errors fail fast.

#### `apply_omni_configpatch()`

Wraps a Talos config-patch YAML in the Omni `ConfigPatches` resource
schema and applies via `omnictl apply -f`. Handles:
- ID generation: `<prefix>-<omni-cluster>` (e.g. `400-etcd-tuning-talos-home`)
- Cluster label: `omni.sidero.dev/cluster: <omni-cluster>`
- Optional extra label (for CP-only scoping)
- Idempotency: re-applying same content is a no-op in Omni

#### `pace()`

Calls `wait_apiserver_calm` if `BOOTSTRAP_PACE=slow`. No-op otherwise.
Inserted between heavy installs (Crossplane, helm releases) so the
script doesn't burst manifests faster than etcd can absorb them.

#### `phase_pause()`

If `--pause` (default), prints "PHASE PAUSED — press ENTER" and waits
for stdin. Lets the operator manually validate state before triggering
the next reconcile burst.

### The flag matrix

| Flag | Default | Purpose |
|---|---|---|
| `--check-only` | off | Run preflight + state checks only. No installs. |
| `--skip-render` | off | Skip `make validate && make export-cluster`. Use when iterating on the script itself. |
| `--no-pause` | (paused on) | Don't wait between phases. CI / unattended runs. |
| `--pause` | on | Default. Wait between phases for ENTER. |

### Environment overrides

| Variable | Default | Purpose |
|---|---|---|
| `SKIP_TALOS_CHECK` | 0 | Bypass Talos disk + extension check |
| `SKIP_APISERVER_TUNING` | 0 | Bypass auto-applied ConfigPatch (only if you tuned out-of-band) |
| `BOOTSTRAP_PACE` | (auto) | `slow` to force /healthz waits between heavy installs |
| `OMNI_CLUSTER` | `talos-${CLUSTER}` | Override Omni cluster name |
| `INSTALL_HARBOR` | auto | `0`/`1` to force install/skip provider-harbor |
| `INSTALL_EXTRA_RES` | auto | `0`/`1` for function-extra-resources |
| `INSTALL_CNPG` | auto | `0`/`1` for CloudNativePG |
| `LONGHORN_CHART_VERSION` | 1.7.2 | Override longhorn chart version |
| `CROSSPLANE_CHART_VERSION` | 2.2.0-up.4 | Override crossplane chart version |
| `HELMRELEASE_WAIT_TIMEOUT` | 900 | Phase 8 wait timeout (seconds) |
| `APISERVER_CALM_TIMEOUT` | 300 | Per-call wait_apiserver_calm timeout |

### When to run paused vs unattended

**Paused (default)**:
- First-ever bootstrap on a fresh cluster
- After major workload changes (added kelos, merged preview, etc.)
- When debugging a specific phase

**Unattended (`--no-pause`)**:
- Re-runs of an already-working bootstrap
- CI pipelines that are setup to capture and respond to failures
- Watching from a monitoring tool that auto-clicks "next" between
  phases (don't actually do this)

### Idempotency contract

Every phase is idempotent — re-running the script on a working cluster
should be a no-op for installed components. Phase logic:

- Phase 1.5: ConfigPatch apply is idempotent (Omni sees same content,
  no-ops)
- Phase 3 Longhorn: `helm status longhorn -n longhorn-system` succeeds
  → skip helm upgrade, just verify StorageClass
- Phase 5 Crossplane: same — `helm status crossplane` skips if installed
- Phase 7 apply: `kubectl apply` is naturally idempotent

You can always re-run after a partial failure. Most state recovers
without operator intervention.

---

<a id="gotchas"></a>
## 16. Common Gotchas Cheat Sheet

| Symptom | Cause | Fix |
|---|---|---|
| `etcdserver: leader changed` repeating in apiserver logs | HDD fsync too slow for 3-CP etcd peers | Drop to single-CP + apply etcd-tuning patch |
| `controllermanager.go: leaderelection lost` | Default 10s renew deadline too tight for slow etcd | Patch sets 40s deadline |
| Worker `configuptodate: false` w/ "etcd config is only allowed on CP" | ConfigPatch has `cluster.etcd:` but isn't CP-scoped | Add label `omni.sidero.dev/machine-set: <cluster>-control-planes` |
| Longhorn manager DS desired=N, current=0 | Namespace under baseline PSS rejects privileged | Label namespace `pod-security.kubernetes.io/enforce=privileged` |
| MetalLB speaker DS desired=N, current=0 | Same PSS issue | Same fix on `metallb-system` |
| LoadBalancer Service stays `<pending>` | MetalLB pool `autoAssign: false` and Service has no annotation | Add `metallb.universe.tf/address-pool: <name>` annotation |
| Hostname resolves but TCP timeout | MetalLB allocated IP but speaker can't ARP-announce (no NIC on that VLAN) | Add VLAN interface to node OR drop the unused pool |
| Hostname resolves to wrong IP (DMZ instead of internal) | external-dns picked first ingress.status.loadBalancer.ingress | Add `external-dns.alpha.kubernetes.io/target=<correct IP>` annotation |
| external-dns webhook 401 on every call | UniFi API key rotated/revoked | Regen key in UniFi Settings → Admins, re-seed `secret/home/unifi` |
| Traefik 502 on HTTPS backend | Talking HTTP to TLS endpoint | Set `service.serversscheme: https` annotation + ServersTransport with `insecureSkipVerify` |
| Traefik 404 on HTTPS backend with no backend logs | ServersTransport reference missing `@kubernetescrd` suffix | Append `@kubernetescrd` to the annotation value |
| `kubectl apply` returns "proxy error" / "TLS handshake timeout" | Apiserver overloaded mid-roll | Wait, retry. `kubectl_apply_with_retry` handles this in script |
| openbao-0 pod stays Pending | Longhorn StorageClass not yet ready | Wait for `kubectl get sc longhorn` to exist; PVC binds shortly after |
| `apidavailable: false` on workers in Omni | Normal — Talos doesn't expose apid endpoint on workers by default | Ignore; workers show `READY: true` in Omni once kubelet is up |
| Object stuck "external-create-pending" | Apiserver flaked mid-create, Crossplane froze | `kubectl annotate <object> crossplane.io/external-create-pending- --overwrite` |
| Helm release stuck "uninstalling" | Helm hook timeout left release in pending-uninstall state | Clear finalizers, delete `sh.helm.release.v1.<name>.v1` Secret, delete Release CR, force XR reconcile |
| Crossplane patch fmt prints `%!d(float64=N)` | `%d` doesn't accept float64 | Use `%v` instead of `%d` |
| Omni proxy URL 404 at `/` | Service annotated correctly but app serves UI at `/dashboard/` etc. | Add Traefik IngressRoute redirect `/` → `/dashboard/` (see Traefik dashboard root redirect example) |
| Some hostnames resolve, others don't, all via UniFi | Stale UniFi API key blocks new record creation | Regen key + re-seed `secret/home/unifi` |
| Provider package stuck Unhealthy | Failed install left old ProviderRevision Active | Delete the failed ProviderRevision; Crossplane reinstalls |

---

<a id="maintenance"></a>
## 17. Maintenance and Backup

### Backup OpenBao keys

The single most important backup. Lose this and every secret in
OpenBao is unrecoverable.

```bash
kubectl get secret openbao-keys -n openbao -o yaml > openbao-keys-backup-$(date +%F).yaml
gpg --symmetric openbao-keys-backup-$(date +%F).yaml
# Store the .gpg file in 1Password / safe / offsite.
```

Re-do this whenever OpenBao is reinitialized (cluster wipe, PVC loss,
upgrade that resets the seal).

### Backup OpenBao data

```bash
# Inside the openbao pod:
kubectl exec -n openbao openbao-0 -- /bin/sh -c '
  bao operator raft snapshot save /tmp/snapshot.snap
'
kubectl cp openbao/openbao-0:/tmp/snapshot.snap ./openbao-snapshot-$(date +%F).snap
```

For file storage (what we use), there's no raft. Just `kubectl cp` the
`/openbao/data` directory:

```bash
kubectl exec -n openbao openbao-0 -- tar czf /tmp/data.tar.gz -C / openbao/data
kubectl cp openbao/openbao-0:/tmp/data.tar.gz ./openbao-data-$(date +%F).tar.gz
```

Schedule weekly via a Kubernetes CronJob (we don't have this yet —
TODO).

### Add a new household service to Traefik

1. Run the service somewhere reachable from the worker nodes (NAS app,
   NodePort on another VM, container on another machine).
2. Add a `XExternalBackend` entry in `composites/home/externalbackends.cue`:
   ```cue
   {
       name:       "foo-backend"
       namespace:  "foo"
       port:       80
       targetPort: 8080         # the actual backend port
       addresses:  ["192.168.1.X"]
       tier:    C.tier
       cluster: C.name
       owner:   "platform-team"
   },
   ```
3. Add the namespace to `composites/home/namespaces.cue`.
4. Add a `XIngress` to `composites/home/ingresses.cue`:
   ```cue
   {
       name:             "foo"
       namespace:        "foo"
       host:             "foo.example.internal"
       serviceName:      "foo-backend"
       servicePort:      80
       ingressClassName: "traefik"
       annotations:      _internalTarget   // 192.168.1.235
       ...
   },
   ```
5. `make export-cluster CLUSTER=home && kubectl apply -f clusters/home/`
6. external-dns publishes the UniFi DNS record within ~1 min.
7. Test: `curl http://foo.example.internal`

For HTTPS backends (self-signed cert), copy the `home-assistant`
pattern: define an `XServersTransport` with `insecureSkipVerify: true`
and reference it via the backend's annotations.

### Recover from a full cluster wipe

The home cluster has been recreated several times. Recovery flow:

```bash
# 1. Refresh kubeconfig + talosconfig
omnictl kubeconfig --cluster=talos-home --merge=false --force /tmp/home-kubeconfig
omnictl talosconfig --cluster=talos-home --force /tmp/home-talosconfig

# 2. Run paused bootstrap
ci/scripts/bootstrap-home.sh
# (walk through 9 phases, validating each)

# 3. After Phase 9 completes, seed OpenBao
kubectl port-forward -n openbao svc/openbao 8200:8200 &
export BAO_ADDR=http://localhost:8200
export BAO_TOKEN=$(kubectl get secret openbao-keys -n openbao \
  -o jsonpath='{.data.root-token}' | base64 -d)
cd ~/k8-infra-openbao-backup-20260416-125740
./reseed.sh

# 4. Re-seed home/unifi with FRESH key (regen in UniFi controller first)
bao kv put secret/home/unifi \
  host='https://192.168.1.1' \
  api_key='<NEW>' \
  external='false'

# 5. Force ESO sync (optional — happens within 1 min anyway)
kubectl rollout restart deployment -n external-secrets external-secrets

# 6. Watch ExternalSecrets converge
watch kubectl get externalsecrets -A
# all should reach STATUS=SecretSynced, READY=True
```

Longhorn volumes themselves don't survive a Talos wipe (they're on the
worker data disks which are zeroed during reinstall). For data
preservation:

```bash
# BEFORE the wipe:
kubectl get pvc -A
# For each PVC you care about:
kubectl create -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Backup
metadata:
  name: <name>-$(date +%F)
  namespace: longhorn-system
spec:
  snapshotName: <existing-snapshot>
  backupTargetName: default
EOF
```

(Requires backup target configured in Longhorn — out of scope here.)

### Routine health checks

```bash
# Apiserver healthz
kubectl get --raw=/healthz

# etcd specifically
kubectl get --raw=/readyz/etcd

# Control plane pod restart counts (should be 0 in steady state)
kubectl -n kube-system get pods | grep -E 'apiserver|controller|scheduler'

# Crossplane resources health
kubectl get xhelmrelease.infra.k8
# all should be SYNCED=True, READY=True

# ESO sync state
kubectl get externalsecrets -A
# all should be SecretSynced, READY=True

# Longhorn nodes
kubectl get nodes.longhorn.io -n longhorn-system
# all should be Ready=True, Schedulable=True

# UniFi DNS (sanity check from your dev machine)
dig @192.168.1.1 it-tools.example.internal
```

A weekly cron + alerting on these would be valuable. We don't have
that yet (TODO: add prometheus + alertmanager).

---

<a id="lessons"></a>
## 18. Lessons in One Line Each

1. **HDD-backed etcd cannot run a multi-CP cluster** with a Crossplane workload — single CP is the only sane choice on slow disk.

2. **`etcd-tuning.yaml` must be CP-scoped** via `omni.sidero.dev/machine-set: <cluster>-control-planes` label, not `role-controlplane`.

3. **Apiserver memory scales linearly with installed CRDs** — usage-driven XRD filtering (only render XRDs whose composite list is non-empty) is worth the CUE complexity.

4. **PSS labels on `longhorn-system` and `metallb-system` are mandatory** — without them, DaemonSets are silently rejected and you'll think networking is broken.

5. **Annotating chart-owned Services for Omni proxy is fragile** — use a sibling Service via `XExposedService` so helm upgrades don't clobber.

6. **Omni proxy prefix annotations cannot contain dashes** — must match `^[a-z][a-z0-9]*$`.

7. **Longhorn's first boot takes 10–15 min on slow disk** — patience over poking. Don't kubectl-delete pods during the manager+webhook race; let them restart on their own.

8. **external-dns picks the first ingress LB IP** — pin with `external-dns.alpha.kubernetes.io/target` annotation when a Service is multi-zone.

9. **UniFi API keys rotate silently** — `external-dns 401` errors with some-but-not-all DNS records resolving means re-seed `secret/home/unifi`.

10. **`etcdserver: request timed out` from `kubectl apply` is transient and retryable** — not a structural failure. The bootstrap script's `kubectl_apply_with_retry` handles this.

11. **The bootstrap script's paused mode is the difference between a 30-minute install and a four-hour debugging session** — default it on for first-time bootstrap, opt out only after you trust the state.

12. **Crossplane's `external-create-pending` annotation is recoverable** — `kubectl annotate <obj> crossplane.io/external-create-pending- --overwrite` clears it.

13. **Helm releases stuck "uninstalling" need full surgery** — clear Crossplane finalizer, delete `sh.helm.release.v1.<name>.v1` Secret, delete Release CR, force XR reconcile.

14. **Pod Security Standards in `restricted` mode block almost all infra components** — accept that namespace-level `privileged` labels are part of the platform contract.

15. **Talos extensions (iscsi-tools, util-linux-tools) are required for Longhorn** — verify in Phase 2 of bootstrap, don't hope they're set.

16. **`%v` not `%d` in Crossplane patch-and-transform** for integer fields — JSON unmarshalling makes them `float64`.

17. **The `eso-home-read` policy must grant `secret/data/preview/*`** if you've merged preview's ExternalSecrets into home (which still reference `preview/` paths).

18. **Talos config patches roll one CP at a time** with quorum preservation — even on single-CP this means brief unavailability during the apply window. Plan for 5 minutes of apiserver downtime per patch.

19. **`kube-api-qps: 25` (default 100) on CM and scheduler** is critical on HDD — controllers' background reconcile traffic alone can overwhelm slow etcd.

20. **`leader-elect-renew-deadline: 40s` (default 10s)** prevents CM/scheduler crashloops during etcd compaction spikes.

---

This document is the post-mortem of 4 days of bootstrap-and-burn cycles
on a slow-disk home cluster. Most of these problems would not exist
on SSD. All of them are documented here so the next person on similar
hardware (or future-you) can skip the four-hour debugging sessions and
go straight to the working state.
