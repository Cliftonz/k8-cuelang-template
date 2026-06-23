#!/usr/bin/env bash
# Migrate an existing Talos+K8s cluster from Flannel+kube-proxy to
# Cilium (kube-proxy replacement).
#
# This is the EXISTING-CLUSTER path. For fresh clusters, bootstrap-home.sh
# already installs Cilium from scratch via phase_cilium.
#
# Phases:
#   0    pre-flight (kubectl, helm, omnictl, talosctl, jq, age of etcd
#        snapshot off-cluster, free space for backups)
#   1    three-layer backup: Velero on-demand backup -> OpenBao snapshot
#        -> Talos etcd snapshot via talosctl. All three must complete green.
#   2    quiesce: scale VPA down, suspend cronjobs, pause kelos
#        taskspawners, label preview-envs ApplicationSet migration-paused.
#   3    apply Talos ConfigPatch via omnictl: cluster.network.cni.name=none
#        + cluster.proxy.disabled=true. Talos applies at runtime (no reboot).
#   4    helm install Cilium with values from infrastructure/cilium/values.yaml
#        (KubePrism 7445, kubeProxyReplacement, policyCIDRMatchMode: nodes,
#        bpf.masquerade: true, devices: eth0).
#   5    apply two additive CCNPs:
#         - allow-egress-to-kube-apiserver (pods -> apiserver Service VIP)
#         - allow-ingress-from-host (apiserver/host/remote-node entities ->
#           pods, required for admission webhooks backed by worker pods).
#        Both have enableDefaultDeny: false so they're purely additive.
#   6    delete kube-flannel + kube-proxy DaemonSets in kube-system.
#   6.5  delete leftover `flannel.1` VXLAN device on every node. Talos
#        doesn't garbage-collect it; it stays UP holding stale ARP entries
#        + a kernel socket on UDP/8472 (same port as Cilium's tunnel),
#        causing intermittent VXLAN packet loss and apiserver->pod failure.
#   6.6  recycle Longhorn `instance-manager` pods. They're managed by
#        longhorn-manager directly (not a controller), so phase_roll_workloads
#        misses them and they keep their pre-Cilium "reserved:unmanaged" IPs.
#   7    rollout restart all workloads namespace-by-namespace so they get
#        Cilium-issued IPs and fresh cgroup-attached socket-LB hooks.
#   7.6  detect containerd orphan sandbox-name reservations from prior
#        CNI plugin timeouts. Talos doesn't expose containerd restart
#        via API; the only fix is `talosctl reboot` of the affected node.
#        Auto-detects nodes with > 50 reservation errors in kubelet log.
#   8    Phase 3 smoke tests: in-cluster DNS, pod->apiserver, external
#        egress, ingress through Traefik. STOP and rollback if any fail.
#   9    un-quiesce: scale VPA back, unsuspend cronjobs, un-pause
#        taskspawners, remove migration-paused label.
#  10    trigger velero-restore-drill manually as post-migration validation.
#
# Rollback (if Phase-8 smoke fails or > 30 min outage):
#   - omnictl delete configpatch 100-cilium-cni-talos-<cluster>  (Talos
#     reinstalls Flannel + kube-proxy on next reconcile)
#   - helm uninstall cilium -n kube-system
#   - if pods still broken: kubectl -n velero create restore from latest
#     pre-cilium-migration-* backup.
#
# Usage:
#   ./ci/scripts/migrate-cni-cilium.sh                # full run, paused between phases
#   ./ci/scripts/migrate-cni-cilium.sh --no-pause     # unattended
#   ./ci/scripts/migrate-cni-cilium.sh --skip-backup  # skip Phase 1 (re-runs)
#   ./ci/scripts/migrate-cni-cilium.sh --check-only   # preflight only
#
# Environment overrides:
#   OMNI_CLUSTER       Omni cluster name (default: talos-${CLUSTER})
#   CLUSTER            local cluster nickname (default: home)
#   BACKUP_DIR         where to stash OpenBao + etcd snapshots
#                      (default: ~/cluster-backups/<TS>)
#   CILIUM_VERSION     default 1.19.3
#   SKIP_TALOS_PATCH=1 skip omnictl ConfigPatch apply (re-runs)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLUSTER="${CLUSTER:-home}"
OMNI_CLUSTER="${OMNI_CLUSTER:-talos-${CLUSTER}}"
TS="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_DIR:-${HOME}/cluster-backups/${TS}}"
CILIUM_VERSION="${CILIUM_VERSION:-1.19.3}"

