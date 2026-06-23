package preview

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
	{
		name:    "argo-events-sa-role"
		cluster: C.name
		owner:   "platform-team"
		rules: [
			{
				apiGroups: ["batch"]
				resources: ["jobs"]
				verbs: ["create", "get", "list", "watch"]
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
		]
	},

	// Preview reaper — lists namespaces/Applications and deletes orphaned preview namespaces.
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
				verbs: ["get", "list"]
			},
		]
	},

	// OpenBao bootstrap — needs to create/update the openbao-keys Secret in
	// its own namespace. Scoped to the openbao namespace via a RoleBinding.
	{
		name:    "openbao-bootstrap"
		cluster: C.name
		owner:   "platform-team"
		rules: [{
			apiGroups: [""]
			resources: ["secrets"]
			verbs: ["get", "create", "update", "patch"]
		}]
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

	// feature-orchestrator — used by the feature-review-orchestrator
	// Sensor Job to create Kelos Tasks (tier-2 reviewers, fixer) and
	// read Task status. Also needs to list reviews on PRs — that's done
	// via gh api, not k8s, so no GitHub-side RBAC needed.
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
]
