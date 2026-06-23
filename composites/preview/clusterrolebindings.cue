package preview

let C = cluster

// ClusterRoleBindings for resources that need cluster-wide permissions.
clusterRoleBindings: [
	// Preview reaper — needs cluster-wide namespace list/delete and
	// Application list in argocd namespace. A namespace-scoped RoleBinding
	// cannot grant these permissions; must be a ClusterRoleBinding.
	{
		name:    "preview-reaper"
		cluster: C.name
		owner:   "platform-team"
		roleRef: {
			apiGroup: "rbac.authorization.k8s.io"
			kind:     "ClusterRole"
			name:     "preview-reaper"
		}
		subjects: [{
			kind:      "ServiceAccount"
			name:      "preview-reaper"
			namespace: "argocd"
		}]
	},

	// kelos-oauth-watchdog — Secret + Tasks read access cluster-wide
	// (the watchdog only acts on kelos-system but we model the role
	// cluster-scoped for simplicity; namespace-scoping the binding would
	// require a Role+RoleBinding pair).
	{
		name:    "kelos-oauth-watchdog"
		cluster: C.name
		owner:   "platform-team"
		roleRef: {
			apiGroup: "rbac.authorization.k8s.io"
			kind:     "ClusterRole"
			name:     "kelos-oauth-watchdog"
		}
		subjects: [{
			kind:      "ServiceAccount"
			name:      "kelos-oauth-watchdog"
			namespace: "kelos-system"
		}]
	},

	// feature-orchestrator — Tasks create/read access. Sensor Jobs
	// run in kelos-system (where Tasks live) and create new Tasks for
	// tier-2 reviewers and the fixer.
	{
		name:    "feature-orchestrator"
		cluster: C.name
		owner:   "platform-team"
		roleRef: {
			apiGroup: "rbac.authorization.k8s.io"
			kind:     "ClusterRole"
			name:     "feature-orchestrator"
		}
		subjects: [{
			kind:      "ServiceAccount"
			name:      "feature-orchestrator"
			namespace: "kelos-system"
		}]
	},

	// quiet-hours-toggle — cluster-scoped so CronJob in kelos-system
	// can patch Sensors in argo-events.
	{
		name:    "quiet-hours-toggle"
		cluster: C.name
		owner:   "platform-team"
		roleRef: {
			apiGroup: "rbac.authorization.k8s.io"
			kind:     "ClusterRole"
			name:     "quiet-hours-toggle"
		}
		subjects: [{
			kind:      "ServiceAccount"
			name:      "quiet-hours-toggle"
			namespace: "kelos-system"
		}]
	},
]
