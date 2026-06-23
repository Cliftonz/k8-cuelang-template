# Cilium + Multus migration — field notes (talos-home, 2026-05-06)

> **2026-05-23 update.** Multus has since been removed from this repo — see
> "Skip Multus unless you actually need secondary networks today" at the
> bottom of this doc, which is now the standing policy. References to
> Multus below are preserved as historical record of what was tried.

Companion to [cilium-cni.md](cilium-cni.md). That document describes the
*intended* install path. This one captures what actually happened the
first time it ran end-to-end on a live home cluster with workloads —
the surprises, the post-mortem, and the changes that went back into the
install assets so the next migration doesn't hit the same potholes.

## Cluster shape at migration

- 4 Talos VMs on TrueNAS (1 control-plane, 3 worker)
- Kubernetes v1.36.0, Talos v1.13.0
- Pre-migration CNI: Flannel (Talos default) + kube-proxy
- ~80 pods across 25 namespaces, including OpenBao, Longhorn, Argo CD,
  Crossplane, External Secrets, cert-manager, Velero, kelos, Traefik,
  MetalLB. ~10 NetworkPolicy resources in active namespaces (rendered
  from CUE; never functionally enforced under Flannel).

## Resource overhead

Measured 30 min after cutover with `kubectl top` summed across the 4 nodes.

| Stack                    | Pods | CPU            | Memory     |
|--------------------------|------|----------------|------------|
| `cilium` agent (DS)      | 4    | ~132m total    | ~676 MiB   |
| `cilium-envoy` (DS)      | 4    | ~12m total     | ~132 MiB   |
| `cilium-operator`        | 1    | ~2m            | ~76 MiB    |
| `kube-multus-ds` (DS)    | 4    | ~4m total      | ~39 MiB    |
| **Added**                | 13   | **~150m**      | **~923 MiB** |
| **Removed** (flannel+kp) | 8    | ~50–80m        | ~250–300 MiB |
| **Net delta**            | +5   | **+70–100m**   | **+625–700 MiB** |

Per-node that's roughly **+20m CPU and +165 MiB RAM** — comfortably within
the budgets configured in `infrastructure/cilium/values.yaml` (cilium
agent: 100m req / 1 CPU limit, 256 MiB req / 512 MiB limit). Hubble UI
and Relay are off; flipping them on adds another deployment + service
roughly equivalent in size to one Cilium operator.

For context, idle node utilisation on talos-home stayed in the 2–5% CPU
and 23–33% memory range before and after. The CNI swap is not what makes
the cluster busy.

## What actually went wrong

### 1. The "rolling reboot" never happened

The original migration plan assumed applying the Talos `cilium-cni-patch`
ConfigPatch (cluster.network.cni.name=none + cluster.proxy.disabled=true)
would trigger Talos to roll-reboot every node, leaving them NotReady
until Cilium was installed. **That's not what Talos does.** It applies
the change at runtime: Flannel + kube-proxy DaemonSets keep running with
existing pods unaffected, the CNI=none flag just stops Talos from
re-installing them on the next reboot.

So the real cutover sequence is:

1. Apply ConfigPatch (no node reboot, nothing breaks immediately).
2. `helm install cilium` *alongside* the still-running Flannel +
   kube-proxy DaemonSets. Cilium-issued IPs and Flannel-issued IPs
   coexist in the same `10.244.0.0/16` pod CIDR (Cilium's
   `ipam.mode: kubernetes` reuses the K8s-allocated podCIDR per node).
3. Verify Cilium is healthy and a fresh test pod can reach Service
   VIPs through socket-LB.
4. **Now** delete `kube-flannel` and `kube-proxy` DaemonSets — that's
   the irreversible point.
5. `kubectl rollout restart` every workload namespace to flip
   pods onto Cilium-issued IPs and re-attach Cilium's socket-LB
   eBPF hooks at cgroup creation.

The migration script ([ci/scripts/migrate-cni-cilium.sh](../ci/scripts/migrate-cni-cilium.sh))
codifies this order. The fresh-cluster install path
([ci/scripts/bootstrap-home.sh](../ci/scripts/bootstrap-home.sh)
phase 2.5) only runs the install half — it refuses to touch a cluster
that still has Flannel and points the operator at the migration script
instead.

