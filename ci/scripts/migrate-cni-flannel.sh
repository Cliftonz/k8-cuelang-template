#!/usr/bin/env bash
# Migrate the home cluster from Cilium back to Flannel + stock kube-proxy.
#
# This is the REVERSE of ci/scripts/migrate-cni-cilium.sh. See
# docs/cni-revert-to-flannel.md for the decision rationale and the full
# operator runbook.
#
# Phases:
#   0   preflight  — kubectl/talosctl/omnictl/helm/jq + free space for backups
#   1   backup     — Velero on-demand + OpenBao snapshot + Talos etcd snapshot
#   2   quiesce    — scale VPA down, suspend cronjobs, pause kelos taskspawners,
#                    label preview-envs ApplicationSet migration-paused
#   3   configpatch — DELETE the cilium-cni ConfigPatch in Omni so Talos
#                     defaults take over (cni.name=flannel + proxy.disabled=false).
#                     This DOES NOT REBOOT — Phase 4 is operator-driven.
#   4   rolling-reboot — OPERATOR step: rolling reboot of workers via Omni so
#                     Talos picks up the new config and installs Flannel +
#                     kube-proxy DaemonSets. This phase has automation to
#                     drain/cordon/uncordon, but the actual reboot is via Omni.
#   5   teardown    — helm uninstall cilium, delete CCNPs, delete CRDs once
#                     all workers are on the new config
#   6   cleanup-kernel — symmetric to forward Phase 6.5: delete cilium_* devices,
#                     lxc* veths, BPF leftovers on each node. Often a no-op if
#                     Phase 4 was clean reboots.
#   7   workload-roll — rollout restart every workload so it gets a Flannel-issued
#                     IP and stock kube-proxy NAT rules
#   8   smoke      — DNS, pod->apiserver, cross-node Service VIP, ingress through
#                    Traefik, external egress. STOP if any fail.
#   9   unquiesce  — undo Phase 2
#  10   (manual)   — `git rm infrastructure/cilium/` + clean bootstrap-home.sh
#
# Rollback: until Phase 5 is complete, re-applying the cilium-cni ConfigPatch
# via Omni puts the cluster back on Cilium with no code-side changes. After
# Phase 5, rollback = re-run migrate-cni-cilium.sh from scratch.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)/.."
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

OMNI_CLUSTER="${OMNI_CLUSTER:-talos-home}"
BACKUP_DIR="${BACKUP_DIR:-/tmp/cni-revert-$(date +%Y%m%d-%H%M%S)}"
PAUSE_BETWEEN_PHASES="${PAUSE_BETWEEN_PHASES:-1}"   # set to 0 for unattended

GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
log()   { printf "%s[migrate]%s %s\n"  "$GREEN"  "$NC" "$*"; }
warn()  { printf "%s[migrate]%s %s\n"  "$YELLOW" "$NC" "$*"; }
die()   { printf "%s[migrate FAIL]%s %s\n" "$RED" "$NC" "$*" >&2; exit 1; }
ok()    { printf "%s[migrate OK]%s   %s\n" "$GREEN" "$NC" "$*"; }

phase_pause() {
  [[ "$PAUSE_BETWEEN_PHASES" == "1" ]] || return 0
  printf "%s[pause]%s Verify ^ before continuing. Press Enter to proceed, Ctrl-C to abort.\n" "$YELLOW" "$NC"
  read -r _
}

# ---------------------------------------------------------------------------
# Phase 0: preflight
# ---------------------------------------------------------------------------
phase_preflight() {
  log "Phase 0: preflight"
  local missing=0
  for bin in kubectl helm omnictl talosctl jq; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      warn "missing tool: $bin"
      missing=1
    fi
  done
  [[ "$missing" == "1" ]] && die "install missing tools first"

  kubectl version --request-timeout=5s >/dev/null 2>&1 || die "kubectl can't reach the cluster"

  # Sanity check: we're actually on Cilium right now (no point reverting otherwise).
  if ! kubectl -n kube-system get daemonset cilium >/dev/null 2>&1; then
    die "no cilium DaemonSet in kube-system — cluster may already be on Flannel"
  fi

  # Sanity check: the Cilium ConfigPatch we'd delete still exists.
  local patch_id="100-cilium-cni-${OMNI_CLUSTER}"
  if ! omnictl get ConfigPatches.omni.sidero.dev "$patch_id" >/dev/null 2>&1; then
    warn "Omni ConfigPatch $patch_id not found — Phase 3 will be a no-op"
  fi

  mkdir -p "$BACKUP_DIR"
  ok "preflight green, backup dir = $BACKUP_DIR"
}

