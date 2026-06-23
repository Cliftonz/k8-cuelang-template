# Troubleshooting log — 2026-05-15 post-recovery hardening

The day after the 14-hour rebuild (see
[troubleshooting-2026-05-14-cluster-recovery.md](troubleshooting-2026-05-14-cluster-recovery.md)).
What started as "remove Coder and install KubeVirt" turned into
four discovered platform bugs that traced back to the rebuild itself.
Each is documented here with the exact symptom, root cause, and fix.

---

## Bug 1: oauth2-proxy sending the secret as the client_id

### Symptom

Browser visits `https://traefik.example.internal/` (or any other
auth-with-redirect-gated app) → reaches Dex's `/auth` endpoint →
Dex responds:

```
Not Found
Invalid client_id ("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef").
```

The 64-char hex was the OIDC client SECRET, not the client_id.

### Root cause

The ExternalSecret in `composites/home/externalsecrets.cue` for
oauth2-proxy was:

```cue
data: [
  {secretKey: "client-id",     remoteRef: {key: "home/dex/clients", property: "oauth2proxy"}},
  {secretKey: "client-secret", remoteRef: {key: "home/dex/clients", property: "oauth2proxy"}},
]
```

Both `client-id` AND `client-secret` were pulled from the same OpenBao
property (`oauth2proxy`), which holds the secret value. So oauth2-proxy
sent the secret as both fields. Dex's `id` for the static client is
the literal string `"oauth2-proxy"` — nothing matched.

Likely original-author error: they wanted the secret to be sourced
from OpenBao and forgot that `client-id` is a literal identifier, not
a credential.

### Fix

ESO template, hardcoding the literal id:

```cue
data: [
  {secretKey: "client_secret", remoteRef: {key: "home/dex/clients", property: "oauth2proxy"}},
  {secretKey: "cookie_secret", remoteRef: {key: "home/dex/clients", property: "oauth2proxy_cookie"}},
]
template: {
  type: "Opaque"
  data: {
    "client-id":     "oauth2-proxy"
    "client-secret": "{{ .client_secret }}"
    "cookie-secret": "{{ .cookie_secret }}"
  }
}
```

Commit: `324741d`.

### Diagnostic recipe

```bash
# What the upstream service THINKS the client_id is:
kubectl -n oauth-proxy get secret oauth2-proxy-dex-client -o jsonpath='{.data.client-id}' | base64 -d

# What Dex is configured to accept:
kubectl -n dex get cm dex -o jsonpath='{.data}' | grep -A2 '"id":'
```

If the first command returns a long hex string instead of a short
human-readable id, that's the bug.

---

## Bug 2: OpenBao filesystem went read-only

### Symptom

OpenBao logs flooded with:

```
core: failed to create token: error="failed to persist accessor index entry:
  open /openbao/data/sys/token/accessor/_xxx.temp: read-only file system"
```

Every ExternalSecret tied to `openbao-backend` ClusterSecretStore
showed `SecretSyncedError` with:

```
unable to log in to auth method: unable to log in with Kubernetes auth:
  Error making API request. URL: PUT
  http://openbao.openbao.svc.cluster.local:8200/v1/auth/kubernetes/login
  Code: 500. Errors: * internal error
```

### Root cause

The Longhorn-backed PVC (10Gi) hosting `/openbao/data` got remounted
read-only. Longhorn reports the volume as `state: attached, robustness:
healthy` — but the engine flipped the mount RO at some point (likely
during a brief Longhorn engine-pod restart). OpenBao kept running with
the stale mount; its writes started failing silently from the FS layer
up.

### Fix

```bash
kubectl -n openbao delete pod openbao-0
# Auto-unseal CronJob re-unseals within 2 min
# ESO controller may also need a kick:
kubectl -n external-secrets rollout restart deploy external-secrets
```

The pod-restart remounts the PVC fresh (RW). The ESO restart
re-establishes its session to OpenBao (the controller caches the
previous session token and didn't notice the server had been
restarted).

### Diagnostic recipe

```bash
# Catch this early — log line is unmissable once you look:
kubectl -n openbao logs openbao-0 | grep -i "read-only"

# Symptom on the consumer side: every ES says "InvalidProviderConfig"
# with a 500 error pointing at openbao.openbao.svc.cluster.local
kubectl describe clustersecretstore openbao-backend | tail -10
```

This is the second time on home cluster (the original 2026-05-14
recovery also hit it). Worth a watcher alert: cron 5m, grep for
`read-only file system` in openbao-0 logs.

---

## Bug 3: NetworkPolicy port mismatch is now a recurring trap

3 instances on home cluster in 1 week — promoted from
"obscure footgun" to "checked in CI":

| Date | NP | Service | Mismatch |
|---|---|---|---|
| 2026-05-14 | coder-traffic | coder :80 → pod :8080 | NP only allowed :80 |
| 2026-05-15 | oauth-proxy-traffic | oauth-redirect-page :80 → pod :8080 | NP only allowed :80 + :4180 |
| 2026-05-15 (recurrence) | goldilocks-traffic | goldilocks-dashboard :80 → pod :8080 | (proactive — no NP existed) |

### Root cause

Cilium evaluates NetworkPolicy `ports` AGAINST the post-DNAT
destination port. Service `:80 → pod :8080` means the agent sees
dst=:8080 and matches against the policy's allowed ports. Allowing
only `:80` (the Service port) silently drops everything.