### 1.5. Host network → cross-node pod silently broke

Even after the apiserver-egress CCNP was in place, every Longhorn volume
operation kept timing out on the admission webhook
(`failed calling webhook "mutator.longhorn.io" ... 10s timeout`). The
trail led somewhere unexpected: **the kube-apiserver, running in the
host network namespace on the control-plane node, could not reach pods
on worker nodes at all.** Same-node pings worked (cilium_host loopback);
cross-node host-net→pod traffic dropped silently.

Three independent causes piled up. All three need fixing:

1. **`bpf.masquerade: false`** in the original Cilium values forced
   Cilium into `Host: Legacy` routing mode (kernel-routing-tables
   forwarding). Legacy mode relies on iptables NAT rules that kube-proxy
   used to maintain — gone after the cutover. Setting `masquerade: true`
   flips Cilium to `Host: BPF`, which routes host-net traffic through
   the same eBPF datapath as pod-net.

2. **The leftover `flannel.1` VXLAN device** stayed UP on every node
   after Flannel was uninstalled. Two problems with that:
   - It bound to UDP/8472 — *the same port Cilium's tunnel uses*. Two
     processes can listen but only one wins delivery; flannel.1's stale
     socket can intercept incoming VXLAN packets and black-hole them.
   - Cilium auto-detects it as a routable device (`Masquerading: BPF
     [eth0, siderolink, flannel.1]`) and adds it to the BPF data path
     for masquerading + policy. Pinning Cilium to `devices: eth0` (in
     values.yaml) excludes it from the BPF path, but doesn't delete the
     leftover kernel device.

   Migration script Phase 6.5 now deletes `flannel.1` on every node via
   a privileged host-network helper Pod with `NET_ADMIN`.

3. **NetworkPolicy ingress rules don't match the `host` /
   `remote-node` / `kube-apiserver` reserved identities by default.**
   The apiserver, when it makes an outbound connection from the
   control-plane node's host network, is classified by Cilium as
   `reserved:host` (or `reserved:remote-node` if hitting a different
   node). Standard `from: namespaceSelector` rules don't match these
   reserved identities — a namespace with a default-deny ingress like
   `longhorn-internal` (allow only from `longhorn-system` ns) silently
   drops the apiserver's webhook calls.

   Fixed with [infrastructure/cilium/ccnp-allow-ingress-from-host.yaml](../infrastructure/cilium/ccnp-allow-ingress-from-host.yaml)
   — an additive `CiliumClusterwideNetworkPolicy` (`enableDefaultDeny:
   false`) that allows ingress from `host`, `remote-node`, and
   `kube-apiserver` entities to every pod. Symmetric to the existing
   apiserver-egress CCNP.

The `cilium-dbg monitor --type drop` command on a Cilium agent is the
diagnostic that surfaced this — drop reason `Policy denied` with source
identity 33554437 = `cidr:192.168.1.109/32 + reserved:remote-node`,
destination identity 32853 = `app=longhorn-manager`. The numeric
identity decodes via `cilium-dbg identity get <id>`.

### 2. Pod → kube-apiserver silently broke (the Cilium gotcha)

The single most important lesson from this migration: **NetworkPolicy
`ipBlock: 0.0.0.0/0` egress rules to port 443 do not match the
kubernetes API server under Cilium kube-proxy replacement.** Symptom:
every pod whose namespace had a default-deny + allow-egress-to-CIDR
NetworkPolicy lost connectivity to `10.96.0.1:443` immediately after
the cutover, even though the policy looked correct.

What's happening:

- A pod connects to `10.96.0.1:443` (the kubernetes Service VIP).
- Cilium's eBPF socket-LB intercepts the connect() in the pod's cgroup,
  *before* any policy evaluation, and rewrites the destination to one
  of the apiserver endpoints — e.g. `192.168.1.154:6443` (a control
  plane node IP).
- Policy is evaluated against the rewritten destination's identity.
- Cilium has a reserved identity called `kube-apiserver` (id 7) that
  takes precedence over `host`/`remote-node` for any IP+port the
  apiserver is listening on. CIDR rules don't match that identity.