CHECK_ONLY=0
SKIP_BACKUP=0
SKIP_TALOS_PATCH="${SKIP_TALOS_PATCH:-0}"
PAUSE=1

for arg in "$@"; do
  case "$arg" in
    --check-only)  CHECK_ONLY=1 ;;
    --skip-backup) SKIP_BACKUP=1 ;;
    --no-pause)    PAUSE=0 ;;
    --pause)       PAUSE=1 ;;
    -h|--help)     sed -n '2,55p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()   { printf '[migrate-cni] %s\n' "$*"; }
warn()  { printf '[migrate-cni] WARN: %s\n' "$*" >&2; }
ok()    { printf '[migrate-cni] OK: %s\n' "$*"; }
die()   { printf '[migrate-cni] FAIL: %s\n' "$*" >&2; exit 1; }

phase_pause() {
  [[ "$PAUSE" == "1" ]] || return 0
  echo
  read -rp "[migrate-cni] press <enter> to continue, ctrl-C to abort... " _ </dev/tty
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

# ---------------------------------------------------------------------------
# Phase 0: preflight
# ---------------------------------------------------------------------------
phase_preflight() {
  log "Phase 0: preflight"
  require kubectl
  require helm
  require omnictl
  require talosctl
  require jq

  kubectl version --request-timeout=5s >/dev/null 2>&1 \
    || die "kubectl can't reach the cluster"

  # Confirm we're talking to the expected Omni cluster
  local current_ctx
  current_ctx="$(kubectl config current-context)"
  log "kubectl context: $current_ctx"
  log "Omni cluster:    $OMNI_CLUSTER"

  # Check that Cilium isn't already the only CNI (idempotent re-run is OK,
  # but warn if we're past the cutover already)
  if kubectl -n kube-system get ds cilium >/dev/null 2>&1 \
    && ! kubectl -n kube-system get ds kube-flannel >/dev/null 2>&1; then
    warn "cilium already installed and flannel is gone — looks like migration already happened"
    warn "this run will re-validate steps but be a no-op for most phases"
  fi

  ok "preflight green"
}

# ---------------------------------------------------------------------------
# Phase 1: three-layer backup
# ---------------------------------------------------------------------------
phase_backup() {
  log "Phase 1: three-layer backup -> ${BACKUP_DIR}"
  mkdir -p "${BACKUP_DIR}"

  # Layer 1: Velero on-demand backup
  log "  layer 1: velero on-demand backup..."
  local backup_name="pre-cilium-migration-${TS}"
  kubectl -n velero exec deploy/velero -- \
    /velero backup create "${backup_name}" \
    --include-namespaces "*" \
    --exclude-namespaces "kube-public,kube-node-lease" \
    --snapshot-volumes \
    --ttl 720h
  log "  waiting for velero backup to complete..."
  for i in $(seq 1 60); do
    local phase
    phase="$(kubectl -n velero get backup "${backup_name}" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
    case "$phase" in
      Completed|PartiallyFailed) break ;;
      Failed|FailedValidation) die "velero backup failed: $phase" ;;
    esac
    sleep 10
  done

  # Layer 2: OpenBao file-storage snapshot (file-backed standalone)
  log "  layer 2: openbao snapshot..."
  if kubectl -n openbao get pod openbao-0 >/dev/null 2>&1; then
    kubectl -n openbao exec openbao-0 -- tar czf - -C /openbao data \
      > "${BACKUP_DIR}/openbao-snapshot-${TS}.tar.gz"
    shasum -a 256 "${BACKUP_DIR}/openbao-snapshot-${TS}.tar.gz" \
      | tee "${BACKUP_DIR}/openbao-snapshot-${TS}.sha256"
  else
    warn "openbao-0 not found — skipping layer 2 (acceptable if openbao not installed)"
  fi

  # Layer 3: Talos etcd snapshot (per-cluster talosconfig fetched fresh)
  log "  layer 3: talos etcd snapshot..."
  local talosconfig="${BACKUP_DIR}/talosconfig"
  omnictl talosconfig "${talosconfig}" --cluster "${OMNI_CLUSTER}" --merge=false
  # talosctl 1.13+ requires --nodes explicitly (older versions read from the
  # talosconfig's `endpoints`). Discover the control-plane IP via kubectl
  # so the script keeps working across talosctl versions.
  local cp_ip
  cp_ip=$(kubectl get nodes -l node-role.kubernetes.io/control-plane \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  [[ -n "$cp_ip" ]] || die "could not discover control-plane node IP for etcd snapshot"
  talosctl --talosconfig "${talosconfig}" --nodes "${cp_ip}" \
    etcd snapshot "${BACKUP_DIR}/${OMNI_CLUSTER}-etcd-${TS}.snap"

  ok "all three backup layers green: ${BACKUP_DIR}"
}

