# Home cluster recovery — Flannel-only path

End-to-end rebuild of the `home` Talos cluster on Flannel + kube-proxy
(no Cilium). This is the simplified clone of the validated 2026-05-14
runbook (see auto-memory `project_home_recovery_runbook`) with the
Cilium-specific phases removed.

Use this when the operator has decided the cluster's profile doesn't
justify Cilium's overhead — see `docs/cni-revert-to-flannel.md` for the
decision rationale.

## Phase 0 — pre-flight (Omni side)

In the Omni UI:

1. Open the `talos-home` cluster machine template.
2. **Detach** any `100-cilium-cni-*` ConfigPatch. With no CNI patch
   attached, Talos defaults apply at bootstrap:
   - `cluster.network.cni.name = flannel`
   - `cluster.proxy.disabled = false`
   Talos installs `kube-flannel` + `kube-proxy` DaemonSets automatically
   when nodes first join.
3. Leave the apiserver-tuning ConfigPatch (`200-apiserver-tuning-*`) and
   kubelet-cert-rotation ConfigPatch (`200-kubelet-cert-rotation-*`)
   attached — both are CNI-agnostic.
4. Re-create the cluster from the template. Wait for all nodes to
   `Ready` in `kubectl get nodes`. If any node is `NotReady` after 5
   minutes, check that no stale Cilium ConfigPatch is on the machine
   class.

## Phase 1 — bootstrap

```bash
INSTALL_CNPG=0 ./ci/scripts/bootstrap-home.sh --no-pause
```

The bootstrap script auto-detects Flannel (since 2026-05-20 — see
`phase_cilium` in `ci/scripts/bootstrap-home.sh`) and does nothing
else CNI-side. `INSTALL_CNPG=0` because CNPG is a Crossplane-managed
XHelmRelease, not a bootstrap component.

Expect a 30-90s apiserver outage mid-bootstrap when the tuning patch
rolls the static pod.

## Phase 2 — seed Velero R2 creds

OpenBao is up but empty after bootstrap, so ESO can't sync
`velero-r2-creds`, so Velero pods can't start, so we can't restore
anything. Manually seed:

```bash
kubectl port-forward -n openbao svc/openbao 8200:8200 &
export BAO_ADDR=http://127.0.0.1:8200    # 127.0.0.1, not localhost — IPv6 issues with port-forward
export BAO_TOKEN=$(kubectl get secret openbao-keys -n openbao \
  -o jsonpath='{.data.root-token}' | base64 -d)
bao kv put secret/preview/r2-velero \
  AWS_ACCESS_KEY_ID=<id> AWS_SECRET_ACCESS_KEY=<key>
kubectl -n velero annotate externalsecret velero-r2-creds \
  force-sync=$(date +%s) --overwrite
kubectl -n velero delete pods --all
```

R2 creds: current values are on the workstation; backup-time values may
have rotated, so use current.

## Phase 3 — wait for Velero to sync backups from R2 (~60s)

```bash
kubectl -n velero get backups.velero.io
```

All historical backups including the `velero-openbao-daily-*` series
should populate.

## Phase 4 — restore openbao (the critical step)

```bash
kubectl annotate xhelmrelease.infra.k8 openbao crossplane.io/paused=true
kubectl -n openbao scale sts openbao --replicas=0
kubectl -n openbao delete pvc data-openbao-0
kubectl -n openbao patch cronjob openbao-auto-unseal \
  -p '{"spec":{"suspend":true}}'

cat <<EOF | kubectl apply -f -
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: openbao-restore-$(date +%Y%m%d)
  namespace: velero
spec:
  backupName: velero-openbao-daily-<LATEST_TS>
  includedNamespaces: [openbao]
  existingResourcePolicy: update
  excludedResources: [events.events.k8s.io, endpoints, endpointslices.discovery.k8s.io]
EOF
```

**Do NOT exclude Pods.** Velero needs the Pod manifest to inject the
kopia restore-helper init container — see auto-memory
`feedback_velero_fsb_restore_needs_pods`. The restore takes 3-5 min;
PVRs appear in `kubectl -n velero get podvolumerestores`.

After restore: unpause openbao XR + unsuspend the cronjob.

## Phase 5 — ESO cascade

```bash
kubectl -n external-secrets rollout restart deploy external-secrets
```

Wait ~60s. All ~30 ExternalSecrets should go green now that the backing
OpenBao paths exist.

## Phase 6 — apply ClusterIssuers

```bash
kubectl apply -f infrastructure/cert-manager/
```

The 18 Certificates fan out on their own once the issuers are ready.

## Phase 7 — fix kelos namespace adoption

The kelos chart refuses to install because Crossplane's XNamespace
claims the namespace. Per the note in `composites/home/namespaces.cue`:

```bash
kubectl annotate xnamespaces.infra.k8 kelos-system \
  crossplane.io/paused=true --overwrite
kubectl label namespace kelos-system \
  app.kubernetes.io/managed-by=Helm --overwrite
kubectl annotate namespace kelos-system \
  meta.helm.sh/release-name=kelos \
  meta.helm.sh/release-namespace=kelos-system --overwrite
kubectl delete release.helm.crossplane.io kelos
```

## Phase 8 — verify

- `kubectl get nodes` — all Ready
- `kubectl -n kube-system get ds kube-flannel kube-proxy` — all rolled
- `home.example.internal` returns HTTP 200
- All HelmReleases Ready
- All Certificates Ready
- All ExternalSecrets Ready
- Smoke targets: bb-docs, jarvy-telemetry, salessage preview env

## What's gone vs. the Cilium-based runbook

- No Phase 8 CNI migration. Cluster starts on Flannel and stays.
- No socket-LB recycle dance after node reboots
  (`feedback_cilium_node_reboot_recycle` no longer applies).
- No CCNPs to apply. Standard `NetworkPolicy` resources are accepted
  by the API but Flannel doesn't enforce them — they're documentation
  rather than enforcement. New work that requires actual pod-to-pod
  enforcement should layer in a NetworkPolicy controller
  (e.g. Calico-policy-only) or move that workload to a different
  cluster.

## Time budget

| Phase | Wall clock |
|---|---|
| 0 (Omni recreate) | 10-15 min |
| 1 (bootstrap) | 20-30 min |
| 2-3 (R2 seed + Velero sync) | 5 min |
| 4 (openbao restore) | 5-10 min |
| 5-6 (ESO + ClusterIssuers) | 5 min (+ cert-manager DNS01 propagation can add 10-20 min) |
| 7 (kelos adoption) | <5 min |
| 8 (verify) | 10 min |
| **Total** | **~75-100 min** (~30 min faster than the Cilium-based path) |
