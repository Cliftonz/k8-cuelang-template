#!/usr/bin/env bash
# End-to-end bootstrap + smoke test for the home cluster.
#
# Phases (each is a stability gate — phase N+1 only starts once apiserver
# /healthz is calm and the previous phase's resources are Ready):
#   1.   Tool + cluster preflight
#   1.5  kube-apiserver tuning only (Talos+Omni: auto-apply ConfigPatch,
#        wait for apiserver pods to roll with the new mem limit, then
#        wait for /healthz to be green). etcd tuning skipped on single-CP
#        (no peers means heartbeat/election knobs are no-ops).
#   2.   Talos worker data-disk check (u-longhorn volume ready)
#   2.5  Primary CNI. Detects whichever CNI is active (Cilium if
#        installed or staged via the Talos ConfigPatch; Flannel if
#        Talos installed it at bootstrap because no CNI patch was
#        present). To swap CNIs on a live cluster use
#        ci/scripts/migrate-cni-{cilium,flannel}.sh.
#   3.   Install Longhorn (Talos-aware preflight skip) — wait StorageClass
#   3.5  metrics-server (only if kubelet-cert-rotation patch applied)
#   4.   CloudNativePG (only if rendered manifests reference it — home doesn't)
#   5.   Crossplane UXP + provider-helm + provider-kubernetes + functions
#        + ProviderConfigs — wait providers Healthy
#   6.   make validate && make export-cluster CLUSTER=home
#   7.   Apply rendered manifests in dependency order:
#          XRDs → wait Established → Compositions → namespaces → policies
#          → rbac → helm releases → wait Ready → backend XRs → ingresses
#   8.   Wait for core HelmReleases to reach Ready
#   9.   Print next-step instructions (OpenBao seed via reseed.sh, UniFi key)
#
# Between every heavy step kubectl_apply_with_retry retries on transient
# etcd timeouts and pace() waits for /healthz to settle. Designed to run
# on slow (HDD-backed) etcd without losing quorum.
#
# Idempotent: safe to re-run. Each phase no-ops when already applied.
#
# Usage:
#   ./ci/scripts/bootstrap-home.sh                     # run all phases (PAUSED between)
#   ./ci/scripts/bootstrap-home.sh --no-pause          # unattended (no manual gates)
#   ./ci/scripts/bootstrap-home.sh --skip-render       # skip make validate/export/apply
#   ./ci/scripts/bootstrap-home.sh --check-only        # preflight + state checks only
#   ./ci/scripts/bootstrap-home.sh --raw               # Crossplane-free fallback path:
#                                                      # skip Crossplane install, render +
#                                                      # apply clusters/<cluster>-raw/.
#                                                      # See docs/raw-fallback.md.
#
# Default behavior pauses between phases so the operator can verify state
# (kubectl get pods, get xrd, etc.) before triggering the next reconcile
# burst. Pass --no-pause when running unattended (CI, watcher script, etc.)
#
# Environment overrides:
#   SKIP_TALOS_CHECK=1     bypass Talos disk + extension check
#   SKIP_APISERVER_TUNING=1 bypass the apiserver-tuning ConfigPatch (Talos+Omni)
#                          AND skip pace-mode waits — only set if you have
#                          already tuned the apiserver out-of-band
#   BOOTSTRAP_PACE=slow    pause between heavy installs until kube-apiserver
#                          /healthz reports etcd ok. Auto-enabled when the
#                          cluster is NOT Talos+Omni (no machineconfig path
#                          available there). Manually set to force on Talos.
#   OMNI_CLUSTER           Omni cluster name for the ConfigPatch label
#                          (default: talos-${CLUSTER}, e.g. talos-preview)
#   INSTALL_HARBOR=auto|0|1     opt in/out of provider-harbor + harbor XRDs.
#                              auto (default) detects from rendered manifests:
#                              install only if any XHarbor* XRD or harbor
#                              CRD reference is present.
#   INSTALL_EXTRA_RES=auto|0|1 opt in/out of function-extra-resources. auto
#                              (default) detects: install only if any
#                              composition pipeline references it.
#   INSTALL_CNPG=auto|0|1      opt in/out of CloudNativePG operator. auto
#                              (default) detects: install only if any
#                              database XRD or cnpg.io reference is present.
#   LONGHORN_CHART_VERSION=1.7.2
#   CROSSPLANE_CHART_VERSION=2.2.0-up.4
#   HELMRELEASE_WAIT_TIMEOUT=900     (seconds)
#   APISERVER_CALM_TIMEOUT=300       seconds wait_apiserver_calm tolerates
#                                    before warn-and-continue

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLUSTER="home"
CHECK_ONLY=0
SKIP_RENDER=0
# RAW_MODE=1 — Crossplane-free fallback path. Skips Crossplane install +
# XRD/Composition apply; renders and applies clusters/<cluster>-raw/.
# See docs/raw-fallback.md.
RAW_MODE=0
# Default ON: stop between phases so the operator can verify state before
# triggering the next reconcile burst. Pass --no-pause for unattended runs.
PAUSE=1

for arg in "$@"; do
  case "$arg" in
    --check-only)  CHECK_ONLY=1 ;;
    --skip-render) SKIP_RENDER=1 ;;
    --raw)         RAW_MODE=1 ;;
    --pause)       PAUSE=1 ;;
    --no-pause)    PAUSE=0 ;;
    -h|--help)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg" >&2
      exit 2
      ;;
  esac
done