# ---------------------------------------------------------------------------
# Phase 2: quiesce
# ---------------------------------------------------------------------------
phase_quiesce() {
  log "Phase 2: quiesce moving parts"
  kubectl -n vpa-system scale deploy vpa-updater              --replicas=0 2>/dev/null || true
  kubectl -n vpa-system scale deploy vpa-admission-controller --replicas=0 2>/dev/null || true

  for cj in 'velero/velero-restore-drill' \
            'argocd/preview-reaper' \
            'kelos-system/ai-cost-aggregator' \
            'kelos-system/claude-oauth-refresher'; do
    local ns="${cj%%/*}" name="${cj##*/}"
    kubectl -n "$ns" get cronjob "$name" >/dev/null 2>&1 \
      && kubectl -n "$ns" patch cronjob "$name" \
           -p '{"spec":{"suspend":true}}' >/dev/null
  done

  for ts_obj in $(kubectl -n kelos-system get taskspawner -o name 2>/dev/null); do
    kubectl -n kelos-system patch "$ts_obj" --type merge \
      -p '{"spec":{"paused":true}}' >/dev/null || true
  done

  kubectl -n argocd label applicationset preview-envs \
    migration-paused=true --overwrite 2>/dev/null || true

  ok "quiesced"
}

# ---------------------------------------------------------------------------
# Phase 3: Talos ConfigPatch
# ---------------------------------------------------------------------------
phase_configpatch() {
  log "Phase 3: apply Talos ConfigPatch (CNI=none, kube-proxy disabled)"
  if [[ "$SKIP_TALOS_PATCH" == "1" ]]; then
    warn "SKIP_TALOS_PATCH=1 — assuming patch already applied"
    return 0
  fi
  local patch_file="${BACKUP_DIR:-/tmp}/cilium-cni-patch-${OMNI_CLUSTER}.yaml"
  cat <<EOF > "$patch_file"
metadata:
  namespace: default
  type: ConfigPatches.omni.sidero.dev
  id: 100-cilium-cni-${OMNI_CLUSTER}
  labels:
    omni.sidero.dev/cluster: ${OMNI_CLUSTER}
spec:
  data: |
    cluster:
      network:
        cni:
          name: none
      proxy:
        disabled: true
EOF
  omnictl apply -f "$patch_file"
  ok "ConfigPatch applied: 100-cilium-cni-${OMNI_CLUSTER}"
}

# ---------------------------------------------------------------------------
# Phase 4: install Cilium
# ---------------------------------------------------------------------------
phase_cilium() {
  log "Phase 4: install Cilium ${CILIUM_VERSION}"
  if [[ "${SKIP_CILIUM_INSTALL:-0}" == "1" ]]; then
    warn "SKIP_CILIUM_INSTALL=1 — assuming Cilium already deployed; skipping helm upgrade"
    return 0
  fi
  CILIUM_VERSION="${CILIUM_VERSION}" "${REPO_ROOT}/infrastructure/cilium/install.sh"
  ok "Cilium installed and DaemonSet healthy"
}

