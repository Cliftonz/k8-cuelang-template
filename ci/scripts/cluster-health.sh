#!/usr/bin/env bash
# Cluster health sweep for the preview platform.
#
# Groups output into sections with pass/warn/fail counts. Distinguishes
# real platform errors from user-side blockers (missing OpenBao secrets,
# unconfigured Cloudflare tunnel, etc.) so you can tell what's actually
# broken vs. what's waiting on manual seeding.
#
# Usage:
#   ./ci/scripts/cluster-health.sh                  # all checks
#   ./ci/scripts/cluster-health.sh --quick          # nodes + releases + pods
#   ./ci/scripts/cluster-health.sh --since=30m      # widen event window
#   ./ci/scripts/cluster-health.sh --no-talos       # skip Talos disk check
#
# Exit codes:
#   0  all green
#   1  warnings only (user-side blockers, pods still converging)
#   2  platform errors that need attention

set -uo pipefail

QUICK=0
SINCE="5m"
SKIP_TALOS=0

for arg in "$@"; do
  case "$arg" in
    --quick)     QUICK=1 ;;
    --no-talos)  SKIP_TALOS=1 ;;
    --since=*)   SINCE="${arg#--since=}" ;;
    -h|--help)   sed -n '2,18p' "$0"; exit 0 ;;
    *)           echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

RED=$'\033[1;31m' YLW=$'\033[1;33m' GRN=$'\033[1;32m' BLU=$'\033[1;34m' DIM=$'\033[2m' RST=$'\033[0m'

warn_count=0
err_count=0

section() { printf '\n%s== %s ==%s\n' "$BLU" "$1" "$RST"; }
ok()      { printf '%s✓%s %s\n'  "$GRN" "$RST" "$1"; }
warn()    { printf '%s⚠%s %s\n'  "$YLW" "$RST" "$1"; warn_count=$((warn_count+1)); }
err()     { printf '%s✗%s %s\n'  "$RED" "$RST" "$1"; err_count=$((err_count+1)); }
note()    { printf '  %s%s%s\n'  "$DIM" "$1" "$RST"; }

# ---------------------------------------------------------------------------
# Cluster context + nodes
# ---------------------------------------------------------------------------
section "Context"
ctx=$(kubectl config current-context 2>/dev/null) || { err "kubectl unreachable"; exit 2; }
ok "context: $ctx"

section "Nodes"
node_json=$(kubectl get nodes -o json 2>/dev/null)
total_nodes=$(jq '.items | length' <<<"$node_json")
ready_nodes=$(jq '[.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))] | length' <<<"$node_json")
unsched=$(jq -r '.items[] | select(.spec.unschedulable==true) | .metadata.name' <<<"$node_json")

if [[ "$ready_nodes" == "$total_nodes" ]]; then
  ok "$ready_nodes/$total_nodes Ready"
else
  warn "$ready_nodes/$total_nodes Ready"
fi
if [[ -n "$unsched" ]]; then
  warn "cordoned nodes: $(tr '\n' ' ' <<<"$unsched")"
fi

# ---------------------------------------------------------------------------
# Helm releases (Crossplane provider-helm)
# ---------------------------------------------------------------------------
section "HelmReleases (Crossplane)"
rel_out=$(kubectl get releases.helm.crossplane.io --no-headers 2>/dev/null || true)
if [[ -z "$rel_out" ]]; then
  warn "no releases.helm.crossplane.io resources found"
else
  # cols: NAME NAMESPACE CHART VERSION SYNCED READY STATE ...
  total_rel=$(wc -l <<<"$rel_out" | tr -d ' ')
  bad_rel=$(awk '$5!="True" || $6!="True"' <<<"$rel_out" | wc -l | tr -d ' ')
  if [[ "$bad_rel" -eq 0 ]]; then
    ok "$total_rel/$total_rel Synced+Ready"
  else
    err "$bad_rel/$total_rel NOT Synced+Ready"
    awk '$5!="True" || $6!="True" {printf "    %s/%s (synced=%s ready=%s state=%s)\n",$2,$1,$5,$6,$7}' <<<"$rel_out"
  fi
fi

# ---------------------------------------------------------------------------
# Non-Running pods
# ---------------------------------------------------------------------------
section "Pods"
pod_out=$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed"')
if [[ -z "$pod_out" ]]; then
  ok "all pods Running/Completed"
