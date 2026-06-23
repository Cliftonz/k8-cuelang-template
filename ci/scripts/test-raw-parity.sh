#!/usr/bin/env bash
# Cross-mode parity tests for the raw-fallback feature.
#
# Two layers:
#
# (1) COUNT PARITY (fast, always runs).
#     For each composite type, asserts the number of rendered manifests in
#     raw mode matches the number of composite inputs (with a 2x multiplier
#     for the multi-resource renderers ExternalBackend and MetalLBPool).
#     Catches "renderer dropped half the inputs" silently.
#
# (2) SEMANTIC PARITY via `crossplane render` (slow, optional).
#     Runs the canonical Crossplane CLI against each (claim, composition)
#     tuple, unwraps provider-kubernetes Object wrappers, and diffs against
#     the raw-mode output. Currently SCAFFOLDED — full implementation
#     deferred. Skipped silently when the crossplane binary is missing.
#
# Usage:
#   ./ci/scripts/test-raw-parity.sh                # both clusters
#   ./ci/scripts/test-raw-parity.sh home

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

CLUSTERS=("$@")
[[ ${#CLUSTERS[@]} -eq 0 ]] && CLUSTERS=(home preview)

pass=0
fail=0

# composite-list field name → output kind(s) it produces in raw mode.
# Multi-kind entries are space-separated; a 2x list means two manifests
# per input (Service+EndpointSlice for ExternalBackend, IPAddressPool+
# L2Advertisement for MetalLBPool).
declare -A FIELD_KINDS=(
	[namespaces]="Namespace"
	[networkPolicies]="NetworkPolicy"
	[resourceQuotas]="ResourceQuota"
	[roleBindings]="RoleBinding"
	[clusterRoles]="ClusterRole"
	[clusterRoleBindings]="ClusterRoleBinding"
	[serviceAccounts]="ServiceAccount"
	[externalSecrets]="ExternalSecret"
	[clusterExternalSecrets]="ClusterExternalSecret"
	[clusterSecretStores]="ClusterSecretStore"
	[certificates]="Certificate"
	[cronJobs]="CronJob"
	[jobs]="Job"
	[kyvernoPolicies]="ClusterPolicy"
	[argoEventBuses]="EventBus"
	[argoEventSources]="EventSource"
	[argoSensors]="Sensor"
	[argoAppProjects]="AppProject"
	[argoApplicationSets]="ApplicationSet"
	[kelosWorkspaces]="Workspace"
	[kelosAgentConfigs]="AgentConfig"
	[kelosTaskSpawners]="TaskSpawner"
	[serversTransports]="ServersTransport"
	[exposedServices]="Service"
	[externalBackends]="Service EndpointSlice"
	[metallbPools]="IPAddressPool L2Advertisement"
	[storageClasses]="StorageClass"
	[ingresses]="Ingress"
	[helmReleases]="HelmRenderRequest"
	[staticSites]="ConfigMap Service Deployment"
)

count_inputs() {
	local cluster="$1" field="$2"
	cue export ./export/ -e "_allClusters[\"$cluster\"].$field" --out json 2>/dev/null \
		| jq 'length' 2>/dev/null \
		|| echo 0
}

count_kind_in_raw() {
	local cluster="$1" kind="$2"
	local out_dir="$REPO_ROOT/clusters/${cluster}-raw"
	[[ -d "$out_dir" ]] || return 0
	grep -rh "^kind: ${kind}$" "$out_dir" 2>/dev/null | wc -l | tr -d ' '
}

for cluster in "${CLUSTERS[@]}"; do
	echo "=== count parity: $cluster ==="

	# Ensure raw export is fresh (deterministic, RAW_HELM=skip).
	out_dir="$REPO_ROOT/clusters/${cluster}-raw"
	if [[ ! -d "$out_dir" ]]; then
		RAW_HELM=skip make export-raw CLUSTER="$cluster" >/dev/null
	fi

	for field in "${!FIELD_KINDS[@]}"; do
		input_count="$(count_inputs "$cluster" "$field")"
		[[ -z "$input_count" || "$input_count" == "null" ]] && input_count=0

		read -ra kinds <<< "${FIELD_KINDS[$field]}"
		for kind in "${kinds[@]}"; do
			actual="$(count_kind_in_raw "$cluster" "$kind")"
			# Sum contributions from other fields that emit the same kind
			# (e.g. exposedServices → Service AND externalBackends → Service).
			# We compute expected per-field; final assertion sums all fields
			# that produce this kind below.
			:
		done
	done

	# Sum input counts per kind, accounting for multi-emit fields.
	declare -A expected_by_kind=()
	for field in "${!FIELD_KINDS[@]}"; do
		input_count="$(count_inputs "$cluster" "$field")"
		[[ -z "$input_count" || "$input_count" == "null" ]] && input_count=0
		read -ra kinds <<< "${FIELD_KINDS[$field]}"
		for kind in "${kinds[@]}"; do
			expected_by_kind[$kind]=$(( ${expected_by_kind[$kind]:-0} + input_count ))
		done
	done

	# Assert raw output count matches expected count per kind.
	for kind in "${!expected_by_kind[@]}"; do
		expected="${expected_by_kind[$kind]}"
		actual="$(count_kind_in_raw "$cluster" "$kind")"
		if [[ "$expected" -eq "$actual" ]]; then
			echo "  PASS: $kind ($expected)"
			pass=$((pass + 1))
		else
			echo "  FAIL: $kind — expected $expected, got $actual"
			fail=$((fail + 1))
		fi
	done
	unset expected_by_kind
done

echo
echo "=== semantic parity (crossplane render) ==="
if ! command -v crossplane >/dev/null 2>&1; then
	echo "  SKIP: crossplane binary not on PATH"
	echo "  (Install crossplane CLI to enable: https://docs.crossplane.io/latest/cli/)"
else
	echo "  TODO: implement claim-by-claim crossplane render + unwrap + diff"
	echo "        against clusters/<name>-raw/. Tracked in plan Phase 5."
	echo "  SKIP: scaffold only"
fi

echo
echo "$pass passed, $fail failed"
exit "$fail"
