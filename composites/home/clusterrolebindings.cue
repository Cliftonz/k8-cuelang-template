package home

let C = cluster

// ClusterRoleBindings for resources that need cluster-wide permissions.
clusterRoleBindings: [
	// eso-session-watchdog — clustersecretstores are cluster-scoped, so
	// the watchdog SA needs a ClusterRoleBinding (not a namespaced
	// RoleBinding) even though it only patches one deployment.
	{
		name:    "eso-session-watchdog"
		cluster: C.name
		owner:   "platform-team"
		roleRef: {
			apiGroup: "rbac.authorization.k8s.io"
			kind:     "ClusterRole"
			name:     "eso-session-watchdog"
		}
		subjects: [{
			kind:      "ServiceAccount"
			name:      "eso-session-watchdog"
			namespace: "external-secrets"
		}]
	},

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

	// argo-sensor-error-watchdog — read pods + pod/log + ConfigMaps in
	// argo-events to scan sensor pods for level=error log entries.
	// Cluster binding for simplicity; only the argo-events SA is the
	// subject so scope is effectively that one namespace.
	{
		name:    "argo-sensor-error-watchdog"
		cluster: C.name
		owner:   "platform-team"
		roleRef: {
			apiGroup: "rbac.authorization.k8s.io"
			kind:     "ClusterRole"
			name:     "argo-sensor-error-watchdog"
		}
		subjects: [{
			kind:      "ServiceAccount"
			name:      "argo-sensor-error-watchdog"
			namespace: "argo-events"
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

	// claude-oauth-refresher: cluster-wide because reads
	// openbao/openbao-keys from a different namespace.
	{
		name:    "claude-oauth-refresher"
		cluster: C.name
		owner:   "platform-team"
		roleRef: {
			apiGroup: "rbac.authorization.k8s.io"
			kind:     "ClusterRole"
			name:     "claude-oauth-refresher"
		}
		subjects: [{
			kind:      "ServiceAccount"
			name:      "claude-oauth-refresher"
			namespace: "kelos-system"
		}]
	},

	// velero-restore-drill — needs cluster-wide ns create/delete +
	// velero.io CR manage. Cluster-scoped because the test ns is
	// created/destroyed on each run.
	{
		name:    "velero-restore-drill"
		cluster: C.name
		owner:   "platform-team"
		roleRef: {
			apiGroup: "rbac.authorization.k8s.io"
			kind:     "ClusterRole"
			name:     "velero-restore-drill"
		}
		subjects: [{
			kind:      "ServiceAccount"
			name:      "velero-restore-drill"
			namespace: "velero"
		}]
	},

	// ai-cost-aggregator: cluster-scoped Tasks + Pods + Pod logs.
	{
		name:    "ai-cost-aggregator"
		cluster: C.name
		owner:   "platform-team"
		roleRef: {
			apiGroup: "rbac.authorization.k8s.io"
			kind:     "ClusterRole"
			name:     "ai-cost-aggregator"
		}
		subjects: [{
			kind:      "ServiceAccount"
			name:      "ai-cost-aggregator"
			namespace: "kelos-system"
		}]
	},

	// jarvy-tool-discovery: create Kelos Tasks for missing tools.
	{
		name:    "jarvy-tool-discovery"
		cluster: C.name
		owner:   "platform-team"
		roleRef: {
			apiGroup: "rbac.authorization.k8s.io"
			kind:     "ClusterRole"
			name:     "jarvy-tool-discovery"
		}
		subjects: [{
			kind:      "ServiceAccount"
			name:      "jarvy-tool-discovery"
			namespace: "kelos-system"
		}]
	},
]