else
  not_running=$(wc -l <<<"$pod_out" | tr -d ' ')
  crashloop=$(awk '$4=="CrashLoopBackOff"' <<<"$pod_out" | wc -l | tr -d ' ')
  err_phase=$(awk '$4=="Error"' <<<"$pod_out" | wc -l | tr -d ' ')
  creating=$(awk '$4=="ContainerCreating"' <<<"$pod_out" | wc -l | tr -d ' ')
  backoff=$(awk '$4=="ImagePullBackOff" || $4=="ErrImagePull"' <<<"$pod_out" | wc -l | tr -d ' ')

  if [[ "$crashloop" -gt 0 || "$backoff" -gt 0 ]]; then
    err "$not_running not Running ($crashloop CrashLoop, $backoff ImagePullBackOff, $err_phase Error, $creating ContainerCreating)"
  else
    warn "$not_running not Running ($err_phase Error, $creating ContainerCreating — may be transient)"
  fi
  awk '{printf "    %-20s %-60s %s\n",$1,$2,$4}' <<<"$pod_out" | head -15
fi

# ---------------------------------------------------------------------------
# Crossplane XRs with non-Ready status
# ---------------------------------------------------------------------------
if [[ "$QUICK" == "0" ]]; then
  section "Crossplane XRs"
  providers_bad=$(kubectl get providers.pkg.crossplane.io --no-headers 2>/dev/null | awk '$3!="True"')
  fns_bad=$(kubectl get functions.pkg.crossplane.io --no-headers 2>/dev/null | awk '$3!="True"')
  if [[ -z "$providers_bad" && -z "$fns_bad" ]]; then
    ok "all providers + functions Healthy"
  else
    [[ -n "$providers_bad" ]] && err "unhealthy providers: $(wc -l <<<"$providers_bad" | tr -d ' ')"
    [[ -n "$fns_bad" ]]       && err "unhealthy functions: $(wc -l <<<"$fns_bad"       | tr -d ' ')"
  fi
fi

# ---------------------------------------------------------------------------
# APIServices — any Unavailable APIService blocks namespace deletion
# (the namespace controller's discovery loop fails on the bad group).
# Burned 30 min on 2026-05-15 with metrics.k8s.io stalled and a ns
# stuck Terminating; this section surfaces it on the first sweep.
# ---------------------------------------------------------------------------
if [[ "$QUICK" == "0" ]]; then
  section "APIServices"
  bad_apisvc=$(kubectl get apiservice -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.conditions[?(@.type=="Available")].status}{":"}{.status.conditions[?(@.type=="Available")].reason}{"\n"}{end}' 2>/dev/null | grep -v "=True:")
  if [[ -z "$bad_apisvc" ]]; then
    ok "all APIServices Available"
  else
    count=$(wc -l <<<"$bad_apisvc" | tr -d ' ')
    err "$count APIService(s) NOT Available (will block ns deletion):"
    echo "$bad_apisvc" | sed 's/^/    /'
  fi
fi

# ---------------------------------------------------------------------------
# External Secrets
# ---------------------------------------------------------------------------
if [[ "$QUICK" == "0" ]]; then
  section "External Secrets"
  css_out=$(kubectl get clustersecretstores --no-headers 2>/dev/null || true)
  if [[ -n "$css_out" ]]; then
    # cols: NAME AGE STATUS CAPABILITIES READY
    bad_css=$(awk '$5!="True"' <<<"$css_out" | wc -l | tr -d ' ')
    total_css=$(wc -l <<<"$css_out" | tr -d ' ')
    if [[ "$bad_css" -eq 0 ]]; then
      ok "ClusterSecretStore(s) Ready: $total_css"
    else
      err "ClusterSecretStore(s) NOT Ready: $bad_css/$total_css"
    fi
  fi

  es_out=$(kubectl get externalsecrets -A --no-headers 2>/dev/null || true)
  if [[ -z "$es_out" ]]; then
    note "no ExternalSecrets found"
  else
    total_es=$(wc -l <<<"$es_out" | tr -d ' ')
    error_es=$(awk '$5=="SecretSyncedError"' <<<"$es_out" | wc -l | tr -d ' ')
    if [[ "$error_es" -eq 0 ]]; then
      ok "$total_es ExternalSecrets synced"
    else
      warn "$error_es/$total_es ExternalSecrets SecretSyncedError (likely missing OpenBao keys — user-side)"
      awk '$5=="SecretSyncedError" {printf "    %s/%s → %s\n",$1,$2,$3}' <<<"$es_out" | head -10
    fi
  fi
fi

# ---------------------------------------------------------------------------
# OpenBao seal status
# ---------------------------------------------------------------------------
if [[ "$QUICK" == "0" ]]; then
  section "OpenBao"
  if kubectl get ns openbao >/dev/null 2>&1; then
    bao_status=$(kubectl exec -n openbao openbao-0 -- bao status 2>/dev/null || true)
    if grep -q 'Sealed.*false' <<<"$bao_status"; then
      ok "openbao-0 initialized + unsealed"
    elif grep -q 'Sealed.*true' <<<"$bao_status"; then
      err "openbao-0 sealed"
    else
      warn "openbao-0 status unclear"
    fi
    kubectl get secret openbao-keys -n openbao >/dev/null 2>&1 \
      && ok "openbao-keys Secret present" \
      || err "openbao-keys Secret missing — bootstrap never completed"
  else
    note "openbao namespace not present — skipping"
  fi