# ---------------------------------------------------------------------------
# Phase 1: three-layer backup
# ---------------------------------------------------------------------------
phase_backup() {
  log "Phase 1: backup (Velero on-demand + OpenBao snapshot + Talos etcd snapshot)"

  # Velero on-demand
  if command -v velero >/dev/null 2>&1; then
    local backup_name="cni-revert-$(date +%Y%m%d-%H%M%S)"
    velero backup create "$backup_name" --include-namespaces='*' --wait
    velero backup describe "$backup_name" --details > "$BACKUP_DIR/velero-${backup_name}.txt"
    ok "velero backup $backup_name complete"
  else
    warn "velero CLI not found — skipping app-state backup. Stop now if this is unintended."
  fi

  # OpenBao snapshot (raw filestore copy via exec)
  if kubectl -n openbao get pod openbao-0 >/dev/null 2>&1; then
    kubectl exec -n openbao openbao-0 -- tar czf - /openbao/data 2>/dev/null \
      > "$BACKUP_DIR/openbao-data.tgz" || warn "openbao snapshot failed (sealed?)"
    ok "openbao data snapshot: $BACKUP_DIR/openbao-data.tgz"
  else
    warn "openbao-0 pod not found — skipping openbao snapshot"
  fi

  # Talos etcd snapshot via talosctl
  local cp_node
  cp_node="$(kubectl get nodes -l node-role.kubernetes.io/control-plane= -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
  if [[ -n "$cp_node" ]]; then
    talosctl --nodes "$cp_node" etcd snapshot "$BACKUP_DIR/etcd.db" 2>/dev/null \
      && ok "etcd snapshot: $BACKUP_DIR/etcd.db" \
      || warn "etcd snapshot failed (talosctl auth?). Continue at your own risk."
  else
    warn "no control-plane node IP detected — skipping etcd snapshot"
  fi

  ok "Phase 1 complete (best-effort) — review $BACKUP_DIR before proceeding"
}

# ---------------------------------------------------------------------------
# Phase 2: quiesce
# ---------------------------------------------------------------------------
phase_quiesce() {
  log "Phase 2: quiesce moving parts so they don't churn pods during the reboot cycle"

  kubectl -n vpa-system scale deploy vpa-updater              --replicas=0 2>/dev/null || true
  kubectl -n vpa-system scale deploy vpa-admission-controller --replicas=0 2>/dev/null || true

  for cj in 'velero/velero-restore-drill' \
            'argocd/preview-reaper' \
            'kelos-system/ai-cost-aggregator' \
            'kelos-system/claude-oauth-refresher' \
            'argo-events/argo-sensor-error-watchdog' \
            'kube-system/openbao-readonly-watchdog'; do
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

  ok "quiesced — kelos paused, ApplicationSet paused, CronJobs suspended"
}

# ---------------------------------------------------------------------------
# Phase 3: delete the Cilium ConfigPatch in Omni
#
# Talos applies CNI choice at boot, so this is a no-op until Phase 4 reboots.
# But removing it now means any subsequent node boot picks up the default
# config (cni.name=flannel + kube-proxy enabled) automatically.
# ---------------------------------------------------------------------------
phase_configpatch() {
  log "Phase 3: remove Cilium ConfigPatch from Omni (default Talos CNI/kube-proxy will take over on reboot)"
  local patch_id="100-cilium-cni-${OMNI_CLUSTER}"
  if omnictl get ConfigPatches.omni.sidero.dev "$patch_id" >/dev/null 2>&1; then
    omnictl delete ConfigPatches.omni.sidero.dev "$patch_id"
    ok "deleted ConfigPatch $patch_id from Omni"
  else
    warn "$patch_id not present — assuming already removed"
  fi
  # Defensive: also try the legacy id if anyone applied via the bare file.
  for legacy in "cilium-cni" "100-cilium-cni"; do
    omnictl delete ConfigPatches.omni.sidero.dev "$legacy" 2>/dev/null && warn "also deleted legacy $legacy"
  done
}