- `policyCIDRMatchMode: nodes` extends ipBlock matching to `host` and
  `remote-node` identities — but **not** `kube-apiserver`. There's no
  CIDR mode that covers it.

The fix is two-part, both already wired into the repo:

- [infrastructure/cilium/values.yaml](../infrastructure/cilium/values.yaml)
  sets `policyCIDRMatchMode: [nodes]` so any *non-apiserver* node-IP
  egress (e.g. talking to kubelet on `:10250`, or pod-to-host pattern)
  works through CIDR rules.
- [infrastructure/cilium/ccnp-allow-kube-apiserver.yaml](../infrastructure/cilium/ccnp-allow-kube-apiserver.yaml)
  is an additive `CiliumClusterwideNetworkPolicy` with
  `enableDefaultDeny: false` that grants every pod egress to the
  `kube-apiserver` entity. This restores the implicit access pods had
  under Flannel (where NetworkPolicy was unenforced anyway) without
  weakening per-namespace policies for any other destination.

The `enableDefaultDeny: false` part is critical. The first version of
this CCNP was applied without it, which caused the policy to *select*
every pod (`endpointSelector: {}`) and only allow egress to the
apiserver — silently breaking DNS, external egress, and pod-to-pod
traffic for every namespace that previously had no NP at all. Cilium
1.14+ added `enableDefaultDeny` precisely so additive CCNPs don't
accidentally trigger isolation. Use it.

### 3. Flannel "supported" NetworkPolicy by ignoring it

The home cluster carried 10+ `NetworkPolicy` resources in CUE source,
authored in the ordinary deny-by-default + allow-known-egress style.
Under Flannel none of them were actually enforced — Flannel ships no
NetworkPolicy implementation. They appeared correct because nothing
ever blocked the traffic they nominally controlled.

Cilium *does* enforce NetworkPolicy. Several pre-existing policies
turned out to have gaps:

- `argo-events-isolation` allows egress to ports 53, 443, 6443, 8080,
  but not 4222 (NATS) — every sensor pod failed to reach
  `eventbus-default-stan` after migration.
- `external-secrets-egress` has the apiserver-CIDR pattern described
  above; broken until the kube-apiserver CCNP went on.
- Argo CD repo-server, OpenCost Prometheus, Velero kopia maintain
  jobs, external-dns-unifi, and a handful of others showed similar
  patterns: an egress allow that *looks* like it covers what the
  workload needs, but doesn't.

These are *not* migration bugs. They were silent misconfigurations that
the previous CNI hid. The migration just turned the lights on. Plan to
spend the day after the cutover walking each namespace, deciding which
egress rules really belong, and either fixing the policy or temporarily
relaxing `policyEnforcementMode` for the namespace.

### 4. Backup tooling

Three backup layers are taken before the migration starts:

1. **Velero on-demand backup** with `--snapshot-volumes` and
   `--ttl 720h`. On talos-home this completed `PartiallyFailed`
   (2 errors, 65 warnings) — the warnings are all completed Job pods
   whose pod-volumes can't be backed up post-completion (expected),
   the errors were a missing VolumeSnapshot CRD. The 2484 items + 61
   kopia Pod Volume Backups it produced are still usable for restore.
2. **OpenBao file-storage tar** of `/openbao/data` from the
   `openbao-0` pod. File-backed standalone OpenBao doesn't expose Raft
   snapshot, so this is the only direct way to capture seal state +
   data. Stash off-cluster (NAS or encrypted drive). The unseal key
   and root token live in a separate `openbao-keys` Secret — record
   them in a password manager, do not stage into git.
3. **Talos etcd snapshot** via `talosctl etcd snapshot`. `omnictl`
   does not have an `etcd snapshot` subcommand (the original plan
   assumed it did). Pull a per-cluster talosconfig with
   `omnictl talosconfig <path> --cluster <name> --merge=false` and
   run `talosctl --talosconfig <path> etcd snapshot` against it.

Velero's restore drill submitted post-migration timed out on
PodVolumeRestore. That's a separate kopia/R2 path issue, not migration
fallout — the underlying backups in R2 are intact and the velero
backup CR list shows them with `Completed`/`PartiallyFailed` status.

### 4.5. Longhorn instance-managers don't get rolled by `kubectl rollout restart`