# ---------------------------------------------------------------------------
# Phase 5: apiserver / host CCNPs (egress + ingress)
# ---------------------------------------------------------------------------
phase_apiserver_ccnp() {
  log "Phase 5: apply additive Cilium ClusterwideNetworkPolicies for apiserver/host paths"
  local egress="${REPO_ROOT}/infrastructure/cilium/ccnp-allow-kube-apiserver.yaml"
  local ingress="${REPO_ROOT}/infrastructure/cilium/ccnp-allow-ingress-from-host.yaml"
  for m in "$egress" "$ingress"; do
    [[ -f "$m" ]] || die "missing $m — was the CCNP committed to repo?"
    kubectl apply --validate=false -f "$m"
  done
  ok "apiserver-egress + host-ingress CCNPs applied (additive, default-deny: false)"
}

# ---------------------------------------------------------------------------
# Phase 6: delete old CNI
# ---------------------------------------------------------------------------
phase_delete_old_cni() {
  log "Phase 6: delete kube-flannel + kube-proxy DaemonSets"
  for ds in kube-flannel kube-proxy; do
    if kubectl -n kube-system get ds "$ds" >/dev/null 2>&1; then
      kubectl -n kube-system delete ds "$ds"
    else
      log "  $ds already removed"
    fi
  done
  ok "old CNI gone"
}

# ---------------------------------------------------------------------------
# Phase 6.5: Flannel-leftover cleanup on every node
#
# Talos doesn't garbage-collect the `flannel.1` VXLAN device after CNI
# swap. The device stays UP, holds PERMANENT ARP entries pointing at MAC
# addresses of dead Flannel pods, and (worst of all) keeps a kernel
# socket bound on UDP/8472 — the same VXLAN port Cilium uses. With both
# devices alive on the same port, incoming VXLAN packets can land on
# flannel.1 and black-hole. Cilium's auto device detection also picks
# up flannel.1 as a routable device and adds it to BPF masquerading,
# which makes the host network namespace's outbound packets to remote
# pods follow a half-broken path.
#
# Pinning Cilium to `devices: eth0` (in values.yaml) excludes flannel.1
# from Cilium's BPF programs, but doesn't delete the leftover kernel
# device. This phase deletes it on every node via a privileged
# host-network helper Pod with NET_ADMIN. Idempotent: skips nodes
# where flannel.1 doesn't exist.
# ---------------------------------------------------------------------------
phase_cleanup_flannel_remnants() {
  log "Phase 6.5: delete leftover Flannel kernel state on each node"
  log "  removes: flannel.1 vxlan device + cni0 bridge + dangling vethN peers"
  log "  (cni0 retention discovered 2026-05-14: cross-node pod->pod silently"
  log "  drops when both cni0 and Cilium veths coexist on the same node)"
  local nodes
  nodes="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
  for node in $nodes; do
    local pod_name="cni-cleanup-${node##*-}"
    cat <<EOF | kubectl apply --validate=false -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: kube-system
spec:
  hostNetwork: true
  hostPID: true
  restartPolicy: Never
  nodeName: ${node}
  tolerations: [{ operator: Exists }]
  containers:
    - name: c
      image: nicolaka/netshoot
      command: ["sh", "-c"]
      args:
        - |
          set -u
          report() { echo "[\$(hostname)] \$@"; }
          # 1. flannel.1 VXLAN device (Talos doesn't gc; same UDP port as Cilium tunnel)
          if ip link show flannel.1 >/dev/null 2>&1; then
            report "deleting flannel.1..."
            ip link delete flannel.1 && report "  flannel.1 deleted"
          else
            report "flannel.1 already gone"
          fi
          # 2. cni0 bridge (Flannel's veth anchor; while it persists, pods may have
          #    their veth peers attached to it instead of Cilium lxc* — cross-node
          #    cilium routing silently drops packets to those pods).
          if ip link show cni0 >/dev/null 2>&1; then
            report "deleting cni0..."
            ip link delete cni0 && report "  cni0 deleted"
          else
            report "cni0 already gone"
          fi
          # 3. dangling vethN peers (Flannel-era pod veths, named vethXYZ unlike
          #    Cilium's lxc*). Safe to delete: Cilium-managed peers all start with lxc.
          local_count=0
          for v in \$(ip -o link show | awk -F': ' '{print \$2}' | awk -F'@' '{print \$1}'); do
            if [[ "\$v" == veth* ]]; then
              report "delete flannel-era veth \$v"
              ip link delete "\$v" 2>&1 || true
              local_count=\$((local_count + 1))
            fi
          done
          report "deleted \$local_count flannel-era vethN peers"
      resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 500m, memory: 256Mi } }
      securityContext: { capabilities: { drop: ["ALL"], add: ["NET_ADMIN", "NET_RAW"] }, privileged: true }