# ---------------------------------------------------------------------------
# Phase 4: rolling reboot of workers
#
# Operator-driven via Omni UI (or omnictl if you prefer). This script
# automates the cordon/drain/uncordon dance and waits for each node to
# come back Ready before moving on.
# ---------------------------------------------------------------------------
phase_rolling_reboot() {
  log "Phase 4: rolling reboot. THIS IS OPERATOR-DRIVEN — reboot each node via Omni when prompted."

  # Get worker nodes in a stable order. Control plane goes LAST.
  local workers
  workers="$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
  local cp
  cp="$(kubectl get nodes -l 'node-role.kubernetes.io/control-plane' \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"

  local nodes
  nodes="$workers"$'\n'"$cp"

  for node in $nodes; do
    [[ -z "$node" ]] && continue
    log "--- $node ---"
    kubectl cordon "$node"
    kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=120s \
      --skip-wait-for-delete-timeout=30 || warn "drain partial — proceeding"

    warn "OPERATOR ACTION: reboot $node via Omni now (Machines → $node → Reboot)."
    warn "  Press Enter once the Omni reboot is INITIATED. The script will then wait for $node to come back Ready."
    read -r _

    log "waiting for $node to become Ready..."
    local tries=0
    while [[ $tries -lt 120 ]]; do
      local status
      status="$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
      if [[ "$status" == "True" ]]; then
        ok "$node Ready"
        break
      fi
      sleep 5
      tries=$((tries + 1))
    done
    [[ $tries -ge 120 ]] && die "$node did not become Ready within 10 minutes — investigate before continuing"

    # Wait for flannel + kube-proxy DaemonSets to schedule a pod on this node.
    log "waiting for kube-flannel + kube-proxy on $node..."
    tries=0
    while [[ $tries -lt 60 ]]; do
      local flannel kp
      flannel="$(kubectl -n kube-system get pods -l app=flannel -o jsonpath="{.items[?(@.spec.nodeName=='${node}')].status.phase}" 2>/dev/null || true)"
      kp="$(kubectl -n kube-system get pods -l k8s-app=kube-proxy -o jsonpath="{.items[?(@.spec.nodeName=='${node}')].status.phase}" 2>/dev/null || true)"
      if [[ "$flannel" == "Running" && "$kp" == "Running" ]]; then
        ok "$node has Running flannel + kube-proxy"
        break
      fi
      sleep 5
      tries=$((tries + 1))
    done
    [[ $tries -ge 60 ]] && warn "$node: flannel/kube-proxy not Running after 5 min — investigate but proceed"

    kubectl uncordon "$node"
    ok "$node back in service"

    # Pause between nodes to let workloads stabilize before the next reboot.
    if [[ "$PAUSE_BETWEEN_PHASES" == "1" ]]; then
      log "Pause 30s to let workloads stabilize..."
      sleep 30
    fi
  done

  ok "all nodes rebooted to default (Flannel) CNI"
}

# ---------------------------------------------------------------------------
# Phase 5: teardown Cilium
# ---------------------------------------------------------------------------
phase_teardown() {
  log "Phase 5: tear down Cilium (helm uninstall + CCNPs + CRDs)"

  # Sanity: every worker should be on Flannel by now.
  local on_cilium=0
  for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
    # if a node still has a Running cilium-agent pod owned by the DaemonSet, we'd hit Cilium policy
    if kubectl -n kube-system get pods -l k8s-app=cilium --field-selector=status.phase=Running -o name 2>/dev/null | grep -q .; then
      :  # check inverted below
    fi
  done
  if [[ $(kubectl -n kube-system get pods -l k8s-app=cilium --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l) -gt 0 ]] && \
     [[ $(kubectl -n kube-system get pods -l app=flannel --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l) -lt $(kubectl get nodes --no-headers | wc -l) ]]; then
    die "Phase 4 not complete — some nodes still on Cilium. Roll those first."
  fi

  log "  helm uninstall cilium..."
  helm uninstall cilium -n kube-system 2>&1 | tail -5 || warn "helm uninstall failed; will keep going"

  log "  delete CCNPs (allow-egress-to-kube-apiserver, allow-ingress-from-host)..."
  kubectl delete ciliumclusterwidenetworkpolicy allow-egress-to-kube-apiserver 2>/dev/null || true
  kubectl delete ciliumclusterwidenetworkpolicy allow-ingress-from-host        2>/dev/null || true

  log "  delete Cilium CRDs (this also GCs any remaining BPF map references)..."
  local crds=$(kubectl get crd -o name 2>/dev/null | grep -E '\.cilium\.io$' || true)
  if [[ -n "$crds" ]]; then
    echo "$crds" | xargs kubectl delete --ignore-not-found
  fi

  ok "Cilium teardown complete"
}

