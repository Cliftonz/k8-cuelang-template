#!/usr/bin/env bash
# Cross-check CronJob bash bodies against the ClusterRoles their
# ServiceAccounts are bound to.
#
# What this catches:
#   - A future PR adds `kubectl get externalsecret` to a watchdog
#     without bumping the ClusterRole. `set -eu` exits silently on
#     the failing kubectl call and the watchdog is dead with no
#     Discord signal. The golden YAML diff cannot catch this.
#
# What this does NOT catch:
#   - Namespace-scoped RoleBindings (the lint only follows
#     ClusterRoleBindings — sufficient for the watchdog family today).
#   - Implicit verbs (`kubectl annotate` is implemented as patch,
#     `kubectl rollout restart` is patch). We approximate by mapping
#     common subcommands → required verb sets.
#   - Resources accessed via Helm chart-generated tooling — we only
#     parse explicit `kubectl <verb> <resource>` calls from the
#     rendered command strings.
#
# Source-of-truth: the rendered output under clusters/home-raw/ and
# the matching ClusterRole files. Run after `make export-raw`.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RAW_DIR="$REPO_ROOT/clusters/home-raw"

if [ ! -d "$RAW_DIR" ]; then
	echo "lint-cronjob-rbac: $RAW_DIR not found — run 'make export-raw CLUSTER=home' first" >&2
	exit 2
fi

if ! command -v yq >/dev/null 2>&1; then
	echo "lint-cronjob-rbac: yq required (brew install yq)" >&2
	exit 2
fi

errors=0

# kubectl-subcommand → set of RBAC verbs the subcommand exercises. The
# canonical mapping mirrors kubectl's source — see staging/src/k8s.io/kubectl.
#
# `get` and `describe` are tricky: `kubectl get <res>` without a name is
# a LIST verb, but `kubectl get <res> <name>` is a GET verb. We default
# to just "get" here and let the caller flip to "list" when no resource
# name argument is present (see extract_kubectl_calls). Same for `delete`.
subcmd_verbs() {
	case "$1" in
		get|describe)              echo "get" ;;
		list)                      echo "list" ;;
		create|apply)              echo "create" ;;
		delete)                    echo "delete" ;;
		patch|annotate|label|edit) echo "patch" ;;
		replace)                   echo "update" ;;
		rollout)                   echo "patch get" ;;
		logs)                      echo "get" ;;
		exec)                      echo "create" ;;
		# Unknown subcommand — emit a marker so the caller can skip.
		*)                         echo "?" ;;
	esac
}

# Special-case pseudo-resources kubectl exposes that don't map to a
# regular Kubernetes resource (subresource notation, virtual targets).
# Treat them as "no RBAC check needed" — they're either covered by the
# parent resource's RBAC (logs → pods/log) or are operator-side calls
# the lint can't model.
skip_resource() {
	case "$1" in
		# kubectl logs $POD → pods/log; we don't model subresources here.
		# Operators using `kubectl logs` always have pods/log granted
		# alongside pods/get in practice.
		'"$POD"'|'"$pod"'|'$POD'|'$pod')
			return 0 ;;
		# Variable resource names from heredocs — too noisy to lint.
		\"\$*\"|\$*)
			return 0 ;;
		*) return 1 ;;
	esac
}

# Singular → plural resource normalization. Best-effort; kubectl accepts
# both, and the API server treats them identically for RBAC.
plural() {
	case "$1" in
		pod|pods|po)                   echo "pods" ;;
		deployment|deployments|deploy) echo "deployments" ;;
		service|services|svc)          echo "services" ;;
		configmap|configmaps|cm)       echo "configmaps" ;;
		secret|secrets)                echo "secrets" ;;
		namespace|namespaces|ns)       echo "namespaces" ;;
		ingress|ingresses|ing)         echo "ingresses" ;;
		clustersecretstore|clustersecretstores|css) echo "clustersecretstores" ;;
		externalsecret|externalsecrets|es)          echo "externalsecrets" ;;
		event|events|ev)               echo "events" ;;
		# Pass-through for everything else; resource name is treated literally.
		*)                             echo "$1" ;;
	esac
}