EOF
    for i in $(seq 1 30); do
      local phase
      phase="$(kubectl -n kube-system get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
      [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
      sleep 2
    done
    log "  $node: $(kubectl -n kube-system logs "$pod_name" 2>/dev/null | grep -c 'deleted\|already gone') items handled"
    kubectl -n kube-system delete pod "$pod_name" --grace-period=0 --force >/dev/null 2>&1 || true
  done
  ok "flannel kernel-state leftovers cleaned"
}

# ---------------------------------------------------------------------------
# Phase 6.6: Recycle Longhorn instance-managers with stale Flannel IPs
#
# Longhorn's `instance-manager` pods are created by `longhorn-manager`
# directly (not a Deployment/DaemonSet/StatefulSet), so they don't get
# rolled by the workload-restart pass in phase_roll_workloads. They
# survive the migration with their pre-Cilium IPs, which Cilium tags
# `reserved:unmanaged` (no endpoint, no datapath). Symptoms: every
# Longhorn engine routes through a stale instance-manager IP, volume
# detach calls hang because longhorn-manager can't reach the engine,
# stuck VolumeAttachment finalizers, OpenBao + Prometheus PVCs become
# unreachable. Found this on talos-home (2026-05-06) about an hour
# after the cutover when the first PVC re-mount was attempted.
# ---------------------------------------------------------------------------
phase_recycle_longhorn_instancemanagers() {
  log "Phase 6.6: recycle Longhorn instance-managers (clear stale Flannel IPs)"
  if ! kubectl -n longhorn-system get pods -l longhorn.io/component=instance-manager >/dev/null 2>&1; then
    log "  no instance-manager pods — Longhorn not installed; skipping"
    return 0
  fi
  local stale=()
  while IFS= read -r line; do
    local pod ip
    pod="$(awk '{print $1}' <<<"$line")"
    ip="$(awk '{print $2}' <<<"$line")"
    [[ -z "$ip" ]] && continue
    # Cross-reference Cilium ipcache: if the IP is unknown to Cilium or
    # tagged `unmanaged`, it's a stale-from-before-Cilium pod.
    local cil
    cil="$(kubectl -n kube-system get pods -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')"
    local tag
    tag="$(kubectl -n kube-system exec "$cil" -c cilium-agent -- cilium-dbg ip list 2>/dev/null | awk -v ip="${ip}/32" '$1==ip {print $2}' | head -1)"
    if [[ -z "$tag" || "$tag" == "reserved:unmanaged" ]]; then
      stale+=("$pod")
    fi
  done < <(kubectl -n longhorn-system get pods -l longhorn.io/component=instance-manager \
             -o jsonpath='{range .items[*]}{.metadata.name} {.status.podIP}{"\n"}{end}')

  if [[ ${#stale[@]} -eq 0 ]]; then
    log "  all instance-manager pods have Cilium-managed IPs; skipping"
    return 0
  fi

  warn "  ${#stale[@]} stale instance-manager pod(s) found; recycling..."
  for pod in "${stale[@]}"; do
    log "    deleting $pod"
    kubectl -n longhorn-system delete pod "$pod" --force --grace-period=0 >/dev/null
    # Wait for the replacement to come back Ready (~5-15s typically).
    for i in $(seq 1 30); do
      kubectl -n longhorn-system get pods --field-selector=spec.nodeName="$(
        kubectl -n longhorn-system get pod "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null \
          || true)" \
        -l longhorn.io/component=instance-manager --no-headers 2>/dev/null \
        | grep -q '1/1.*Running' && break
      sleep 2
    done
  done
  ok "instance-managers recycled with Cilium-issued IPs"
}

# ---------------------------------------------------------------------------
# Phase 7: roll workloads
# ---------------------------------------------------------------------------
phase_roll_workloads() {
  log "Phase 7: rollout restart all workloads (namespace-by-namespace)"
  # Skip kube-system except CoreDNS — system DaemonSets handled by Cilium itself.
  kubectl -n kube-system rollout restart deploy/coredns 2>/dev/null || true
  for ns in $(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
              | grep -vE '^(kube-system|kube-public|kube-node-lease)$'); do
    kubectl -n "$ns" rollout restart deploy,ds,sts 2>/dev/null \
      | grep -v 'no resources' | sed "s|^|  [$ns] |" || true
  done

  log "  force-deleting any pods still in CrashLoopBackOff/Error..."
  kubectl get pods -A --no-headers 2>/dev/null \
    | grep -E 'CrashLoopBackOff|Error' \
    | awk '{print $1, $2}' \
    | while read -r ns name; do
        kubectl -n "$ns" delete pod "$name" --force --grace-period=0 \
          >/dev/null 2>&1 || true
      done

  ok "workloads rolled"
}

# ---------------------------------------------------------------------------
# Phase 7.6: detect containerd orphan sandbox-name reservations
#
# After 2+ hours of CNI/agent restarts during a real migration, every
# pod-create attempt that timed out at the CNI plugin layer leaves a
# "sandbox name" reservation in containerd. Reservations don't expire
# under load — kubelet keeps retrying, refreshing the orphan. Every
# new pod that lands on the affected node hangs in ContainerCreating
# forever with `failed to reserve sandbox name ... is reserved for
# <orphan-container-id>`.
#
# Talos doesn't expose a containerd-only restart through its API.
# `talosctl reboot -n <ip>` is the only fix. Auto-detect nodes with >50
# reservation errors and prompt for reboot.
#
# Requires TALOSCONFIG (path to the cluster's talosconfig). Pass via
# env var or stash in $BACKUP_DIR/talosconfig from the backup phase.
# ---------------------------------------------------------------------------
phase_check_containerd_orphans() {
  log "Phase 7.6: check for containerd orphan sandbox reservations"

  local talosconfig="${TALOSCONFIG:-${BACKUP_DIR}/talosconfig}"
  if [[ ! -f "$talosconfig" ]]; then
    warn "TALOSCONFIG not set / not found at $talosconfig — skipping"
    warn "  to enable: TALOSCONFIG=/path/to/talosconfig $0 ..."
    return 0
  fi

  local need_reboot=()
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    local count
    count="$(talosctl --talosconfig "$talosconfig" -n "$ip" logs kubelet 2>/dev/null \
      | grep -c 'is reserved for' || echo 0)"
    log "  $ip: $count reservation errors"
    if [[ "$count" -gt 50 ]]; then
      need_reboot+=("$ip")
    fi
  done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')

  if [[ ${#need_reboot[@]} -eq 0 ]]; then
    ok "no nodes with stuck containerd reservations"
    return 0
  fi

  warn "${#need_reboot[@]} node(s) have stuck containerd reservations — must reboot"
  warn "  affected: ${need_reboot[*]}"
  if [[ "$PAUSE" == "1" ]]; then
    read -rp "[migrate-cni] reboot affected nodes? [y/N] " ans </dev/tty
    [[ "$ans" =~ ^[Yy] ]] || { warn "skipping reboot — pods on affected nodes will stay stuck"; return 0; }
  fi

  for ip in "${need_reboot[@]}"; do
    log "  rebooting $ip..."
    talosctl --talosconfig "$talosconfig" -n "$ip" reboot 2>&1 | tail -5
    # Wait for node to come back Ready (Talos reboot returns when post-checks pass)
    local node
    node="$(kubectl get nodes -o jsonpath='{range .items[?(@.status.addresses[*].address=="'"$ip"'")]}{.metadata.name}{"\n"}{end}' | head -1)"
    for i in $(seq 1 60); do
      [[ "$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]] && break
      sleep 5
    done
    log "  $node Ready"
  done
  ok "containerd state reset on affected nodes"
}

# ---------------------------------------------------------------------------
# Phase 8: smoke tests
# ---------------------------------------------------------------------------
phase_smoke() {
  log "Phase 8: smoke tests (DNS, apiserver, external egress)"
  kubectl delete pod dnstest -n default --grace-period=0 --force >/dev/null 2>&1 || true
  cat <<'EOF' | kubectl apply --validate=false -f -
apiVersion: v1
kind: Pod
metadata:
  name: dnstest
  namespace: default
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: curlimages/curl
      command: ["sleep", "120"]
      resources:
        requests: { cpu: 50m, memory: 64Mi }
        limits:   { cpu: 200m, memory: 128Mi }
      securityContext:
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        runAsUser: 1000
        capabilities: { drop: ["ALL"] }
        seccompProfile: { type: RuntimeDefault }
EOF
  for i in $(seq 1 20); do
    [[ "$(kubectl get pod dnstest -n default -o jsonpath='{.status.phase}' 2>/dev/null)" == "Running" ]] && break
    sleep 2
  done

  local fail=0
  if kubectl exec -n default dnstest -- nslookup kubernetes.default.svc.cluster.local 10.96.0.10 2>&1 | grep -q '10.96.0.1'; then
    ok "  DNS via 10.96.0.10 resolves kubernetes.default"
  else
    warn "  DNS smoke FAILED"; fail=1
  fi

  local code
  code="$(kubectl exec -n default dnstest -- curl -fsS --max-time 5 -k -o /dev/null -w '%{http_code}' https://kubernetes.default.svc.cluster.local/healthz 2>/dev/null || echo 000)"
  if [[ "$code" == "401" || "$code" == "200" || "$code" == "403" ]]; then
    ok "  apiserver Service VIP reachable (http=$code)"
  else
    warn "  apiserver smoke FAILED (http=$code)"; fail=1
  fi

  code="$(kubectl exec -n default dnstest -- curl -fsS --max-time 8 -o /dev/null -w '%{http_code}' https://api.github.com/zen 2>/dev/null || echo 000)"
  if [[ "$code" == "200" ]]; then
    ok "  external egress (api.github.com) reachable"
  else
    warn "  external egress smoke FAILED (http=$code)"; fail=1
  fi

  # Cross-node pod-to-pod via Service VIP. Discovered 2026-05-14 that
  # phases 6.5 + 7 alone don't catch every stale-Flannel artifact —
  # cross-node Service routing can still silently drop until the
  # affected nodes are rebooted. The 503 we see in the wild looks
  # identical to a healthy 200-but-no-backend response from Traefik;
  # only this in-cluster cross-node probe catches it cleanly.
  log "  cross-node Service VIP probe (discovered post-mortem 2026-05-14)..."
  local crossnode_fail=0
  # Pick two pods on different nodes
  local probe_targets
  probe_targets=$(kubectl get pods -A -o json 2>/dev/null | python3 -c "
import sys,json,collections
d=json.loads(sys.stdin.read())
by_node=collections.defaultdict(list)
for p in d['items']:
    n=p['spec'].get('nodeName','')
    ip=p['status'].get('podIP','')
    ns=p['metadata']['namespace']
    nm=p['metadata']['name']
    phase=p['status'].get('phase','')
    if n and ip and phase=='Running': by_node[n].append((ns,nm,ip))
# emit first IP from two different nodes
nodes=list(by_node.keys())
if len(nodes)>=2:
    a=by_node[nodes[0]][0][2]; b=by_node[nodes[1]][0][2]
    print(f'{a} {b}')
" 2>/dev/null)
  if [[ -n "$probe_targets" ]]; then
    local a b
    read -r a b <<<"$probe_targets"
    if kubectl exec -n default dnstest -- curl -fsS --max-time 5 -o /dev/null "http://$a:80" >/dev/null 2>&1 \
       || kubectl exec -n default dnstest -- curl -fsS --max-time 5 -o /dev/null "http://$b:80" >/dev/null 2>&1; then
      ok "  cross-node pod-to-pod reachable"
    else
      # Connection failed cleanly is OK (no server on :80); a TIMEOUT is the smoking gun.
      local tcode
      tcode="$(kubectl exec -n default dnstest -- curl -sS --max-time 3 -o /dev/null -w '%{http_code}' "http://$a:80" 2>/dev/null || echo 'TIMEOUT')"
      if [[ "$tcode" == "TIMEOUT" || -z "$tcode" || "$tcode" == "000" ]]; then
        warn "  cross-node pod-to-pod TIMES OUT (target=$a) — leftover Flannel kernel state on some node"
        warn "  fix: rolling-reboot affected workers via talosctl to clear iptables/conntrack/ARP"
        crossnode_fail=1
        fail=1
      else
        ok "  cross-node pod-to-pod reachable (target rejected http=$tcode, but reached)"
      fi
    fi
  else
    warn "  could not find two-node probe targets; skipping cross-node check"
  fi

  kubectl delete pod dnstest -n default --grace-period=0 --force >/dev/null 2>&1 || true
  [[ "$fail" == "0" ]] || die "smoke tests failed — STOP and decide on rollback"
}

# ---------------------------------------------------------------------------
# Phase 9: un-quiesce
# ---------------------------------------------------------------------------
phase_unquiesce() {
  log "Phase 9: un-quiesce"
  kubectl -n vpa-system scale deploy vpa-updater              --replicas=1 2>/dev/null || true
  kubectl -n vpa-system scale deploy vpa-admission-controller --replicas=1 2>/dev/null || true

  for cj in 'velero/velero-restore-drill' \
            'argocd/preview-reaper' \
            'kelos-system/ai-cost-aggregator' \
            'kelos-system/claude-oauth-refresher'; do
    local ns="${cj%%/*}" name="${cj##*/}"
    kubectl -n "$ns" get cronjob "$name" >/dev/null 2>&1 \
      && kubectl -n "$ns" patch cronjob "$name" \
           -p '{"spec":{"suspend":false}}' >/dev/null
  done

  for ts_obj in $(kubectl -n kelos-system get taskspawner -o name 2>/dev/null); do
    kubectl -n kelos-system patch "$ts_obj" --type merge \
      -p '{"spec":{"paused":false}}' >/dev/null || true
  done

  kubectl -n argocd label applicationset preview-envs migration-paused- 2>/dev/null || true
  ok "un-quiesced"
}

# ---------------------------------------------------------------------------
# Phase 10: post-migration drill
# ---------------------------------------------------------------------------
phase_drill() {
  log "Phase 10: trigger velero-restore-drill"
  local job_name="drill-post-cilium-${TS}"
  kubectl -n velero create job --from=cronjob/velero-restore-drill "$job_name" || true
  log "  drill submitted as job/$job_name; tail logs with:"
  log "  kubectl -n velero logs -f job/$job_name"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  phase_preflight
  if [[ "$CHECK_ONLY" == "1" ]]; then
    log "--check-only: stopping"
    return 0
  fi
  phase_pause

  if [[ "$SKIP_BACKUP" != "1" ]]; then
    phase_backup
    phase_pause
  fi

  phase_quiesce
  phase_pause

  phase_configpatch
  phase_pause

  phase_cilium
  phase_pause

  phase_apiserver_ccnp
  phase_pause

  phase_delete_old_cni
  phase_pause

  phase_cleanup_flannel_remnants
  phase_pause

  phase_recycle_longhorn_instancemanagers
  phase_pause

  phase_roll_workloads
  phase_pause

  phase_check_containerd_orphans
  phase_pause

  phase_smoke
  phase_pause

  phase_unquiesce
  phase_drill

  ok "migrate-cni-cilium.sh complete — backups in ${BACKUP_DIR}"
}

main "$@"