# ---------------------------------------------------------------------------
# Phase 6: kernel state cleanup
#
# Symmetric to forward Phase 6.5: delete cilium_* devices, lxc* veths,
# stale iptables/BPF leftovers. Usually a no-op if Phase 4 was clean
# reboots (reboot wipes kernel state). Idempotent.
# ---------------------------------------------------------------------------
phase_cleanup_kernel() {
  log "Phase 6: clean up Cilium kernel state on each node (cilium_* devices, lxc* veths, BPF maps)"
  log "  (idempotent — most nodes already clean post-reboot)"

  local nodes
  nodes="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
  for node in $nodes; do
    local pod_name="cilium-cleanup-${node##*-}"
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

          # 1. cilium_* devices (host, vxlan, geneve, health, net).
          for dev in cilium_host cilium_net cilium_vxlan cilium_geneve cilium_health; do
            if ip link show "\$dev" >/dev/null 2>&1; then
              report "deleting \$dev"
              ip link delete "\$dev" 2>&1 || true
            fi
          done

          # 2. lxc* veth peers (Cilium-managed). Safe — Flannel uses vethN.
          local_count=0
          for v in \$(ip -o link show | awk -F': ' '{print \$2}' | awk -F'@' '{print \$1}'); do
            if [[ "\$v" == lxc* ]]; then
              report "delete cilium-era \$v"
              ip link delete "\$v" 2>&1 || true
              local_count=\$((local_count + 1))
            fi
          done
          report "deleted \$local_count cilium-era lxc* peers"

          # 3. BPF maps. Cilium pins under /sys/fs/bpf/tc/globals/.
          if [[ -d /sys/fs/bpf/tc/globals ]]; then
            for f in /sys/fs/bpf/tc/globals/cilium_*; do
              [[ -e "\$f" ]] && rm -rf "\$f" && report "unpinned \$f"
            done
          fi

          # 4. iptables/nftables rules tagged with cilium. Flannel + kube-proxy
          #    install fresh chains; we just need to clear ours.
          if command -v iptables-save >/dev/null 2>&1; then
            iptables-save | grep -c -i cilium 2>/dev/null && \
              iptables-save | grep -v -i cilium | iptables-restore || true
          fi
      resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 500m, memory: 256Mi } }
      securityContext: { capabilities: { drop: ["ALL"], add: ["NET_ADMIN", "NET_RAW"] }, privileged: true }
EOF
    for i in $(seq 1 30); do
      local phase
      phase="$(kubectl -n kube-system get pod "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
      [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
      sleep 2
    done
    log "  $node: $(kubectl -n kube-system logs "$pod_name" 2>/dev/null | grep -c -E 'deleted|unpinned' || echo 0) items cleaned"
    kubectl -n kube-system delete pod "$pod_name" --grace-period=0 --force >/dev/null 2>&1 || true
  done

  ok "cilium kernel-state cleanup complete"
}

# ---------------------------------------------------------------------------
# Phase 7: rollout restart workloads
# ---------------------------------------------------------------------------
phase_workload_roll() {
  log "Phase 7: rollout restart workloads so they get Flannel-issued IPs"

  # Skip kube-system DaemonSets — those are stable and already on the new CNI from Phase 4.
  local namespaces
  namespaces="$(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    | grep -v -E '^(kube-system|kube-public|kube-node-lease)$')"

  for ns in $namespaces; do
    for kind in deployment statefulset daemonset; do
      local objs
      objs="$(kubectl -n "$ns" get "$kind" -o name 2>/dev/null || true)"
      [[ -z "$objs" ]] && continue
      log "  $ns: rolling $kind..."
      echo "$objs" | xargs -r kubectl -n "$ns" rollout restart >/dev/null 2>&1 || true
    done
  done

  # Longhorn instance-managers: same trick as forward Phase 6.6.
  log "  bouncing Longhorn instance-managers (not Deployment-owned)..."
  kubectl -n longhorn-system delete pod -l longhorn.io/component=instance-manager 2>/dev/null || true

  ok "workload rollout triggered (give 5-10 min for cluster to converge)"
}