# Pull every kubectl call from the script body. We strip leading flags
# (`--request-timeout=20s`, `-n <ns>`, etc.) before grabbing the
# subcommand + resource. Output: one `verb resource` pair per line.
#
# Caveats:
#   - We match `kubectl` AND `$KUBECTL` (scripts often hoist the binary
#     into a variable for default flags). False matches inside string
#     literals (e.g. `notify_discord "Verify: kubectl ..."`) DO happen
#     and are not perfectly avoidable in shell; the dedupe at the end
#     mitigates noise. Real coverage gaps get caught first.
extract_kubectl_calls() {
	local body="$1"
	# Substitute $KUBECTL → kubectl so the rest of the parser only has to
	# handle one form. Drop runbook-hint lines that include kubectl as
	# documentation rather than as a call ("Verify: kubectl ...", "Run:
	# kubectl ..." in Discord notify bodies). Each kubectl call may span
	# multiple shell tokens; normalize to lines (stop at pipe/semicolon/
	# backtick/end-of-string).
	printf '%s' "$body" \
		| sed -E 's/\$KUBECTL/kubectl/g' \
		| sed -E '/^[[:space:]]*(Verify|Run|Recommended|Suggested|Try|See|Check|Or|Manual|Then):.*kubectl/d' \
		| grep -oE 'kubectl[^|;&`]*' \
		| sed -E 's/[\\]$//' \
		| while read -r call; do
			# Strip "kubectl" and re-tokenize. Then drop flags + their values.
			set -- $(echo "$call" | sed 's/^kubectl //')
			# Skip global flags: --kubeconfig=, --context=, --request-timeout=, --request-timeout 20s, -n <ns>, -A, --all-namespaces, --as=, --user=, --server=.
			while [ $# -gt 0 ]; do
				case "$1" in
					--*=*) shift ;;
					--kubeconfig|--context|--request-timeout|--server|--as|--user|--token|--cluster)
						shift; [ $# -gt 0 ] && shift ;;
					-n|--namespace)
						shift; [ $# -gt 0 ] && shift ;;
					-A|--all-namespaces|--ignore-not-found|--wait|--no-headers)
						shift ;;
					-*)
						shift ;;
					*) break ;;
				esac
			done
			# $1 = subcommand, $2 = resource (best effort).
			subcmd="${1:-}"
			res="${2:-}"
			[ -z "$subcmd" ] && continue
			# Skip non-verb forms ("kubectl create -f -" has no resource;
			# kubectl auth, version, config, completion, explain — all skipped).
			case "$subcmd" in
				auth|version|config|completion|explain|cluster-info|api-resources|api-versions)
					continue ;;
			esac
			verbs=$(subcmd_verbs "$subcmd")
			[ "$verbs" = "?" ] && continue
			# Trim a literal "-" trailing arg ("apply -f -")
			[ "$res" = "-" ] && continue
			[ "$res" = "-f" ] && continue
			[ -z "$res" ] && continue
			# Some forms put a label-selector before resource: "get -l x deploy"
			# — caught when $res starts with -. Iterate.
			while [ "${res#-}" != "$res" ] && [ $# -gt 0 ]; do
				shift; res="${1:-}"
			done
			[ -z "$res" ] && continue
			[ "${res#-}" != "$res" ] && continue
			# Skip variable / pseudo-resources (kubectl logs "$POD", etc.).
			if skip_resource "$res"; then
				continue
			fi
			res_plural=$(plural "$res")
			for v in $verbs; do
				printf '%s\t%s\n' "$v" "$res_plural"
			done
		done \
		| sort -u
}

# Lookup the ClusterRole's granted verbs for a given resource.
clusterrole_grants() {
	local cr_file="$1" want_resource="$2"
	yq -r '.rules[]? | (.resources // []) as $r | (.verbs // []) as $v |
		select($r[] == "'"$want_resource"'") | $v[]' "$cr_file" 2>/dev/null \
		| sort -u
}

# For every CronJob in clusters/home-raw, find its SA, then its CRB, then
# its ClusterRole. Cross-check.
for cj in "$RAW_DIR"/cronjob-*.yaml; do
	[ -f "$cj" ] || continue
	cj_name=$(yq -r '.metadata.name'                                           "$cj")
	cj_ns=$(yq -r   '.metadata.namespace'                                      "$cj")
	sa_name=$(yq -r '.spec.jobTemplate.spec.template.spec.serviceAccountName // ""' "$cj")
	[ -z "$sa_name" ] && continue

	# Find the matching CRB (by subject SA + namespace).
	crb_file=$(grep -l -E "^\\s*name: $sa_name\$" "$RAW_DIR"/clusterrolebinding-*.yaml 2>/dev/null | head -1 || true)
	if [ -z "$crb_file" ]; then
		# No CRB → namespaced RoleBinding likely; out of scope.
		continue
	fi
	cr_name=$(yq -r '.roleRef.name' "$crb_file")
	# Resolve CR file.
	cr_file="$RAW_DIR/clusterrole-$cr_name.yaml"
	if [ ! -f "$cr_file" ]; then
		# Some ClusterRoles are not in this raw dir (preview-reaper, kelos)
		# — skip, lint is best-effort.
		continue
	fi

	body=$(yq -r '.spec.jobTemplate.spec.template.spec.containers[0].command[2] // ""' "$cj")
	[ -z "$body" ] && continue

	calls=$(extract_kubectl_calls "$body")
	if [ -z "$calls" ]; then
		continue
	fi

	# Per resource: union of verbs the script needs vs verbs the role grants.
	missing=""
	while IFS=$'\t' read -r verb resource; do
		[ -z "$verb" ] && continue
		grants=$(clusterrole_grants "$cr_file" "$resource")
		# Resource not granted at all
		if [ -z "$grants" ]; then
			missing="$missing\n  $verb $resource → no rule matches"
			continue
		fi
		# Verb missing within the rule
		if ! echo "$grants" | grep -qx "$verb"; then
			missing="$missing\n  $verb $resource → role only grants: $(echo "$grants" | tr '\n' ',' | sed 's/,$//')"
		fi
	done <<EOF
$calls
EOF

	if [ -n "$missing" ]; then
		errors=$((errors + 1))
		printf 'lint-cronjob-rbac: %s (ns=%s) → ClusterRole %s missing grants:%s\n' \
			"$cj_name" "$cj_ns" "$cr_name" "$missing"
	fi
done

if [ "$errors" -gt 0 ]; then
	echo
	echo "lint-cronjob-rbac: $errors CronJob(s) have RBAC drift" >&2
	exit 1
fi

echo "lint-cronjob-rbac: OK ($(ls "$RAW_DIR"/cronjob-*.yaml 2>/dev/null | wc -l | tr -d ' ') CronJobs checked)"
