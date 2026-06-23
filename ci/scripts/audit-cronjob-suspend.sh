#!/usr/bin/env bash
#
# Audit CronJob spec.suspend drift between the home cluster and CUE source.
#
# Why: silent CronJob suspension is a known footgun — three CronJobs
# (github-app-token-refresh, claude-oauth-refresher, kelos-oauth-watchdog)
# were suspended in-cluster for 2+ days during 2026-05, which expired the
# example-org GitHub App token and the Claude OAuth token and silently
# broke the entire ci-failure-autofix pipeline. Nothing in CUE flagged
# the suspension. This script surfaces the drift so it can be either
# resolved (un-suspend in cluster) or declared (add `suspend: true` to
# the CUE source so the rationale lives next to the code).
#
# Usage:
#   ci/scripts/audit-cronjob-suspend.sh
#   ci/scripts/audit-cronjob-suspend.sh --context talos-home
#
# Exit codes:
#   0  no drift detected (or only drift is CUE-declared suspensions)
#   1  drift detected (cluster has suspended CronJobs without CUE backing)
#   2  preflight failure (missing tool, can't reach cluster)

set -euo pipefail

CTX="${1:-}"
[[ "$CTX" == "--context" ]] && { CTX="$2"; shift 2; }
KCTL=(kubectl)
[[ -n "$CTX" ]] && KCTL+=("--context" "$CTX")

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT/.."

command -v jq        >/dev/null || { echo "missing: jq"        >&2; exit 2; }
command -v kubectl   >/dev/null || { echo "missing: kubectl"   >&2; exit 2; }

# 1. Pull cluster state — every CronJob with spec.suspend == true.
cluster_suspended=$(
  "${KCTL[@]}" get cronjob -A -o json \
    | jq -r '.items[] | select(.spec.suspend == true) | "\(.metadata.namespace)/\(.metadata.name)"' \
    | sort
)

# 2. Pull CUE-declared suspensions. The conservative form is to grep for
#    `suspend: true` in cronjobs.cue — the canonical place CronJobs are
#    declared. Any other location is unusual and intentionally surfaced
#    by failing the grep (the script will report 0 declared, the cluster
#    set will look entirely undeclared, and you investigate manually).
cue_declared=$(
  awk '
    /^[[:space:]]*name:[[:space:]]*"/ {
      match($0, /"[^"]*"/)
      cur = substr($0, RSTART+1, RLENGTH-2)
    }
    /suspend:[[:space:]]*true/ { if (cur != "") print cur }
  ' composites/home/cronjobs.cue \
    | sort -u
)

echo "── CronJob suspend drift report (cluster context: ${CTX:-current}) ──"
echo
echo "## Suspended in cluster ($(echo "$cluster_suspended" | wc -l | tr -d ' '))"
echo "$cluster_suspended" | sed 's/^/  /'
echo
echo "## Declared suspended in CUE ($(echo "$cue_declared" | wc -l | tr -d ' '))"
echo "$cue_declared" | sed 's/^/  /'
echo

# 3. Drift = cluster-suspended minus CUE-declared (matched on name only;
#    namespace stripped because CUE source isn't grouped by namespace in
#    the awk pass above).
cluster_names=$(echo "$cluster_suspended" | awk -F/ '{print $2}' | sort -u)
drift=$(comm -23 <(echo "$cluster_names") <(echo "$cue_declared"))

if [[ -z "$drift" ]]; then
  echo "✓ No drift — every cluster-suspended CronJob is declared in CUE."
  exit 0
fi

echo "## DRIFT — suspended in cluster but NOT declared in CUE"
echo "$drift" | sed 's/^/  /'
echo
echo "Resolve by either:"
echo "  1. Adding 'suspend: true' to the CronJob's entry in composites/home/cronjobs.cue"
echo "     with a comment explaining why (intentional config)."
echo "  2. Un-suspending in the cluster:"
echo "     kubectl patch cronjob <name> -n <ns> --type merge -p '{\"spec\":{\"suspend\":false}}'"
echo "  3. Letting the next 'make apply CLUSTER=home' un-suspend them (rendered CUE"
echo "     sets default suspend=false for these entries)."
exit 1
