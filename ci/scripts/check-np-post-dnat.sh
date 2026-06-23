#!/usr/bin/env bash
# Post-DNAT NetworkPolicy gap auditor.
#
# Cilium evaluates NetworkPolicies AFTER Service DNAT, so the policy sees
# the pod's actual containerPort, not the Service port. If a Service maps
# :80 → pod :8080 and the destination NP only allows port 80, every request
# through that Service is silently dropped — no entry in `cilium-dbg
# monitor --type drop` on the source.
#
# This trap has hit the home cluster three times in one week (coder-traffic,
# oauth-proxy-traffic, plus the original 14-hour outage). See
# docs/troubleshooting-2026-05-14-cluster-recovery.md and the memory entry
# feedback_cilium_np_port_post_dnat.md.
#
# What this script does:
#   1. Lists every Ingress object in the cluster
#   2. For each Ingress, resolves the backend Service's port → targetPort,
#      including named ports (looking up the actual containerPort on the
#      backing pod)
#   3. Determines the SOURCE namespace based on ingressClassName
#      (cloudflare-tunnel → cloudflared, anything else → traefik)
#   4. Checks the DESTINATION namespace's NPs: is there any Ingress rule
#      that matches the source ns AND allows the post-DNAT pod port?
#   5. Flags every Ingress where the answer is no
#
# Exit codes:
#   0  no gaps found
#   1  at least one Ingress would be silently dropped
#   2  kubectl/jq unavailable, can't connect, etc.
#
# Usage:
#   ./ci/scripts/check-np-post-dnat.sh           # audit current context
#   ./ci/scripts/check-np-post-dnat.sh --verbose # show OK paths too

set -uo pipefail

VERBOSE=0
if [[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]]; then
  VERBOSE=1
fi

command -v kubectl >/dev/null || { echo "kubectl not on PATH" >&2; exit 2; }
command -v jq      >/dev/null || { echo "jq not on PATH" >&2; exit 2; }

kubectl cluster-info >/dev/null 2>&1 || {
  echo "kubectl cannot reach the API server" >&2
  exit 2
}

gaps=0
checks=0

# Resolve a Service's port to its actual pod containerPort (numeric).
# Echoes the port, or nothing if it can't be resolved.
resolve_target_port() {
  local ns="$1" svc="$2" svc_port="$3"
  local svc_json
  svc_json=$(kubectl -n "$ns" get svc "$svc" -o json 2>/dev/null) || return
  local tp
  tp=$(echo "$svc_json" | jq -r --argjson p "$svc_port" \
    '.spec.ports[]? | select(.port == $p) | .targetPort')
  [[ -z "$tp" || "$tp" == "null" ]] && return

  if [[ "$tp" =~ ^[0-9]+$ ]]; then
    echo "$tp"
    return
  fi

  # Named port — look it up via the pod selector
  local sel
  sel=$(echo "$svc_json" | jq -r \
    '.spec.selector // {} | to_entries | map("\(.key)=\(.value)") | join(",")')
  [[ -z "$sel" ]] && return  # ExternalName, headless, etc.

  kubectl -n "$ns" get pod -l "$sel" -o json 2>/dev/null | jq -r --arg pname "$tp" '
    .items[0].spec.containers[]? | .ports[]? |
    select(.name == $pname) | .containerPort
  ' | head -1
}

# Check whether the destination namespace's NPs admit a request from
# source_ns to pod_port. Echoes "ok" or "gap".
check_admission() {
  local source_ns="$1" dest_ns="$2" pod_port="$3"
  local nps_json
  nps_json=$(kubectl -n "$dest_ns" get networkpolicy -o json 2>/dev/null)

  local has_ingress
  has_ingress=$(echo "$nps_json" | jq \
    '[.items[] | select((.spec.policyTypes // []) | index("Ingress"))] | length')
  if [[ "$has_ingress" == "0" ]]; then
    # No Ingress-type NP in the destination ns → default-allow
    echo ok
    return
  fi

  echo "$nps_json" | jq -r --arg src "$source_ns" --argjson tp "$pod_port" '
    [.items[] |
      select((.spec.policyTypes // []) | index("Ingress")) |
      .spec.ingress // [] | .[] |
      (.from // []) as $froms |
      (.ports // []) as $ports |
      (
        (($froms | length) == 0) or
        ([$froms[]? | (.namespaceSelector.matchLabels."kubernetes.io/metadata.name" // "") == $src] | any)
      ) as $src_match |
      select($src_match) |
      (
        (($ports | length) == 0) or
        ([$ports[]? | .port == $tp] | any)
      )
    ] | if any then "ok" else "gap" end
  '
}

while IFS=$'\t' read -r src ns name svc port; do
  [[ -z "$ns" ]] && continue
  checks=$((checks + 1))

  pod_port=$(resolve_target_port "$ns" "$svc" "$port")
  if [[ -z "$pod_port" ]]; then
    # Service is ExternalName or otherwise un-resolvable; skip
    [[ "$VERBOSE" == 1 ]] && echo "skip: $src → $ns/$svc:$port (unresolvable targetPort)"
    continue
  fi

  result=$(check_admission "$src" "$ns" "$pod_port")
  if [[ "$result" == "gap" ]]; then
    echo "GAP: ingress $ns/$name routes $src → $svc:$port (pod :$pod_port) — destination NP drops post-DNAT"
    gaps=$((gaps + 1))
  elif [[ "$VERBOSE" == 1 ]]; then
    echo "ok:  $src → $ns/$svc:$port (pod :$pod_port)"
  fi
done < <(kubectl get ingress -A -o json | jq -r '
  .items[] |
  (if .spec.ingressClassName == "cloudflare-tunnel" then "cloudflared" else "traefik" end) as $src |
  .metadata.namespace as $ns |
  .metadata.name    as $name |
  .spec.rules[]? | .http.paths[]? |
  "\($src)\t\($ns)\t\($name)\t\(.backend.service.name)\t\(.backend.service.port.number // 0)"
')

if [[ "$gaps" -gt 0 ]]; then
  echo ""
  echo "FAIL: $gaps post-DNAT NP gap(s) across $checks ingress backend(s)."
  echo "Each gap is a silent drop — Cilium does NOT log these on the source."
  echo "Fix: add the pod's containerPort to the destination NP's ingress.ports."
  echo "See docs/troubleshooting-2026-05-14-cluster-recovery.md."
  exit 1
fi

echo "OK: $checks ingress backend(s) audited, 0 post-DNAT NP gaps."
exit 0