### Permanent guardrails added this session

1. **`ci/scripts/check-np-post-dnat.sh`** — audits every Ingress
   backend, resolves named targetPorts via the actual containerPort
   on the backing pod, confirms the destination NP has a rule that
   admits source-ns→pod-port. Exits 1 on any gap.
2. **`make check-np-post-dnat`** — Make target for the same.
3. **Integrated into `ci/scripts/cluster-health.sh`** — runs on every
   full sweep (skipped in `--quick` mode).

Commit `d0a3657` introduces the audit; `ebf325b` wires it into
cluster-health.

---

## Bug 4: Stuck-Terminating namespace from broken APIService

### Symptom

Deleted Coder via `kubectl delete xnamespace coder`. All pods, PVCs,
PV, Services, NPs gone within ~10s. But the namespace itself stuck
in `Terminating` indefinitely.

`kubectl get ns coder -o json` showed:

```
conditions:
- type: NamespaceDeletionDiscoveryFailure
  status: "True"
  message: "Discovery failed for some groups, 1 failing:
            unable to retrieve the complete list of server APIs:
            metrics.k8s.io/v1beta1: stale GroupVersion discovery"
- type: NamespaceContentRemaining
  status: "False"
  message: "All content successfully removed"
```

### Root cause

The namespace controller, before removing the `kubernetes` finalizer,
runs a discovery loop against every registered APIService to confirm
no resources remain. If even one APIService is Unavailable, the loop
fails and the ns stays in Terminating forever — even when every
content type has been fully drained.

In this case: `metrics.k8s.io/v1beta1` was Unavailable because the
metrics-server pod's readiness probe was failing on `tls: failed to
verify certificate ... doesn't contain any IP SANs`. Talos kubelets
generate their serving certs without IP SANs unless
`rotate-server-certificates=true` is set.

### Fix

```yaml
# Omni ConfigPatch:
metadata:
    namespace: default
    type: ConfigPatches.omni.sidero.dev
    id: 200-kubelet-cert-rotation-talos-home
    labels:
        omni.sidero.dev/cluster: talos-home
spec:
    data: |
        machine:
          kubelet:
            extraArgs:
              rotate-server-certificates: "true"
```

Applied via `omnictl apply -f <patch>.yaml`. Talos restarts kubelet
in-place (no node reboot). kubelet-serving-cert-approver
auto-approves the new CSRs in ~30s per node. metrics-server scrape
succeeds. APIService Available. Namespace finalizes.

Commit: `abdbc4a` (doc); the patch itself was never committed because
Omni-managed config patches live in Omni, not the repo (file
`infrastructure/talos/kubelet-cert-rotation.yaml` documents the
expected content).

### Diagnostic recipe

```bash
# Any APIService Unavailable will block ns deletion:
kubectl get apiservice | grep -v Available
```

If `v1beta1.metrics.k8s.io` shows `False (MissingEndpoints)` or just
`False`, the namespace controller can't make progress. Either fix the
broken APIService or `kubectl delete apiservice <name>` to unblock
(GitOps will recreate it later).

---

## Bug 5 (meta): Omni ConfigPatches don't carry through cluster rebuilds

The kubelet-cert-rotation patch was **authored 2026-05-06** (during
the Cilium migration) but **never applied** to talos-home because the
cluster was rebuilt mid-day 2026-05-14 from base templates. Omni
doesn't export existing ConfigPatches with cluster definitions;
they're a separate resource type.

### Lesson

When rebuilding a Talos cluster via Omni:

1. Before destroying: `omnictl get configpatch -l "omni.sidero.dev/cluster=<name>"`
2. Export each patch: `omnictl get configpatch <id> -o yaml > patches/<id>.yaml`
3. After rebuild: `omnictl apply -f patches/`

There's no `omnictl export cluster` that bundles patches today.

### Persistent fix considered

Add `infrastructure/talos/configpatches/` directory with one YAML per
intended ConfigPatch, and a script `ci/scripts/apply-omni-patches.sh`
that re-applies all of them. Deferred — adding when we hit this a
second time.

---

## What's now in place to catch these earlier

- **`make check-np-post-dnat`** — runs the NP audit. CI/CD could
  invoke this against the live cluster context.
- **`ci/scripts/cluster-health.sh`** — full sweep includes the NP
  audit + warning event triage. Quick mode skips the audit.
- **Memory entries** (under `~/.claude/projects/.../memory/`):
  - `cilium-np-evaluates-ports-after-service-dnat`
  - `kubelet-rotate-server-certificates-applied-to-talos-home`
  - `omni-configpatch-flow`
  - `coder-removed-from-home-cluster`

## What's still NOT instrumented

- **OpenBao read-only filesystem detection** — log line is unmissable
  but only if you're tailing. A cron-driven `bao status` check that
  alerts on Sealed=true or write probe-failure would catch this within
  5 min. Not built.
- **ESO controller session staleness** — when OpenBao restarts, the
  ESO controller keeps a stale session token. Restart the controller
  manually. A health-check that pokes the secret store after OpenBao
  restarts would automate this. Not built.
- **stale APIService → stuck Terminating** — `cluster-health.sh`
  doesn't flag APIServices that are False/Unavailable; add a check
  that grep-greens this.
- **Cluster-config drift after Omni rebuild** — no automation for
  re-applying ConfigPatches. Manual checklist for now.