# Pauses between phases for manual inspection. ON by default — pass
# --no-pause for unattended runs (e.g. CI).
phase_pause() {
  [[ "$PAUSE" == "1" ]] || return 0
  printf '\n\033[1;36mPHASE PAUSED — press ENTER to continue, Ctrl-C to abort\033[0m\n'
  read -r _
}

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m⚠\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Phase 1: Tool + cluster preflight
# ---------------------------------------------------------------------------
phase_preflight() {
  log "Phase 1: tool + cluster preflight"

  local required=(kubectl helm cue yq jq)
  local missing=()
  for bin in "${required[@]}"; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  if ((${#missing[@]})); then
    die "Missing required tools: ${missing[*]}"
  fi
  ok "required tools present: ${required[*]}"

  # Optional but recommended for later phases
  command -v talosctl    >/dev/null 2>&1 || warn "talosctl not found — Talos disk check will be skipped"
  command -v cloudflared >/dev/null 2>&1 || warn "cloudflared not found — needed for tunnel phase (brew install cloudflared)"
  command -v bao         >/dev/null 2>&1 || warn "bao CLI not found — needed for seeding secrets (brew install openbao)"
  command -v argocd      >/dev/null 2>&1 || warn "argocd CLI not found — needed to mint CI token"

  kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach cluster — check context"
  ok "kubectl reachable: $(kubectl config current-context)"

  local cue_version
  cue_version="$(cue version | awk '/^cue version/ {print $3; exit}')"
  ok "cue version: ${cue_version} (module pins v0.16.1 — minor skew usually fine)"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# True (rc 0) if the current kubectl context is a Talos cluster managed by
# Omni AND omnictl is logged in for that cluster. Result is cached for the
# rest of the script in IS_TALOS_OMNI.
IS_TALOS_OMNI=""
detect_talos_omni() {
  if [[ -n "$IS_TALOS_OMNI" ]]; then
    [[ "$IS_TALOS_OMNI" == "yes" ]]
    return $?
  fi
  IS_TALOS_OMNI="no"

  command -v omnictl >/dev/null 2>&1 || return 1
  # API server image label is the cleanest probe — Talos kube-apiserver
  # static pods are namespaced under registry.k8s.io but with a Talos
  # build prefix in osImage. Use node osImage instead.
  local os_image
  os_image=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.osImage}' 2>/dev/null)
  [[ "$os_image" == Talos* ]] || return 1

  local omni_cluster="${OMNI_CLUSTER:-talos-${CLUSTER}}"
  omnictl get cluster "$omni_cluster" >/dev/null 2>&1 || return 1

  IS_TALOS_OMNI="yes"
  return 0
}

# Block until kube-apiserver /healthz reports etcd ok across all instances.
# Returns 0 on success, 1 on timeout (caller should warn-and-continue, not die —
# transient etcd flakes resolve on their own and the next phase will retry).
wait_apiserver_calm() {
  local timeout="${APISERVER_CALM_TIMEOUT:-300}"
  local deadline=$(( $(date +%s) + timeout ))
  local last_err=""

  while (( $(date +%s) < deadline )); do
    # /healthz returns 200 with body "ok" only when every check passes.
    # If etcd is the failing check, body contains "[-]etcd failed".
    local body
    if body=$(kubectl get --raw='/healthz' 2>&1) && [[ "$body" == "ok" ]]; then
      return 0
    fi
    last_err="$body"
    sleep 5
  done

  warn "apiserver did not calm within ${timeout}s — last /healthz: ${last_err}"
  return 1
}

# ---------------------------------------------------------------------------
# Phase 1.5: control-plane tuning (kube-apiserver only)
# ---------------------------------------------------------------------------
# On Talos+Omni: applies one Omni ConfigPatch:
#   400-apiserver-tuning-${OMNI_CLUSTER} from
#     infrastructure/talos/apiserver-tuning.yaml
#       (raises apiserver memory limit to 4Gi + in-flight caps so the CRD
#        storm doesn't OOMKill the apiserver, plus CM/scheduler kube-api-qps
#        + leader-elect timeouts that survive HDD fsync spikes)
#
# etcd tuning is intentionally NOT applied here. Home runs single-CP, so
# there are no etcd peers to lose quorum with — heartbeat-interval and
# election-timeout knobs are no-ops. If you scale CP back to 3, re-add
# the etcd-tuning ConfigPatch via:
#   omnictl apply -f infrastructure/talos/etcd-tuning-omni-patch.yaml
# (or extend this script).
#
# Then waits for Talos to roll the new kube-apiserver static-pod manifest
# (memory limit = 4Gi) on every control plane and for /healthz to be calm.
# Idempotent: re-applying the same ConfigPatch with the same data is a
# no-op in Omni.
#
# On non-Talos: switches BOOTSTRAP_PACE to slow so heavy installs wait for
# apiserver calm between phases instead of relying on tuning we cannot
# apply remotely.
phase_apiserver_tuning() {
  log "Phase 1.5: control-plane tuning (kube-apiserver)"

  if [[ "${SKIP_APISERVER_TUNING:-0}" == "1" ]]; then
    warn "SKIP_APISERVER_TUNING=1 — skipping (you take responsibility for apiserver headroom)"
    return 0
  fi

  if ! detect_talos_omni; then
    warn "not a Talos+Omni cluster — cannot auto-apply apiserver tuning patches"
    if [[ -z "${BOOTSTRAP_PACE:-}" ]]; then
      warn "auto-enabling BOOTSTRAP_PACE=slow so installs serialize and wait for /healthz between phases"
      BOOTSTRAP_PACE=slow
      export BOOTSTRAP_PACE
    fi
    warn "for permanent headroom on non-Talos: kube-apiserver mem-limit >=4Gi + --max-requests-inflight=1500 / --max-mutating-requests-inflight=700"
    return 0
  fi

  local omni_cluster="${OMNI_CLUSTER:-talos-${CLUSTER}}"

  # apiserver-tuning is cluster-wide. Workers silently ignore the apiServer/
  # controllerManager/scheduler blocks (Talos applies them only on CP).
  apply_omni_configpatch "$omni_cluster" 400-apiserver-tuning \
    "${REPO_ROOT}/infrastructure/talos/apiserver-tuning.yaml"

  # Talos rolls the new apiserver static-pod manifest serially per CP and
  # restarts apiserver. Just wait for /healthz to come back green — that's
  # sufficient confirmation the new config is live.
  log "waiting for kube-apiserver /healthz to settle after patch roll"
  wait_apiserver_calm || warn "continuing despite apiserver not yet calm — heavy installs may flake"
}

# Wrap a Talos config-patch yaml in an Omni ConfigPatches resource and apply
# it.
# Args:
#   $1  omni-cluster (e.g. talos-preview)
#   $2  patch-id-prefix (e.g. 400-etcd-tuning)
#   $3  patch-file (path to yaml under infrastructure/talos/)
#   $4  optional extra label to scope the patch (e.g.
#       "omni.sidero.dev/role-controlplane=" — value can be empty for
#       presence-only labels). Without this, the patch applies to every
#       machine in the cluster.
apply_omni_configpatch() {
  local omni_cluster="$1"
  local prefix="$2"
  local patch_file="$3"
  local extra_label="${4:-}"
  [[ -f "$patch_file" ]] || die "patch missing at ${patch_file}"

  local patch_id="${prefix}-${omni_cluster}"
  local tmp
  tmp=$(mktemp)
  {
    cat <<EOF
metadata:
  namespace: default
  type: ConfigPatches.omni.sidero.dev
  id: ${patch_id}
  labels:
    omni.sidero.dev/cluster: ${omni_cluster}
EOF
    if [[ -n "$extra_label" ]]; then
      local lk lv
      lk="${extra_label%%=*}"
      lv="${extra_label#*=}"
      printf '    %s: "%s"\n' "$lk" "$lv"
    fi
    cat <<EOF
spec:
  data: |
EOF
    sed 's/^/    /' "$patch_file" | grep -v '^    #'
  } > "$tmp"

  omnictl apply -f "$tmp" >/dev/null
  rm -f "$tmp"
  ok "ConfigPatch ${patch_id} applied"
}

# Inserted between phases to give the apiserver/etcd a chance to recover
# from a CRD/HelmRelease burst. No-op unless BOOTSTRAP_PACE=slow.
pace() {
  [[ "${BOOTSTRAP_PACE:-}" == "slow" ]] || return 0
  log "pace: waiting for kube-apiserver /healthz to stay green"
  wait_apiserver_calm || true
}

# `kubectl apply` wrapper that retries on transient apiserver/etcd errors.
# Even with apiserver+etcd tuning, large manifest bursts can momentarily
# saturate etcd write IOPS and surface as "etcdserver: request timed out"
# or Omni "proxy error". kubectl apply is idempotent for the resources
# already created, so we just retry until the burst clears.
kubectl_apply_with_retry() {
  local max_attempts="${KUBECTL_APPLY_MAX_ATTEMPTS:-5}"
  local backoff=10
  local attempt err_log
  err_log=$(mktemp)
  for (( attempt=1; attempt <= max_attempts; attempt++ )); do
    if kubectl apply "$@" 2> >(tee "$err_log" >&2); then
      rm -f "$err_log"
      return 0
    fi
    local err
    err=$(cat "$err_log")
    # Retry only on known-transient apiserver/etcd flakes. Real errors
    # (manifest validation, RBAC, schema) should fail fast.
    if ! grep -qE 'etcdserver: request timed out|proxy error|TLS handshake timeout|connection reset by peer|no endpoints available' <<<"$err"; then
      rm -f "$err_log"
      return 1
    fi
    warn "kubectl apply hit transient error (attempt ${attempt}/${max_attempts}); waiting ${backoff}s for /healthz to settle"
    wait_apiserver_calm || true
    sleep "$backoff"
    backoff=$(( backoff * 2 ))
  done
  rm -f "$err_log"
  die "kubectl apply failed ${max_attempts}x with transient errors — etcd is too overloaded to make progress"
}

# ---------------------------------------------------------------------------
# Phase 2: Talos worker data-disk check
# ---------------------------------------------------------------------------
phase_talos_check() {
  log "Phase 2: Talos data-disk check"

  if [[ "${SKIP_TALOS_CHECK:-0}" == "1" ]]; then
    warn "SKIP_TALOS_CHECK=1 — skipping"
    return 0
  fi
  if ! command -v talosctl >/dev/null 2>&1; then
    warn "talosctl missing — skipping"
    return 0
  fi

  # Default talosctl context defaults to whatever was last `talosctl config
  # context …` set, which is rarely the cluster we just kubectl'd into. Pin
  # it to the kubectl context name (works when both share naming, the case
  # in this repo). Override via TALOSCTL_CONTEXT.
  local tctx="${TALOSCTL_CONTEXT:-$(kubectl config current-context 2>/dev/null)}"
  [[ -n "$tctx" ]] || { warn "no talosctl context resolvable — skipping disk check"; return 0; }
  local tflag="--context=$tctx"

  # Map node IPs from kubectl; iterate and confirm u-longhorn volume + iscsi-tools ext.
  local ips
  ips=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')
  [[ -z "$ips" ]] && die "no node IPs found"

  local ok_count=0 total=0
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    total=$((total+1))

    # Retry up to 3x — talosctl over Omni/WireGuard can flake under burst.
    local vol_out="" ext_out="" attempt
    for attempt in 1 2 3; do
      vol_out=$(talosctl $tflag get volumestatus -n "$ip" 2>/dev/null || true)
      ext_out=$(talosctl $tflag get extensions   -n "$ip" 2>/dev/null || true)
      [[ -n "$vol_out" && -n "$ext_out" ]] && break
      sleep 2
    done

    if [[ -z "$vol_out" ]]; then
      warn "$ip: talosctl returned no volume status (auth/context issue?)"
      continue
    fi
    if ! grep -q 'u-longhorn .* ready' <<<"$vol_out"; then
      warn "$ip: u-longhorn volume not ready"
      continue
    fi
    # iscsi-tools may legitimately be absent for control-plane-only nodes
    # that don't run Longhorn pods. Treat missing extensions as a soft note,
    # not a blocker.
    if [[ -n "$ext_out" ]] && ! grep -q 'iscsi-tools' <<<"$ext_out"; then
      warn "$ip: iscsi-tools extension missing (ok if this node is CP-only)"
    fi
    ok_count=$((ok_count+1))
  done <<< "$ips"

  if [[ "$ok_count" -eq "$total" ]]; then
    ok "all $total nodes have u-longhorn volume ready"
  else
    warn "$ok_count/$total nodes fully ready — Longhorn may partially fail"
  fi
}

# ---------------------------------------------------------------------------
# Phase 2.5: CNI (Cilium or Flannel)
#
# Idempotent. Two supported primary CNIs:
#
#   Cilium: requires the Talos ConfigPatch (cni.name=none + proxy.disabled)
#     at cluster bootstrap time so nodes come up NotReady waiting for a CNI.
#     The Cilium-specific CCNP that allows pod->kube-apiserver is applied
#     after install (required because kube-proxy-replacement socket-LB
#     rewrites the kubernetes Service VIP to a node IP with reserved
#     identity that ipBlock CIDR rules don't match by default).
#
#   Flannel: Talos installs kube-flannel + kube-proxy DaemonSets
#     automatically at bootstrap when no CNI ConfigPatch is present.
#     Nothing else to do in this phase.
#
# To swap CNIs on a live cluster use ci/scripts/migrate-cni-cilium.sh or
# ci/scripts/migrate-cni-flannel.sh — those take backups first and quiesce
# workloads before the cut-over.
# ---------------------------------------------------------------------------
phase_cilium() {
  log "Phase 2.5: install primary CNI"

  local cni_mode="unknown"
  if kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
    cni_mode="cilium"
    log "  cilium DaemonSet already exists — skipping install"
  elif kubectl -n kube-system get ds kube-flannel >/dev/null 2>&1; then
    cni_mode="flannel"
    log "  flannel DaemonSet present (installed by Talos) — skipping Cilium install"
  else
    # No CNI yet — assume the operator intends Cilium (matches the
    # cilium-cni-patch.yaml ConfigPatch path). If they intended Flannel,
    # Talos would have already installed kube-flannel by the time we got
    # here, so this branch only runs on a Cilium-staged fresh cluster.
    cni_mode="cilium"
    "${REPO_ROOT}/infrastructure/cilium/install.sh"
  fi

  if [[ "$cni_mode" == "cilium" ]]; then
    # Apply additive CCNP that allows pod->kube-apiserver. Required under
    # Cilium kube-proxy replacement only.
    local ccnp="${REPO_ROOT}/infrastructure/cilium/ccnp-allow-kube-apiserver.yaml"
    if [[ -f "$ccnp" ]]; then
      kubectl_apply_with_retry "$ccnp"
    fi
  fi

  ok "$cni_mode CNI ready"
}

# ---------------------------------------------------------------------------
# Phase 3: Longhorn
# ---------------------------------------------------------------------------
phase_longhorn() {
  log "Phase 3: install Longhorn"

  if helm status longhorn -n longhorn-system >/dev/null 2>&1; then
    ok "Longhorn already installed — skipping helm upgrade"
  else
    # Talos PID 1 has no shell; the nsenter preflight in install.sh can't run.
    SKIP_PREFLIGHT=1 bash "${REPO_ROOT}/infrastructure/longhorn/install.sh"
  fi

  kubectl get storageclass longhorn >/dev/null 2>&1 || die "longhorn StorageClass missing"
  ok "longhorn StorageClass present (default)"

  # Note: Omni proxy annotation on longhorn-frontend is handled by the
  # XObjectPatch claim in composites/preview/objectpatches.cue and applied
  # in phase 7 when the rendered manifests are applied.
}

# ---------------------------------------------------------------------------
# Phase 3.5: metrics-server (Sidero-recommended path)
# ---------------------------------------------------------------------------
phase_metrics_server() {
  log "Phase 3.5: install metrics-server + kubelet-serving-cert-approver"

  if kubectl get deploy metrics-server -n kube-system >/dev/null 2>&1; then
    ok "metrics-server already installed — skipping"
    return 0
  fi

  # Talos kubelet must rotate server certs for metrics-server to talk
  # to kubelets without --kubelet-insecure-tls. Apply via Omni:
  #   infrastructure/talos/kubelet-cert-rotation.yaml
  # and reboot each node BEFORE running this. Warn if not detected.
  warn "ensure machine-config patch infrastructure/talos/kubelet-cert-rotation.yaml is applied + nodes rebooted"

  bash "${REPO_ROOT}/infrastructure/metrics-server/install.sh" || warn "metrics-server install verification timed out — check CSRs and kubelet config"
}

# ---------------------------------------------------------------------------
# Phase 4: CloudNativePG
# ---------------------------------------------------------------------------
phase_cnpg() {
  log "Phase 4: install CloudNativePG"

  # INSTALL_CNPG=auto (default) defers to detect_addons; explicit 0/1 wins.
  local need_cnpg="${INSTALL_CNPG:-auto}"
  [[ "$need_cnpg" == "auto" ]] && need_cnpg="${DETECTED_NEED_CNPG:-0}"

  if [[ "$need_cnpg" != "1" ]]; then
    if helm status cnpg -n cnpg-system >/dev/null 2>&1; then
      warn "CNPG installed but no rendered manifests reference it — leaving in place; pass INSTALL_CNPG=0 to phase_uninstall_unused (TODO) for cleanup"
    else
      ok "no rendered manifests reference CNPG — skipping install"
    fi
    return 0
  fi

  if helm status cnpg -n cnpg-system >/dev/null 2>&1; then
    ok "CNPG already installed — skipping helm upgrade"
  else
    bash "${REPO_ROOT}/infrastructure/cloudnative-pg/install.sh"
  fi

  if kubectl -n cnpg-system wait --for=condition=Available deploy --all --timeout=10m >/dev/null 2>&1; then
    ok "CNPG operator Available"
  else
    warn "CNPG operator not yet Available within 10m — pod is likely crashlooping on lease-renew under etcd pressure; continuing (CNPG is downstream-only and self-stabilizes once apiserver/etcd settle)"
  fi
}

# ---------------------------------------------------------------------------
# Phase 5: Crossplane
# ---------------------------------------------------------------------------
phase_crossplane() {
  log "Phase 5: install Crossplane UXP + providers + functions"

  if helm status crossplane -n crossplane-system >/dev/null 2>&1; then
    ok "Crossplane already installed — re-running installer for providers/functions idempotency"
  fi

  # detect_addons sets DETECTED_INSTALL_HARBOR / DETECTED_INSTALL_EXTRA_RES /
  # DETECTED_NEED_CNPG based on what the rendered cluster manifests actually
  # reference. INSTALL_HARBOR=auto / INSTALL_EXTRA_RES=auto in the env defers
  # to detection; explicit 0/1 wins. CNPG is gated separately in phase_cnpg.
  local install_harbor="${INSTALL_HARBOR:-auto}"
  local install_extra="${INSTALL_EXTRA_RES:-auto}"
  [[ "$install_harbor" == "auto" ]] && install_harbor="${DETECTED_INSTALL_HARBOR:-0}"
  [[ "$install_extra"  == "auto" ]] && install_extra="${DETECTED_INSTALL_EXTRA_RES:-0}"

  INSTALL_HARBOR="$install_harbor" INSTALL_EXTRA_RES="$install_extra" \
    bash "${REPO_ROOT}/infrastructure/crossplane/install.sh"

  kubectl wait --for=condition=Healthy provider/provider-helm       --timeout=5m >/dev/null
  kubectl wait --for=condition=Healthy provider/provider-kubernetes --timeout=5m >/dev/null
  if [[ "$install_harbor" == "1" ]] && kubectl get provider provider-harbor >/dev/null 2>&1; then
    kubectl wait --for=condition=Healthy provider/provider-harbor   --timeout=5m >/dev/null
  fi
  ok "Crossplane providers Healthy"
}

# Inspect rendered manifests under clusters/${CLUSTER}/ and decide which
# optional Crossplane providers + functions and which standalone operators
# (CNPG) the cluster actually needs. Sets DETECTED_INSTALL_* exports that
# phase_crossplane and phase_cnpg consume. Idempotent; safe to re-run.
detect_addons() {
  log "Detecting required Crossplane addons + operators from rendered manifests"

  local out_dir="${REPO_ROOT}/clusters/${CLUSTER}"
  if [[ ! -d "$out_dir" ]]; then
    warn "no rendered manifests at ${out_dir} — addon detection will assume nothing is needed; pass INSTALL_HARBOR/INSTALL_EXTRA_RES/INSTALL_CNPG to override"
    DETECTED_INSTALL_HARBOR=0
    DETECTED_INSTALL_EXTRA_RES=0
    DETECTED_NEED_CNPG=0
    export DETECTED_INSTALL_HARBOR DETECTED_INSTALL_EXTRA_RES DETECTED_NEED_CNPG
    return 0
  fi

  # Harbor: any XHarbor* XRD or any composition that references a harbor
  # CRD group. Either signal is sufficient.
  if ls "$out_dir/xrds" 2>/dev/null | grep -qi 'xharbor'; then
    DETECTED_INSTALL_HARBOR=1
  elif grep -q -r --include='*.yaml' 'harbor.crossplane.io\|provider-harbor' "$out_dir/compositions" 2>/dev/null; then
    DETECTED_INSTALL_HARBOR=1
  else
    DETECTED_INSTALL_HARBOR=0
  fi

  # function-extra-resources: any composition pipeline step references it.
  if grep -q -r --include='*.yaml' 'crossplane-contrib-function-extra-resources' "$out_dir/compositions" 2>/dev/null; then
    DETECTED_INSTALL_EXTRA_RES=1
  else
    DETECTED_INSTALL_EXTRA_RES=0
  fi

  # CNPG: any database-shaped XRD or any manifest references the cnpg.io
  # API group. Tightening this signal as the database stack matures is fine.
  if ls "$out_dir/xrds" 2>/dev/null | grep -qi 'xdatabase\|xpostgres\|xcnpg'; then
    DETECTED_NEED_CNPG=1
  elif grep -q -r --include='*.yaml' 'cnpg.io\|postgresql.cnpg' "$out_dir" 2>/dev/null; then
    DETECTED_NEED_CNPG=1
  else
    DETECTED_NEED_CNPG=0
  fi

  export DETECTED_INSTALL_HARBOR DETECTED_INSTALL_EXTRA_RES DETECTED_NEED_CNPG
  ok "addon detection: harbor=${DETECTED_INSTALL_HARBOR} extra-resources=${DETECTED_INSTALL_EXTRA_RES} cnpg=${DETECTED_NEED_CNPG}"
}

# ---------------------------------------------------------------------------
# Phase 5.5: patch upbound-controller-manager ConfigMap
# ---------------------------------------------------------------------------
# UXP chart 2.2.0-up.4 writes ConfigMap key `uxpVersion` but the
# upbound-controller-manager sidecar reads `crossplaneVersion`. Without
# this patch the sidecar pod CrashLoops with CreateContainerConfigError.
# Idempotent: kubectl patch is safe to re-run.
phase_upbound_cm_patch() {
  log "Phase 5.5: patch upbound-crossplane-versions ConfigMap"

  if ! kubectl get cm upbound-crossplane-versions -n crossplane-system >/dev/null 2>&1; then
    warn "upbound-crossplane-versions ConfigMap not found — skipping"
    return 0
  fi
  local uxpv
  uxpv=$(kubectl get cm upbound-crossplane-versions -n crossplane-system -o jsonpath='{.data.uxpVersion}')
  # Use --field-manager=helm so subsequent `helm upgrade` doesn't conflict
  # with kubectl-patch ownership on .data.crossplaneVersion. --force-conflicts
  # rewrites ownership cleanly when re-running on a previously-patched CM.
  kubectl patch cm upbound-crossplane-versions -n crossplane-system \
    --type=merge -p "{\"data\":{\"crossplaneVersion\":\"${uxpv}\"}}" \
    --field-manager=helm >/dev/null 2>&1 || \
  kubectl apply --server-side --force-conflicts --field-manager=helm -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: upbound-crossplane-versions
  namespace: crossplane-system
data:
  crossplaneVersion: "${uxpv}"
  uxpVersion: "${uxpv}"
EOF
  ok "ConfigMap patched (crossplaneVersion=${uxpv}, field-manager=helm)"

  # Restart the controller manager to pick up the new key if it was crashing.
  kubectl get pod -n crossplane-system -l app.kubernetes.io/component=upbound-controller-manager \
    -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -q 'Pending\|Failed' \
    && kubectl delete pod -n crossplane-system -l app.kubernetes.io/component=upbound-controller-manager >/dev/null \
    && ok "restarted upbound-controller-manager pod" \
    || true
}

# ---------------------------------------------------------------------------
# Phase 6: render CUE
# ---------------------------------------------------------------------------
phase_render() {
  log "Phase 6: validate + render home manifests"
  (cd "${REPO_ROOT}" && make validate)
  if [[ "$RAW_MODE" == "1" ]]; then
    (cd "${REPO_ROOT}" && make export-raw CLUSTER="${CLUSTER}")
    local out_dir="${REPO_ROOT}/clusters/${CLUSTER}-raw"
  else
    (cd "${REPO_ROOT}" && make export-cluster CLUSTER="${CLUSTER}")
    local out_dir="${REPO_ROOT}/clusters/${CLUSTER}"
  fi
  [[ -d "$out_dir" ]] || die "expected ${out_dir} after export"
  ok "rendered manifests at ${out_dir}"
}

# ---------------------------------------------------------------------------
# Phase 7: apply
# ---------------------------------------------------------------------------
phase_apply() {
  log "Phase 7: apply rendered manifests"

  local out_dir
  if [[ "$RAW_MODE" == "1" ]]; then
    out_dir="${REPO_ROOT}/clusters/${CLUSTER}-raw"
  else
    out_dir="${REPO_ROOT}/clusters/${CLUSTER}"
  fi
  [[ -d "$out_dir" ]] || die "no rendered manifests at ${out_dir} — run phase 6 first"

  if [[ "$RAW_MODE" != "1" && -d "${out_dir}/xrds" ]]; then
    kubectl_apply_with_retry -R -f "${out_dir}/xrds"
    if ! kubectl wait --for=condition=Established -f "${out_dir}/xrds" --timeout=10m; then
      warn "some XRDs not Established within 10m — Crossplane may still be reconciling; continuing"
    fi
  fi

  # Pre-install chart CRDs that ship a CRD *and* a custom resource in the
  # SAME Helm release. Helm can't establish the CRD's API before it applies
  # the CR within one release, so provider-helm fails with "no matches for
  # kind ..." and rolls the whole release back (it never retries to success).
  # The argocd-image-updater chart ships the ImageUpdater CRD + per-app
  # ImageUpdater CRs together. Install the CRD up front and stamp it with the
  # release's Helm ownership so `crds.install: true` adopts it instead of
  # erroring on "exists and cannot be imported". Idempotent; version must
  # track the chart version in composites/home/helmreleases.cue.
  if [[ "$RAW_MODE" != "1" ]]; then
    local iu_crd="imageupdaters.argocd-image-updater.argoproj.io"
    helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
    helm repo update argo >/dev/null 2>&1 || true
    if helm show crds argo/argocd-image-updater --version 1.1.5 2>/dev/null | kubectl apply -f - >/dev/null 2>&1; then
      kubectl label crd "$iu_crd" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true
      kubectl annotate crd "$iu_crd" \
        meta.helm.sh/release-name=argocd-image-updater \
        meta.helm.sh/release-namespace=argocd --overwrite >/dev/null 2>&1 || true
      kubectl wait --for=condition=established "crd/${iu_crd}" --timeout=60s >/dev/null 2>&1 || true
      ok "pre-installed + helm-stamped ImageUpdater CRD (avoids same-release CRD/CR race)"
    else
      warn "could not pre-install ImageUpdater CRD — argocd-image-updater may need a manual retry"
    fi
  fi

  kubectl_apply_with_retry -R -f "${out_dir}"
  ok "manifests applied"

  if [[ "$RAW_MODE" == "1" && -f "${out_dir}/_skipped.md" ]]; then
    log "raw-mode skipped resources (manual replacement required):"
    sed 's/^/  /' "${out_dir}/_skipped.md" >&2
  fi

  # Cloudflare tunnel edge Ingresses — consumed by STRRL controller to
  # provision the tunnel, DNS, and routes. Applied out-of-band because they
  # use path-based routing in argo-events, which XIngress XRD doesn't model.
  if kubectl get ns traefik argo-events >/dev/null 2>&1; then
    kubectl apply -f "${REPO_ROOT}/infrastructure/cloudflared/ingresses.yaml"
    ok "cloudflare-tunnel Ingresses applied (controller will provision tunnel once token is seeded)"
  fi

  # If Omni service-exposer annotations were updated by this apply, the
  # exposer DaemonSet's per-node in-memory registry can hold stale
  # host-port mappings. Restart cycles all pods so each re-reads the
  # current Service set. Cheap (~30s), idempotent. See:
  # docs/support-cases/omni-exposer-stale-registry.md
  if kubectl get ds -n kube-system omni-kube-service-exposer >/dev/null 2>&1; then
    kubectl rollout restart ds -n kube-system omni-kube-service-exposer >/dev/null
    if kubectl rollout status ds -n kube-system omni-kube-service-exposer --timeout=5m >/dev/null; then
      ok "omni-kube-service-exposer DaemonSet rolled (clears any stale annotation registry)"
    else
      warn "omni-kube-service-exposer DaemonSet rollout did not complete within 5m — continuing (registry may be stale)"
    fi
  fi

  # MetalLB pool now ships as XMetalLBPool composite (rendered from CUE),
  # not raw YAML — applied with the rest of clusters/home above.
}

# ---------------------------------------------------------------------------
# Phase 8: wait for core HelmReleases
# ---------------------------------------------------------------------------
phase_wait_releases() {
  log "Phase 8: wait for HelmReleases to reconcile"

  local timeout="${HELMRELEASE_WAIT_TIMEOUT:-900}"
  local deadline=$(( $(date +%s) + timeout ))

  while (( $(date +%s) < deadline )); do
    local total not_ready
    # cols: NAME NAMESPACE CHART VERSION SYNCED READY STATE ...
    total=$(kubectl get releases.helm.crossplane.io --no-headers 2>/dev/null | wc -l | tr -d ' ')
    not_ready=$(kubectl get releases.helm.crossplane.io --no-headers 2>/dev/null \
      | awk '$5 != "True" || $6 != "True" {print $1}' | wc -l | tr -d ' ')
    if [[ "$total" -gt 0 && "$not_ready" -eq 0 ]]; then
      ok "$total HelmReleases Synced+Ready"
      return 0
    fi
    printf '  waiting: %s/%s releases not yet ready...\r' "$not_ready" "$total"
    sleep 10
  done

  warn "timeout after ${timeout}s — check: kubectl get releases.helm.crossplane.io"
  kubectl get releases.helm.crossplane.io || true
  return 1
}

# ---------------------------------------------------------------------------
# Phase 8.5: bootstrap Argo CD `ci` account + RBAC
# ---------------------------------------------------------------------------
# Argo Events sync Jobs authenticate to Argo CD with a token minted for
# the `ci` account. Argo CD doesn't ship that account by default; this
# phase patches argocd-cm to enable it, sets RBAC for the `previews`
# project, and restarts the server so the changes take effect.
#
# Token minting itself is NOT done here — it requires an `argocd login`
# session. The next-step summary prints the exact commands.
# Idempotent: kubectl patch on the same value is a no-op.
phase_argocd_ci_bootstrap() {
  log "Phase 8.5: enable Argo CD 'ci' account + RBAC"

  if ! kubectl get cm argocd-cm -n argocd >/dev/null 2>&1; then
    warn "argocd-cm not found — Argo CD HelmRelease may not be ready yet"
    return 0
  fi

  local existing_account existing_policy
  existing_account=$(kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.accounts\.ci}' 2>/dev/null)
  if [[ "$existing_account" != "apiKey" ]]; then
    kubectl -n argocd patch cm argocd-cm --type merge \
      -p '{"data":{"accounts.ci":"apiKey"}}' >/dev/null
    ok "argocd-cm: accounts.ci=apiKey"
  fi

  existing_policy=$(kubectl -n argocd get cm argocd-rbac-cm -o jsonpath='{.data.policy\.csv}' 2>/dev/null)
  if [[ "$existing_policy" != *"role:ci"* ]]; then
    kubectl -n argocd patch cm argocd-rbac-cm --type merge -p '{"data":{"policy.csv":"p, role:ci, applications, get, previews/*, allow\np, role:ci, applications, sync, previews/*, allow\np, role:ci, applications, action/*, previews/*, allow\ng, ci, role:ci\n"}}' >/dev/null
    ok "argocd-rbac-cm: role:ci policy added"
  fi

  # Restart argocd-server to pick up account + RBAC changes (no-op if no
  # change was made because Deployment template hash stays the same — but
  # `rollout restart` always bumps an annotation, so still cheap).
  if kubectl -n argocd get deploy argo-cd-argocd-server >/dev/null 2>&1; then
    kubectl -n argocd rollout restart deploy argo-cd-argocd-server >/dev/null
    kubectl -n argocd rollout status   deploy argo-cd-argocd-server --timeout=2m >/dev/null
    ok "argocd-server restarted"
  fi
}

# ---------------------------------------------------------------------------
# Phase 8.6: kelos feature-flags ConfigMap (defaults)
# ---------------------------------------------------------------------------
# The ci-failure-autofix Sensor and the review-pipeline Sensors gate on
# data keys inside ConfigMap kelos-system/feature-flags. With the
# ConfigMap missing the gate reads an empty string and the dispatcher
# exits (silently leaving the automation off). Seed the ConfigMap once,
# imperatively, with off-by-default values for net-new clusters; if the
# ConfigMap already exists this phase is a no-op so per-cluster toggles
# made via `kubectl patch cm feature-flags ...` survive future bootstrap
# runs.
phase_kelos_feature_flags() {
  log "Phase 8.6: kelos feature-flags ConfigMap"

  if ! kubectl get ns kelos-system >/dev/null 2>&1; then
    warn "kelos-system namespace not found — skipping (Crossplane Composition not applied yet?)"
    return 0
  fi

  if kubectl -n kelos-system get cm feature-flags >/dev/null 2>&1; then
    ok "feature-flags ConfigMap already present — leaving values as-is"
    return 0
  fi

  # ci-autofix is gated PER-WORKSPACE. The dispatcher reads
  # ci-autofix-enabled-<workspace> (e.g. ci-autofix-enabled-jarvy),
  # where <workspace> is the lowercased repo name. A repo without an
  # explicit "true" entry is treated as DISABLED — no global default.
  # Seed each known workspace with off-by-default so the keys exist
  # for easy toggling; new workspaces inherit "disabled" until added
  # here OR a kubectl patch.
  kubectl -n kelos-system create configmap feature-flags \
    --from-literal=ci-autofix-enabled-jarvy=false \
    --from-literal=ci-autofix-enabled-k8-infra=false \
    --from-literal=ci-autofix-enabled-salessage=false \
    --from-literal=review-pipeline-enabled=false \
    --from-literal=tool-discovery-enabled=false >/dev/null
  ok "feature-flags ConfigMap seeded (all flags off — toggle per-workspace via kubectl patch)"
}

# ---------------------------------------------------------------------------
# Phase 9: next-step summary
# ---------------------------------------------------------------------------
phase_summary() {
  log "Phase 9: next steps (manual)"
  cat <<'EOS'

Platform base is installed. Remaining phases require human input or secrets:

  1. OpenBao bootstrap — the bootstrap Job should run automatically. Verify:
       kubectl get jobs -n openbao -w
       kubectl exec -n openbao openbao-0 -- bao status

     Back up the unseal key immediately:
       kubectl get secret openbao-keys -n openbao -o yaml > openbao-keys-backup.yaml

  2. Seed secrets — fastest path is the bundled reseed script:
       kubectl port-forward -n openbao svc/openbao 8200:8200 &
       export BAO_ADDR=http://localhost:8200
       export BAO_TOKEN=$(kubectl get secret openbao-keys -n openbao \
         -o jsonpath='{.data.root-token}' | base64 -d)
       cd ~/k8-infra-openbao-backup-20260416-125740
       ./reseed.sh        # populates every preview/* path from JSON files

     Then re-seed home/unifi with a FRESH UniFi admin API key (the one in the
     backup file was rotated):
       bao kv put secret/home/unifi \
         host='https://192.168.1.1' \
         api_key='<NEW_UNIFI_KEY>' \
         external='false'

  3. Cloudflare tunnel:
       cloudflared tunnel login
       cloudflared tunnel create home
       bao kv put -mount=secret preview/cloudflare-tunnel \
         account_id="<id>" tunnel_name=home \
         api_token="<token with Zone:DNS:Edit + Account:Cloudflare Tunnel:Edit>"
       cloudflared tunnel route dns home "<your zone>"

  4. Force ESO sync + verify:
       kubectl rollout restart deployment -n external-secrets external-secrets
       kubectl get externalsecrets -A
       kubectl get clusterexternalsecrets

  5. UniFi DNS records publish automatically once external-dns picks up the
     valid api_key. Verify:
       dig @192.168.1.1 it-tools.example.internal
       dig @192.168.1.1 home-assistant.example.internal

  6. Smoke test the AI pipeline (only if you re-seeded github-pat + claude
     oauth + discord webhook):
       kubectl get applications -n argocd -w
       kubectl get tasks -n kelos-system

EOS
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  phase_preflight
  phase_pause
  phase_apiserver_tuning
  phase_pause
  phase_talos_check
  phase_pause

  if [[ "$CHECK_ONLY" == "1" ]]; then
    log "--check-only: skipping installs"
    return 0
  fi

  phase_cilium
  pace
  phase_pause

  # Render up-front so detect_addons can inspect the actual rendered XRDs +
  # Compositions and decide which optional providers/operators to install.
  # phase_render is idempotent (cue export overwrites clusters/<cluster>/);
  # the later phase_apply uses the same output.
  if [[ "$SKIP_RENDER" == "1" ]]; then
    warn "--skip-render: addon detection will fall back to env vars (INSTALL_HARBOR/INSTALL_EXTRA_RES/INSTALL_CNPG)"
  else
    phase_render
  fi
  detect_addons
  phase_pause

  phase_longhorn
  pace
  phase_pause
  phase_metrics_server
  pace
  phase_pause
  phase_cnpg
  pace
  phase_pause
  if [[ "$RAW_MODE" != "1" ]]; then
    phase_crossplane
    phase_upbound_cm_patch
    pace
    phase_pause
  else
    log "Phase 5: SKIPPED — --raw mode renders Crossplane-free manifests"
  fi

  if [[ "$SKIP_RENDER" == "1" ]]; then
    warn "--skip-render: skipping apply/wait"
  else
    phase_apply
    phase_pause
    phase_wait_releases || true
    phase_pause
    phase_argocd_ci_bootstrap || true
    phase_kelos_feature_flags || true
  fi

  phase_summary
  ok "bootstrap-home.sh complete"
}

main "$@"
