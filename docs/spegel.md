# Spegel — distributed in-cluster image pull-through cache

[Spegel](https://github.com/spegel-org/spegel) is a stateless daemon that
turns every node's local containerd image cache into a peer registry.
When a pod schedules and needs an image:

1. containerd checks its local store. Hit → pull skipped.
2. Miss → containerd's mirror config asks Spegel.
3. Spegel asks peers via libp2p. Peer hit → fetch over LAN.
4. Total miss → Spegel falls back to the upstream registry (ghcr.io,
   docker.io, etc.) on the asking node only.

## Why on the home cluster

| Pain today | Spegel fixes |
|---|---|
| Crossplane provider images (~150 MiB each) re-pulled per node on first apply | Pulled once, peer-distributed |
| `claude-code:v0.X` re-pulled when scaling kelos AI Tasks across nodes | Pulled once, served from a sibling node |
| Cloudflared, kelos-controller, ESO bouncing during reconciles → re-pulls | Cached locally on first pull, instant on restart |
| GHCR/Docker Hub rate limits hit during a noisy reconcile burst | Most pulls served from peers, upstream only on miss |
| Slow upstream during a Cloudflare outage | Cluster keeps pulling from peers |

Cost:
- ~64-256 MiB RAM per node for the Spegel pod.
- ~2-4× image size in extra disk (containerd keeps unpacked layers).
- Writes a containerd hosts.toml file per registry mirror — if you
  later add a private registry, Spegel needs an annotation per ns to
  honor pull secrets.

## Bootstrap order

1. **Apply the containerd ConfigPatch** (Talos must reboot to pick it up):
   ```bash
   omnictl apply -f infrastructure/talos/spegel-containerd-patch.yaml \
     --label omni.sidero.dev/cluster=<cluster-name>
   ```
   This sets `discard_unpacked_layers = false` so Spegel has layers to
   advertise. Without this, Spegel runs but caches nothing useful.

2. **Wait for nodes to reboot** (Talos rolls them sequentially). Verify:
   ```bash
   kubectl get nodes  # all Ready
   ```

3. **Install Spegel**:
   ```bash
   ./infrastructure/spegel/install.sh
   ```

4. **Smoke test**:
   ```bash
   # Pull on node A
   kubectl run spegel-test-a --image=nginx:1.27 --restart=Never \
     --image-pull-policy=Always --overrides='{"spec":{"nodeName":"<nodeA>"}}'
   kubectl wait pod/spegel-test-a --for=condition=Ready --timeout=60s
   kubectl delete pod spegel-test-a --wait=true

   # Pull on node B — should be served by Spegel from node A
   kubectl run spegel-test-b --image=nginx:1.27 --restart=Never \
     --image-pull-policy=Always --overrides='{"spec":{"nodeName":"<nodeB>"}}'
   ```

5. **Confirm hit rate** via metrics:
   ```bash
   kubectl -n spegel port-forward ds/spegel 9090:9090
   curl -s localhost:9090/metrics | grep -E "spegel_(mirror_requests|advertised)"
   ```

## Should we add it to the home cluster?

**Yes — the cost/benefit is favorable:**

| For | Against |
|---|---|
| 4-node cluster pulls each image up to 4× today | +1 daemonset per node (small) |
| Heavy images (Crossplane providers, claude-code, Longhorn) re-pulled often | Disk overhead from unpacked layers (~5-10 GiB cluster-wide on this image set) |
| Multiple GHCR-hosted private packages → rate-limit sensitivity | Adds a containerd config dependency — if Spegel breaks, mirror config still attempts and may delay pulls before falling back |
| Bonus: insulates against ghcr.io / docker.io transient outages | Need to remember to label `spegel` ns privileged |

**Risks:**
- Spegel itself pulls images peer-to-peer over the pod network (CNI). On
  Flannel + VXLAN this works fine. If we later move to Cilium with strict
  NetworkPolicy, need to allow spegel↔spegel on the libp2p port.
- A node reboot evicts its image cache. Cache rewarms as workloads pull
  again — first pull of a re-warming image hits upstream.

**Recommend**: install on home cluster after the next maintenance window
(needs node reboots for the containerd patch). Treat as DR + perf win,
not critical-path.

## Known issues

- `discard_unpacked_layers = false` adds disk usage. Monitor
  `/var/lib/containerd` on each node; if pinching, prune images via
  `kubectl debug node/<n> -- crictl rmi --prune`.
- Pull secret usage: Spegel itself doesn't proxy auth. For a private
  registry, the pull secret must be in the consuming namespace AND
  Spegel needs to know via `spegel.spegel.upstreamMirrors` config; off
  by default for ghcr.io which works anonymously for our packages.

## Reference

- Sidero: https://docs.siderolabs.com/kubernetes-guides/advanced-guides/spegel
- Project: https://github.com/spegel-org/spegel
- Latest stable: v0.7.0 (2026-04-19)