fi

# ---------------------------------------------------------------------------
# Talos disk + extension check
# ---------------------------------------------------------------------------
if [[ "$QUICK" == "0" && "$SKIP_TALOS" == "0" ]] && command -v talosctl >/dev/null 2>&1; then
  section "Talos data disks"
  ips=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')
  good=0 bad=0
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    vol=$(talosctl get volumestatus -n "$ip" 2>/dev/null || true)
    ext=$(talosctl get extensions   -n "$ip" 2>/dev/null || true)
    if grep -q 'u-longhorn .* ready' <<<"$vol" && grep -q 'iscsi-tools' <<<"$ext"; then
      good=$((good+1))
    else
      bad=$((bad+1))
      warn "$ip: u-longhorn volume or iscsi-tools missing"
    fi
  done <<< "$ips"
  [[ "$bad" -eq 0 ]] && ok "$good nodes with u-longhorn + iscsi-tools"
fi

# ---------------------------------------------------------------------------
# Recent warning events
# ---------------------------------------------------------------------------
section "Warning events (last $SINCE)"
ev_out=$(kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null \
  | awk -v age="$SINCE" '
      # Filter rows where the "AGE" column (col 2) is within $SINCE.
      # Crude — kubectl prints 30s/5m/2h/1d; we accept anything <= $SINCE unit-wise.
      NR==1 {next}
      {
        a=$2
        # drop s/m/h/d suffix
        unit=substr(a, length(a), 1); num=substr(a,1,length(a)-1)+0
        cutoff_unit=substr(age, length(age), 1); cutoff_num=substr(age,1,length(age)-1)+0
        # convert to seconds
        us = (unit=="s"?1:unit=="m"?60:unit=="h"?3600:unit=="d"?86400:0)
        cs = (cutoff_unit=="s"?1:cutoff_unit=="m"?60:cutoff_unit=="h"?3600:cutoff_unit=="d"?86400:0)
        if (num*us <= cutoff_num*cs) print
      }')

if [[ -z "$ev_out" ]]; then
  ok "no Warning events in last $SINCE"
else
  ev_count=$(wc -l <<<"$ev_out" | tr -d ' ')
  # Classify: user-side vs platform-side.
  user_side=$(grep -cE 'Secret does not exist|secret.*not found|no such host.*example\.com' <<<"$ev_out" || true)
  transient=$(grep -cE 'BackOff|snapshot becomes not ready|still attached to node|FailedMount.*webhook-secret' <<<"$ev_out" || true)
  platform=$(( ev_count - user_side - transient ))
  if [[ "$platform" -gt 0 ]]; then
    err "$ev_count warnings ($platform platform / $user_side user-side / $transient transient)"
    grep -vE 'Secret does not exist|secret.*not found|no such host.*example\.com|BackOff|snapshot becomes not ready|still attached to node|FailedMount.*webhook-secret' <<<"$ev_out" \
      | awk '{printf "    %s/%-30s %s %s\n",$1,$5,$4,$6}' | head -10
  else
    warn "$ev_count warnings (all user-side/transient)"
  fi
fi

# ---------------------------------------------------------------------------
# NetworkPolicy post-DNAT gap audit (skipped in --quick mode)
# ---------------------------------------------------------------------------
if [[ "$QUICK" == 0 ]]; then
  section "NetworkPolicy post-DNAT audit"
  script_dir=$(cd "$(dirname "$0")" && pwd)
  if [[ -x "$script_dir/check-np-post-dnat.sh" ]]; then
    np_out=$("$script_dir/check-np-post-dnat.sh" 2>&1)
    np_rc=$?
    if [[ $np_rc -eq 0 ]]; then
      ok "$np_out"
    else
      err "$np_out"
    fi
  else
    warn "check-np-post-dnat.sh not found alongside cluster-health.sh"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "Summary"
printf '  warnings: %s%d%s  errors: %s%d%s\n' "$YLW" "$warn_count" "$RST" "$RED" "$err_count" "$RST"

if [[ "$err_count" -gt 0 ]]; then
  printf '%s✗ platform errors present%s\n' "$RED" "$RST"
  exit 2
elif [[ "$warn_count" -gt 0 ]]; then
  printf '%s⚠ warnings only — likely user-side blockers or transients%s\n' "$YLW" "$RST"
  exit 1
else
  printf '%s✓ cluster clean%s\n' "$GRN" "$RST"
  exit 0
fi