Longhorn's `instance-manager` pods are created by `longhorn-manager`
itself (CRD-driven), not by a Deployment / DaemonSet / StatefulSet, so
the namespace-by-namespace `kubectl rollout restart deploy,ds,sts`
sweep in phase 7 misses them. They survive the cutover with their
pre-Cilium IPs, which Cilium tags `reserved:unmanaged` (no endpoint,
no datapath). Symptoms:

- Engines for active volumes report `state=running` but their `.status.ip`
  is the stale instance-manager IP. longhorn-manager → engine gRPC calls
  time out (i/o timeout to a 10.244.x.y that Cilium doesn't route).
- `csi-attacher` detach calls to `longhorn-backend:9500` time out
  (longhorn-backend forwards to the unreachable engine).
- `kubectl patch volume.longhorn.io ... nodeID=""` fails with the same
  webhook timeout, since the longhorn admission webhook backend hits
  the same dead engine path.
- Net result: **every PVC is stuck attached, no detach can complete,
  no remount can begin.** Looks identical to a Longhorn data corruption
  panic but is purely a CNI-state issue.

Fix in migration script Phase 6.6: enumerate `instance-manager` pods,
cross-reference each pod IP with `cilium ip list`, force-delete any
that show up as `reserved:unmanaged` or aren't in the IP cache at all.
longhorn-manager spawns replacements within seconds with proper
Cilium-issued IPs.

### 4.55. Containerd accumulates orphan sandbox-name reservations under churn

A subtler trap that bites *after* the actual CNI is fixed. During the
2+ hours of migration thrash (cilium agent rolls, CCNP applies, helm
upgrades, instance-manager recycles, flannel.1 deletes), kubelet
attempted to start dozens of pods on each node. Each attempt that
timed out at the CNI plugin layer (>10s response from cilium-agent)
left a "sandbox name" reservation in containerd's state, tied to a
container ID that never finished initialization.

After the underlying issues are fixed and pods retry:

```
Failed to create pod sandbox: rpc error: code = FailedPrecondition
desc = failed to reserve sandbox name "<podname>_<ns>_<uid>_0":
name "<podname>_<ns>_<uid>_0" is reserved for "<orphan-container-id>"
```

These reservations don't expire on their own under load — kubelet
keeps retrying, refreshing the orphan, every few seconds. After 2 hours
of thrash, talos-node-12 had **752 reservation errors** in kubelet's
log; talos-node-10 had 316. Every new pod scheduled to those nodes
hung in `ContainerCreating` indefinitely. Visible in
`talosctl logs kubelet | grep 'is reserved for' | wc -l` per node.

Talos doesn't expose a containerd-only restart through its API
(`talosctl service cri restart` and `service containerd restart` both
return *"doesn't support restart operation via API"*). `talosctl
service kubelet restart` clears kubelet's cache but the orphan
reservations are in containerd, not kubelet — restart doesn't help.

**The fix is `talosctl reboot`** of each affected node. Talos handles
graceful drain, all pods reschedule, containerd starts fresh on boot.
~3-5 min per node. On talos-home this resolved openbao-0,
opencost-prometheus-server, and a long tail of CronJob pods that had
been stuck for 50+ min.

To detect this proactively, the migration script should check
`talosctl logs kubelet | grep -c 'is reserved for'` per node *after*
phase 7 (workload roll); any node with > 50 reservation errors needs
a reboot before the run can be considered complete. (Adding this to
the script as Phase 7.6.)

### 4.6. Apiserver static pod restart is necessary, not sufficient

The first instinct after cluster network changes is to restart
kube-apiserver so it picks up fresh routing — this is correct on Talos
where apiserver is a static pod (`kubectl -n kube-system delete pod
kube-apiserver-<node>` triggers kubelet to recreate it). On a single-CP
home cluster this gives a 10–15 sec API blackout.

But it's not the full fix. Even with a fresh apiserver, it still can't
reach worker pods until the host-network routing issues above (1.5)
are addressed. **Schedule the apiserver restart AFTER applying the
host-ingress CCNP and deleting flannel.1**, otherwise it's pure
disruption with no benefit.

### 5. Operational bookkeeping that's easy to forget

- **VPA updater + admission-controller scaled to 0** during quiesce.
  Easy to forget to scale back up — the cluster will run fine without
  them, just won't apply right-sizing recommendations or in-place
  resizes.
- **Suspended cronjobs**: `velero-restore-drill`, `preview-reaper`,
  `ai-cost-aggregator`, `claude-oauth-refresher`. The last one is
  load-bearing: if it stays suspended past the OAuth token TTL,
  Claude-driven CI tasks start failing.
- **Kelos taskspawners paused** with `spec.paused: true`. Kelos's own
  reconciler will not auto-unpause these.
- **`migration-paused=true` label** on the `preview-envs`
  ApplicationSet stops PR-poll generators. Forgetting to remove this
  silently blocks all new preview env spin-ups.

The migration script's `phase_unquiesce` reverses every one of these.
Don't skip it.

## What surfaced in the days after — Part II: NP gap mole-whacking

Even after the migration's "official" phases all reported green, a
stream of services kept failing in subtle ways for the next 36 hours.
Every one of them traced back to a NetworkPolicy that Flannel had been
ignoring and Cilium suddenly took seriously. None of these were
visible during the migration's smoke tests because the smoke tests
hit the apiserver and external endpoints directly — they didn't
exercise Traefik→backend, cert-manager→OpenBao, Argo Events sensor→
eventbus, etc.

Running tally of NP rules that had to be added to
`composites/home/networkpolicies.cue`:

- **`argo-events-isolation`** — added intra-namespace ingress + egress
  so sensors can reach the NATS eventbus on 4222. Sensors had been
  CrashLoopBackOff with `dial tcp <eventbus-ip>:4222: i/o timeout`.
- **`argocd-traffic`** — added intra-namespace egress so server↔
  repo-server↔redis↔app-controller↔dex internal traffic works. Argo
  CD UI was hanging on every internal API call.
- **New `opencost-egress`** — DNS, intra-namespace, kubelet on 10250
  for cAdvisor scrape. OpenCost main pod was CrashLoopBackOff with
  "operation not permitted" errors connecting to the bundled
  Prometheus.
- **New `velero-egress`** — DNS, R2 (port 443), intra-namespace,
  longhorn-system. Kopia maintain jobs were timing out.
- **`traefik-egress`** — added two rules:
  1. Egress to NodePort range (30000-32767) on `0.0.0.0/0` so Traefik
     can proxy to LAN-side host services (metube, it-tools, recipes,
     n8n, webui, home-assistant all run on 192.168.1.148:NodePort).
     `ipBlock: 0.0.0.0/0` on 80/443 covers internet, but the NodePort
     range was a missing class.
  2. Egress to all in-cluster namespaces on common backend ports
     (3000, 8000, 8080, 8081, 8200, 9090, etc.). Cilium classifies
     in-cluster Service backends as pod identities — `ipBlock` doesn't
     match those even with `policyCIDRMatchMode: nodes`. Without the
     namespace rule, Traefik couldn't reach `homepage:3000`,
     `argocd-server:8080`, or any other in-cluster Ingress backend.
- **`openbao-isolation`** — added two rules:
  1. Ingress from `cert-manager` ns on 8200. Without this, the
     `openbao-example-internal` ClusterIssuer fell into "Failed to
     initialize Vault client: context deadline exceeded" and *all
     new TLS cert issuance stalled*. Existing certs (issued before
     the migration) kept working, so this only hit on the first
     attempt to issue a new cert (Hubble UI, in our case).
  2. Ingress from `traefik` ns on 8200. Without this, every hit to
     `https://openbao.example.internal/` timed out at Traefik even
     though the cluster-internal probe with Host header returned 200.

**Pattern**: every default-deny ingress NP needs explicit allowances
for cert-manager and traefik. Codified as a rule in the project's
memory (`feedback_cilium_np_enforcement.md`).

## What surfaced in the days after — Part III: Multus delegate chain

Multus was installed during the migration as planned (chart, thick
plugin, `cni.exclusive: false` in Cilium values for chaining). It
worked initially but exhibited a slow degradation:

1. After multiple Cilium DS rolls + node reboots, the multus-daemon
   pods on worker nodes accumulated state where they accepted CNI ADD
   requests but never completed the delegate call to `cilium-cni`.
2. Symptom: kubelet's `RunPodSandbox` calls to containerd timed out
   at the CNI plugin layer (10s default), leaving orphan sandbox name
   reservations in containerd. Subsequent retries hit
   "name reserved for &lt;orphan-id&gt;" and stayed in
   `ContainerCreating` forever.
3. Tell: `cilium-cni.log` (written by the actual `cilium-cni` binary
   when invoked) was missing on every node EXCEPT the control plane.
   Multus was receiving "ADD starting" but never reaching cilium-cni.

After three rolls of Multus DaemonSet failed to clear the hang, we
**uninstalled Multus entirely** (`kubectl delete -f
multus-daemonset-thick.yml`) and removed `00-multus.conf` +
`multus-shim` binary from every node via a privileged hostPath
DaemonSet. With Multus out of the way, kubelet falls back to
`05-cilium.conflist` and invokes `cilium-cni` directly. New pod
creates worked immediately.

**Why it bit us this time**: we didn't actually need secondary
networks yet. Multus was provisioned for "later" but its delegate
chain added a failure mode. Decision: leave it uninstalled until an
actual macvlan / SR-IOV / per-pod-real-LAN-IP use case appears. Cilium
is fine as primary CNI; Multus install is a 2-minute helm command
when needed.

## What surfaced in the days after — Part IV: Containerd orphan reservations

After 2+ hours of CNI/agent thrash, every worker node had accumulated
hundreds of orphan sandbox-name reservations (talos-node-12: 752,
talos-node-10: 316, talos-node-11: 1065, talos-node-04: 212). These
don't expire under load — kubelet's retry loop refreshes them every
few seconds. Standard fix is restarting containerd, which on Talos
has no `service cri restart` API:

```
$ talosctl service cri restart
service "cri" doesn't support restart operation via API
```

`talosctl service kubelet restart` doesn't help — orphans live in
containerd. The only fix is `talosctl reboot` of each affected node.
We had to reboot all 4 nodes sequentially (control plane last,
~3-5 min each) to fully clear state. Each reboot triggered ~30-40
pods to reschedule.

Detection signal we baked into the migration script (Phase 7.6):

```
talosctl --talosconfig <path> -n <ip> logs kubelet | grep -c 'is reserved for'
```

Anything > 50 means that node needs a reboot before the migration is
truly done. The rolling reboot is invasive enough that it should
happen *during* the planned migration window, not as an afterthought.

## What surfaced in the days after — Part V: Longhorn instance-manager IPs

Longhorn's `instance-manager` pods are created by `longhorn-manager`
itself (CRD-driven), not by a Deployment / DaemonSet / StatefulSet, so
the namespace-by-namespace `kubectl rollout restart deploy,ds,sts`
sweep in phase 7 missed them. They survived the cutover with their
pre-Cilium IPs, which Cilium tags `reserved:unmanaged`. Effects:

- Engines for active volumes reported `state=running` but `.status.ip`
  was the stale instance-manager IP. longhorn-manager → engine gRPC
  calls timed out (i/o timeout to a 10.244.x.y Cilium had no route to).
- `csi-attacher` detach calls to `longhorn-backend:9500` timed out
  because longhorn-backend forwards to the unreachable engine.
- `kubectl patch volume.longhorn.io ... nodeID=""` failed with the
  same webhook timeout.
- Net: every PVC stuck attached, no detach could complete, no remount
  could begin. Looked identical to Longhorn data corruption but was
  purely a CNI-state issue.

Fix: enumerate `instance-manager` pods, cross-reference each pod IP
with `cilium-dbg ip list`, force-delete any that show up as
`reserved:unmanaged`. longhorn-manager spawned replacements within
seconds with proper Cilium-issued IPs. Codified as Phase 6.6 in the
migration script.

## What surfaced in the days after — Part VI: Hubble UI flip

Once the cluster was stable, we turned on `hubble.relay.enabled` and
`hubble.ui.enabled` in `infrastructure/cilium/values.yaml` to get the
cluster network observability dashboard. Resource cost ~120 MiB RAM
cluster-wide. Exposed via `https://hubble.example.internal/` with a
new Ingress in `composites/home/ingresses.cue` (the only Ingress in
the project that targets a `kube-system` Service).

Two minor potholes:
- quay.io served a 502 Bad Gateway for the manifest fetch during the
  initial helm-upgrade — transient, second attempt succeeded.
- The new TLS cert (issued by `openbao-example-internal`) was the
  trigger that revealed the cert-manager NP gap above (it had been
  silently broken since the migration; nothing else needed a *new*
  cert until Hubble).

Homepage's auto-discovery picked it up via the `gethomepage.dev/*`
annotations within ~1 minute. Group "Platform" alongside Goldilocks
and OpenCost.

## What the next migration should do differently

- **Capture this script in the runbook before starting.** The original
  plan was correct in spirit but several details (Talos reboot
  behaviour, omnictl etcd subcommand, the CCNP additive flag) only
  surfaced during the run. The codified script
  [ci/scripts/migrate-cni-cilium.sh](../ci/scripts/migrate-cni-cilium.sh)
  reflects what actually works (11 phases, including the post-mortem-
  derived 6.5 / 6.6 / 7.6 cleanups for flannel.1 / instance-managers /
  containerd orphans).
- **Apply the kube-apiserver CCNP *before* deleting Flannel + kube-proxy**,
  not after the symptoms appear. The script does this in phase 5.
- **Apply the host-ingress CCNP at the same time** so admission
  webhooks backed by worker-node pods (Longhorn, cert-manager,
  ESO, etc.) keep working when apiserver tries to call them.
- **Budget a full week, not a day, for NetworkPolicy fixup** as a
  follow-up. The "2 hour migration window" turned into 36+ hours of
  whack-a-mole as Cilium's enforcement revealed each NP gap one tool
  at a time. The script's smoke tests in phase 8 catch the foundation
  ones (DNS, apiserver, external egress, ingress); the long tail
  (cert-manager → OpenBao, Traefik → in-cluster backends, sensor →
  eventbus) only shows up when those specific paths are exercised.
- **Take all three backup layers**, even if Velero feels like enough.
  Each one protects a different failure mode: Velero for namespaced
  resources + PVCs, OpenBao tar for seal state, Talos etcd snapshot
  for the cluster control-plane state including Crossplane CRs and
  Argo CD state that aren't always reliably re-applied from git alone.
- **Plan for 4 node reboots, not 0.** The original plan assumed Talos
  would handle reboots. It didn't (CNI ConfigPatch applies at runtime).
  Then containerd orphan reservations forced rolling reboots of every
  node anyway, *after* the cutover. Plan for them up front.
- **Skip Multus unless you actually need secondary networks today.**
  It was a "future-proofing" install that became a debugging burden
  with no payoff. Easy to add back if/when needed.

## References

- [docs/cilium-cni.md](cilium-cni.md) — install path + Talos tweaks
- [docs/multus.md](multus.md) — secondary-network attachments
- [ci/scripts/migrate-cni-cilium.sh](../ci/scripts/migrate-cni-cilium.sh) — live-cluster migration (phases 0–11, with the post-mortem-derived 6.5 + 6.6 cleanups)
- [ci/scripts/bootstrap-home.sh](../ci/scripts/bootstrap-home.sh) — fresh-cluster install (phase 2.5)
- [infrastructure/cilium/values.yaml](../infrastructure/cilium/values.yaml) — Talos-tuned Cilium values (`bpf.masquerade: true`, `devices: eth0`, `policyCIDRMatchMode: nodes`)
- [infrastructure/cilium/ccnp-allow-kube-apiserver.yaml](../infrastructure/cilium/ccnp-allow-kube-apiserver.yaml) — additive apiserver-egress allowance
- [infrastructure/cilium/ccnp-allow-ingress-from-host.yaml](../infrastructure/cilium/ccnp-allow-ingress-from-host.yaml) — additive apiserver-ingress allowance (host / remote-node / kube-apiserver entities)
- Cilium docs on `policyCIDRMatchMode`: https://docs.cilium.io/en/stable/security/policy/language/#policy-cidr-match-mode
- Cilium docs on the `kube-apiserver` entity: https://docs.cilium.io/en/stable/security/policy/language/#kube-apiserver
- Cilium docs on `bpf.masquerade` + Host BPF routing: https://docs.cilium.io/en/stable/network/concepts/masquerading/