# ---------------------------------------------------------------------------
# Phase 8: smoke tests
# ---------------------------------------------------------------------------
phase_smoke() {
  log "Phase 8: smoke tests (DNS, pod→apiserver, cross-node Service VIP, ingress)"

  local fail=0

  log "  test 1: in-cluster DNS resolution..."
  kubectl run dns-test --rm -i --restart=Never -n default --image=busybox:1.36 \
    --command -- nslookup kubernetes.default >/dev/null 2>&1 \
    && ok "    DNS OK" \
    || { warn "    DNS FAIL"; fail=1; }

  log "  test 2: pod → apiserver Service VIP..."
  kubectl run api-test --rm -i --restart=Never -n default --image=curlimages/curl:8.10.0 \
    --command -- curl -ksI --max-time 5 https://kubernetes.default.svc/healthz >/dev/null 2>&1 \
    && ok "    apiserver Service OK" \
    || { warn "    apiserver Service FAIL"; fail=1; }

  log "  test 3: cross-node pod→pod (this is the one that catches stale kernel state)..."
  # Find two pods on different nodes and exec a curl/wget between them.
  local pod_pairs
  pod_pairs="$(kubectl get pods -A -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.namespace}/{.metadata.name}/{.spec.nodeName}/{.status.podIP}{"\n"}{end}' \
    | awk -F/ '$4!=""' | head -20)"
  local src=$(echo "$pod_pairs" | head -1)
  local dst=$(echo "$pod_pairs" | awk -F/ -v src_node="$(echo "$src" | cut -d/ -f3)" '$3 != src_node' | head -1)
  if [[ -n "$src" && -n "$dst" ]]; then
    local src_ns=$(echo "$src" | cut -d/ -f1)
    local src_pod=$(echo "$src" | cut -d/ -f2)
    local dst_ip=$(echo "$dst" | cut -d/ -f4)
    if kubectl -n "$src_ns" exec "$src_pod" -- timeout 5 sh -c "ping -c 1 -W 3 $dst_ip" >/dev/null 2>&1; then
      ok "    cross-node ping $src → $dst_ip OK"
    else
      warn "    cross-node ping $src → $dst_ip FAIL"; fail=1
    fi
  else
    warn "    couldn't find two Running pods on different nodes for cross-node test"
  fi

  log "  test 4: traefik ingress alive..."
  kubectl -n traefik get pods -l app.kubernetes.io/name=traefik --field-selector=status.phase=Running -o name 2>/dev/null | grep -q . \
    && ok "    Traefik Running" \
    || { warn "    Traefik FAIL"; fail=1; }

  log "  test 5: cilium DaemonSet is GONE..."
  if kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
    warn "    cilium DaemonSet still present — Phase 5 didn't fully tear down"; fail=1
  else
    ok "    cilium DaemonSet absent"
  fi

  if [[ "$fail" == "1" ]]; then
    die "smoke tests failed — investigate before unquiesce"
  fi
  ok "smoke tests green"
}

# ---------------------------------------------------------------------------
# Phase 9: un-quiesce
# ---------------------------------------------------------------------------
phase_unquiesce() {
  log "Phase 9: un-quiesce (reverse of Phase 2)"

  kubectl -n vpa-system scale deploy vpa-updater              --replicas=1 2>/dev/null || true
  kubectl -n vpa-system scale deploy vpa-admission-controller --replicas=1 2>/dev/null || true

  for cj in 'velero/velero-restore-drill' \
            'argocd/preview-reaper' \
            'kelos-system/ai-cost-aggregator' \
            'kelos-system/claude-oauth-refresher' \
            'argo-events/argo-sensor-error-watchdog' \
            'kube-system/openbao-readonly-watchdog'; do
    local ns="${cj%%/*}" name="${cj##*/}"
    kubectl -n "$ns" get cronjob "$name" >/dev/null 2>&1 \
      && kubectl -n "$ns" patch cronjob "$name" \
           -p '{"spec":{"suspend":false}}' >/dev/null
  done

  for ts_obj in $(kubectl -n kelos-system get taskspawner -o name 2>/dev/null); do
    kubectl -n kelos-system patch "$ts_obj" --type merge \
      -p '{"spec":{"paused":false}}' >/dev/null || true
  done

  kubectl -n argocd label applicationset preview-envs \
    migration-paused- 2>/dev/null || true

  ok "un-quiesced — full cluster activity resumed"
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
PHASE="${1:-all}"
[[ "$PHASE" == "--phase="* ]] && PHASE="${PHASE#--phase=}"

case "$PHASE" in
  all)              phase_preflight && phase_pause \
                    && phase_backup && phase_pause \
                    && phase_quiesce && phase_pause \
                    && phase_configpatch && phase_pause \
                    && phase_rolling_reboot && phase_pause \
                    && phase_teardown && phase_pause \
                    && phase_cleanup_kernel && phase_pause \
                    && phase_workload_roll && phase_pause \
                    && phase_smoke && phase_pause \
                    && phase_unquiesce
                    ;;
  preflight)        phase_preflight ;;
  backup)           phase_backup ;;
  quiesce)          phase_quiesce ;;
  configpatch)      phase_configpatch ;;
  rolling-reboot)   phase_rolling_reboot ;;
  teardown)         phase_teardown ;;
  cleanup-kernel)   phase_cleanup_kernel ;;
  workload-roll)    phase_workload_roll ;;
  smoke)            phase_smoke ;;
  unquiesce)        phase_unquiesce ;;
  *)                die "unknown phase: $PHASE (use --phase=<name>)" ;;
esac
