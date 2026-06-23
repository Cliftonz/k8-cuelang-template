package home

let C = cluster

// ClusterRoles for the preview environment system.
clusterRoles: [
	// Read-only access for Kelos AI agent pods to inspect preview namespace resources.
	// Bound per-namespace via RoleBinding in the preview Helm chart.
	// Deliberately excludes: pods/exec, secrets, delete, namespace, networkpolicy, rbac.
	{
		name:    "preview-ai-agent-reader"
		cluster: C.name
		owner:   "platform-team"
		rules: [
			{
				apiGroups: [""]
				resources: ["pods", "pods/log", "services", "configmaps", "events", "endpoints"]
				verbs: ["get", "list", "watch"]
			},
			{
				apiGroups: ["apps"]
				resources: ["deployments", "replicasets", "statefulsets"]
				verbs: ["get", "list", "watch"]
			},
			{
				apiGroups: ["networking.k8s.io"]
				resources: ["ingresses"]
				verbs: ["get", "list"]
			},
			{
				apiGroups: ["batch"]
				resources: ["jobs"]
				verbs: ["get", "list"]
			},
		]
	},

	// Argo Events SA role — creates Jobs for sync and agent-spawn triggers.
	// `delete` lets sensors clean up stuck Jobs/Tasks instead of waiting
	// on TTL; `patch` enables idempotent re-creation when deterministic
	// names collide and need spec updates.
	{
		name:    "argo-events-sa-role"
		cluster: C.name
		owner:   "platform-team"
		rules: [
			{
				apiGroups: ["batch"]
				resources: ["jobs"]
				verbs: ["create", "get", "list", "watch", "delete", "patch"]
			},
			{
				apiGroups: [""]
				resources: ["namespaces", "pods"]
				verbs: ["get", "list", "watch"]
			},
			{
				apiGroups: ["argoproj.io"]
				resources: ["applications"]
				verbs: ["get", "list"]
			},
			// Kelos Tasks — sensors (feature-ideator, -implementer, the
			// review tier sensors, code-explain) spawn kelos.dev/Task
			// resources in the kelos-system namespace. Without this rule
			// the sensor pod fails with "tasks.kelos.dev is forbidden".
			{
				apiGroups: ["kelos.dev"]
				resources: ["tasks"]
				verbs: ["create", "get", "list", "watch", "delete", "patch"]
			},
			// Argo Workflows — the preview-build sensor creates Workflow
			// CRs in argo-workflows ns when a PR is labeled `preview`. The
			// Workflow then runs BuildKit to produce the preview image.
			{
				apiGroups: ["argoproj.io"]
				resources: ["workflows"]
				verbs: ["create", "get", "list", "watch", "delete", "patch"]
			},
		]
	},

	// Preview reaper — lists namespaces/Applications, deletes orphaned
	// preview namespaces, and force-removes finalizers on Applications
	// stuck in deletion. `patch` on applications is required to clear
	// the resources-finalizer.argoproj.io when the controller fails to
	// run the prune (observed indefinitely-stuck deletions 2026-05-23).
	{
		name:    "preview-reaper"
		cluster: C.name
		owner:   "platform-team"
		rules: [
			{
				apiGroups: [""]
				resources: ["namespaces"]
				verbs: ["get", "list", "delete"]
			},
			{
				apiGroups: ["argoproj.io"]
				resources: ["applications"]
				verbs: ["get", "list", "patch"]
			},
		]
	},

	// OpenBao bootstrap — needs to create/update the openbao-keys Secret in
	// its own namespace. Scoped to the openbao namespace via a RoleBinding.
	// `resourceNames` further narrows the role to the single Secret the
	// bootstrap script ever touches.
	{
		name:    "openbao-bootstrap"
		cluster: C.name
		owner:   "platform-team"
		rules: [
			// `create` cannot be restricted by resourceNames (the resource
			// doesn't exist yet at create time). Split into two rules.
			{
				apiGroups: [""]
				resources: ["secrets"]
				verbs: ["create"]
			},
			{
				apiGroups: [""]
				resources: ["secrets"]
				resourceNames: ["openbao-keys"]
				verbs: ["get", "update", "patch"]
			},
		]
	},

	// kelos-oauth-watchdog — read the claude-code-oauth Secret annotation
	// (for token expiry) and list/get tasks.kelos.dev to detect auth-error
	// patterns. Read-only, cluster-scoped for simplicity.
	{
		name:    "kelos-oauth-watchdog"
		cluster: C.name
		owner:   "platform-team"
		rules: [
			{
				apiGroups: [""]
				resources: ["secrets"]
				verbs: ["get", "list"]
			},
			{
				apiGroups: ["kelos.dev"]
				resources: ["tasks"]
				verbs: ["get", "list"]
			},
		]
	},

	// argo-sensor-error-watchdog — list argo-events sensor pods in the
	// argo-events namespace, read their logs, and look for error-level
	// JSON lines (e.g. argo-events trigger failures that don't surface
	// at the kubectl describe / pod-status level). Bound to argo-events
	// via a namespace-scoped RoleBinding.
	{
		name:    "argo-sensor-error-watchdog"
		cluster: C.name
		owner:   "platform-team"
		rules: [
			{
				apiGroups: [""]
				resources: ["pods"]
				verbs: ["get", "list"]
			},
			{
				apiGroups: [""]
				resources: ["pods/log"]
				verbs: ["get"]
			},
			// Lock ConfigMap for alert dedup — create on first sighting
			// of an error fingerprint, get/delete to check if we've
			// already alerted in this 24h window.
			{
				apiGroups: [""]
				resources: ["configmaps"]
				verbs: ["get", "list", "create", "delete", "patch", "update"]
			},
		]
	},

	// openbao-readonly-watchdog — scans openbao-0 logs for "read-only file
	// system" errors (Longhorn engine flipping the PVC mount RO on a
	// transient blip; OpenBao keeps running but every write fails silently
	// from the FS layer). When detected, deletes openbao-0 to force a
	// remount; the auto-unseal CronJob handles re-unseal afterwards.
	{
		name:    "openbao-readonly-watchdog"
		cluster: C.name
		owner:   "platform-team"
		rules: [
			{
				apiGroups: [""]
				resources: ["pods"]
				verbs: ["get", "list", "delete"]
			},
			{
				apiGroups: [""]
				resources: ["pods/log"]
				verbs: ["get"]
			},
		]
	},

	// eso-session-watchdog — when OpenBao restarts, the
	// external-secrets controller keeps a stale session token and
	// every ClusterSecretStore goes Ready=False until the controller
	// is restarted. This watchdog checks CSS Ready status and, if any
	// has been NotReady for ≥5 min, rollout-restarts the
	// external-secrets deployment. Discord-alerts the action.
	//
	// Patch verb is scoped via resourceNames so a compromise of the
	// watchdog Pod can ONLY rolling-restart the external-secrets
	// Deployment, not arbitrary Deployments cluster-wide. list is
	// allowed cluster-wide because the script uses a label-selector
	// to find the chart's release name (so a future Helm rename
	// surfaces as an explicit Discord alert instead of silently
	// no-op'ing). list+watch can't be combined with resourceNames
	// per k8s RBAC, but list-only on apps/deployments is read-only.
	{
		name:    "eso-session-watchdog"
		cluster: C.name
		owner:   "platform-team"
		rules: [
			{
				apiGroups: ["external-secrets.io"]
				resources: ["clustersecretstores"]
				verbs: ["get", "list"]
			},
			{
				apiGroups: ["apps"]
				resources: ["deployments"]
				verbs: ["get", "list"]
			},
			{
				apiGroups: ["apps"]
				resources: ["deployments"]
				verbs: ["patch"]
				resourceNames: ["external-secrets"]
			},
		]
	},

	// feature-orchestrator — used by the panel-spawner + spawn-lead-dev
	// Jobs to create Kelos Tasks (review panel + lead-dev) and to read
	// the feature-review-killswitch ConfigMap. The lock-CM creation in
	// spawn-lead-dev also needs configmap create+delete. Reviews on PRs
	// are fetched via gh api, not k8s.
	{
		name:    "feature-orchestrator"
		cluster: C.name
		owner:   "platform-team"
		rules: [
			{
				apiGroups: ["kelos.dev"]
				resources: ["tasks"]
				verbs: ["get", "list", "create", "watch"]
			},
			{
				apiGroups: [""]
				resources: ["configmaps"]
				// get/list = killswitch read; create/delete = spawn-lead-dev's
				// per-SHA lock CM lifecycle.
				verbs: ["get", "list", "create", "delete"]
			},
		]
	},

	// quiet-hours-toggle — patches TaskSpawners (kelos.dev) to suspend
	// polling and Sensors (argoproj.io) to scale replicas to 0/1.
	// Read ConfigMap for global override. Cluster-scoped so the CronJob
	// in kelos-system can reach Sensors in argo-events.
	{
		name:    "quiet-hours-toggle"
		cluster: C.name
		owner:   "platform-team"
		rules: [
			{
				apiGroups: ["kelos.dev"]
				resources: ["taskspawners"]
				verbs: ["get", "list", "patch"]
			},
			{
				apiGroups: ["argoproj.io"]
				resources: ["sensors"]
				verbs: ["get", "list", "patch"]
			},
			{
				apiGroups: [""]
				resources: ["configmaps"]
				verbs: ["get"]
			},
		]
	},

	// velero-restore-drill — weekly CronJob that restores the latest
	// openbao backup into a throwaway namespace + verifies the secret
	// came back. Needs to manage Velero CRs in velero ns and create/
	// delete the test namespace cluster-wide.
	// Verification reads ONLY the openbao-keys Secret post-restore;
	// dropped pods/configmaps/services/pvcs to shrink blast radius.
	{
		name:    "velero-restore-drill"
		cluster: C.name
		owner:   "platform-team"
		rules: [
			// Velero CRD ops in velero ns (RoleBinding scopes to ns).
			{
				apiGroups: ["velero.io"]
				resources: ["backups", "restores"]
				verbs: ["get", "list", "watch", "create", "delete"]
			},
			// Create/delete the velero-restore-test namespace.
			{
				apiGroups: [""]
				resources: ["namespaces"]
				verbs: ["get", "list", "create", "delete"]
			},
			// Verification read — only the one Secret we assert on.
			{
				apiGroups: [""]
				resources: ["secrets"]
				resourceNames: ["openbao-keys"]
				verbs: ["get"]
			},
		]
	},

	// github-app-token-refresh — used by the per-namespace CronJob that
	// mints installation tokens for the Example Org AI GitHub App and
	// upserts them into Secret/github-app-token. Read app credentials
	// (PRIVATE_KEY etc) from secrets, write the resulting token back as
	// another secret. RoleBinding (per namespace) scopes which namespace
	// each SA can write into.
	{
		name:    "github-app-token-refresh"
		cluster: C.name
		owner:   "platform-team"
		rules: [
			{
				apiGroups: [""]
				resources: ["secrets"]
				verbs: ["get", "list", "create", "update", "patch"]
			},
		]
	},

	// ai-cost-aggregator — hourly CronJob: list Kelos Tasks, read pod
	// logs (cost / token markers), aggregate by role label, post Discord.
	// Read-only access to tasks + pods + pod logs.
	{
		name:    "ai-cost-aggregator"
		cluster: C.name
		owner:   "platform-team"
		rules: [
			{
				apiGroups: ["kelos.dev"]
				resources: ["tasks"]
				verbs: ["get", "list"]
			},
			{
				apiGroups: [""]
				resources: ["pods"]
				verbs: ["get", "list"]
			},
			{
				apiGroups: [""]
				resources: ["pods/log"]
				verbs: ["get"]
			},
		]
	},

	// jarvy-tool-discovery — daily CronJob: queries Loki for
	// tool.unsupported events, cross-references with open Jarvy PRs,
	// and CREATES Kelos Tasks to scaffold missing tools. Needs read
	// access to existing Tasks (de-dupe on jarvy.io/requested-tool
	// label so we don't re-spawn while a discoverer is still running)
	// and create access to spawn new ones.
	{
		name:    "jarvy-tool-discovery"
		cluster: C.name
		owner:   "platform-team"
		rules: [
			{
				apiGroups: ["kelos.dev"]
				resources: ["tasks"]
				verbs: ["get", "list", "create"]
			},
		]
	},

	// claude-oauth-refresher — auto-renews the Claude Code OAuth access
	// token using the stored refresh token. Needs cluster-wide secret
	// read so it can fetch the OpenBao root token from openbao/openbao-keys,
	// and patch (annotate) the ExternalSecret in kelos-system to force a
	// post-write sync. Bound cluster-wide via ClusterRoleBinding because
	// the openbao-keys read crosses namespace boundaries.
	// resourceNames pins secret reads to the single needed Secret.
	{
		name:    "claude-oauth-refresher"
		cluster: C.name
		owner:   "platform-team"
		rules: [
			{
				apiGroups: [""]
				resources: ["secrets"]
				resourceNames: ["openbao-keys"]
				verbs: ["get"]
			},
			{
				apiGroups: ["external-secrets.io"]
				resources: ["externalsecrets"]
				resourceNames: ["claude-code-oauth"]
				verbs: ["get", "patch", "update"]
			},
		]
	},
]
