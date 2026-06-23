package home

let C = cluster

roleBindings: [
	// Argo Events service account — needs permissions to create Jobs
	// (sync-preview, spawn-agent) in the argo-events namespace and
	// read Applications in the argocd namespace.
	{
		name:      "argo-events-job-creator"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		roleRef: {
			apiGroup: "rbac.authorization.k8s.io"
			kind:     "ClusterRole"
			name:     "argo-events-sa-role"
		}
		subjects: [{
			kind:      "ServiceAccount"
			name:      "argo-events-sa"
			namespace: "argo-events"
		}]
	},

	// Argo Events SA again — needs to create kelos.dev/Task resources
	// in kelos-system (feature-ideator, feature-implementer, the review
	// tier sensors all spawn Tasks there). Same ClusterRole as
	// argo-events-job-creator; bound into kelos-system instead of
	// argo-events so the cross-namespace Task create succeeds.
	{
		name:      "argo-events-task-creator"
		namespace: "kelos-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		roleRef: {
			apiGroup: "rbac.authorization.k8s.io"
			kind:     "ClusterRole"
			name:     "argo-events-sa-role"
		}
		subjects: [{
			kind:      "ServiceAccount"
			name:      "argo-events-sa"
			namespace: "argo-events"
		}]
	},

	// NOTE: The preview-reaper binding is a ClusterRoleBinding (see clusterrolebindings.cue)
	// because the reaper needs cluster-wide namespace list/delete permissions.

	// OpenBao bootstrap Job — reads/writes the openbao-keys Secret in the
	// openbao namespace only. Namespace-scoped binding.
	{
		name:      "openbao-bootstrap"
		namespace: "openbao"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		roleRef: {
			apiGroup: "rbac.authorization.k8s.io"
			kind:     "ClusterRole"
			name:     "openbao-bootstrap"
		}
		subjects: [{
			kind:      "ServiceAccount"
			name:      "openbao-bootstrap"
			namespace: "openbao"
		}]
	},

	// OpenBao readonly-FS watchdog — scoped to openbao ns so the CronJob
	// can read openbao-0 logs and delete the pod to remount when the
	// Longhorn engine flips the PVC RO.
	{
		name:      "openbao-readonly-watchdog"
		namespace: "openbao"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		roleRef: {
			apiGroup: "rbac.authorization.k8s.io"
			kind:     "ClusterRole"
			name:     "openbao-readonly-watchdog"
		}
		subjects: [{
			kind:      "ServiceAccount"
			name:      "openbao-readonly-watchdog"
			namespace: "openbao"
		}]
	},


	// github-app-token-refresh: per-namespace bindings of the shared
	// ClusterRole onto each ns-scoped ServiceAccount. The binding limits
	// the SA's secret-write reach to its own namespace only.
	{
		name:      "github-app-token-refresh"
		namespace: "kelos-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		roleRef: {
			apiGroup: "rbac.authorization.k8s.io"
			kind:     "ClusterRole"
			name:     "github-app-token-refresh"
		}
		subjects: [{
			kind:      "ServiceAccount"
			name:      "github-app-token-refresh"
			namespace: "kelos-system"
		}]
	},
	{
		name:      "github-app-token-refresh-events"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		roleRef: {
			apiGroup: "rbac.authorization.k8s.io"
			kind:     "ClusterRole"
			name:     "github-app-token-refresh"
		}
		subjects: [{
			kind:      "ServiceAccount"
			name:      "github-app-token-refresh-events"
			namespace: "argo-events"
		}]
	},
	// example-bot-installation token-refresh SA — same ClusterRole as above,
	// just bound to the new per-installation SA. Lives in kelos-system
	// (panel + lead-dev spawners run there).
	{
		name:      "github-app-token-refresh-example-bot"
		namespace: "kelos-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		roleRef: {
			apiGroup: "rbac.authorization.k8s.io"
			kind:     "ClusterRole"
			name:     "github-app-token-refresh"
		}
		subjects: [{
			kind:      "ServiceAccount"
			name:      "github-app-token-refresh-example-bot"
			namespace: "kelos-system"
		}]
	},
	// Argo Workflows ns binding — refresh CronJob writes the App token
	// into Secret/github-app-token in argo-workflows so build workflow
	// steps can git-clone PR HEAD and push to GHCR with App auth.
	{
		name:      "github-app-token-refresh-workflows"
		namespace: "argo-workflows"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		roleRef: {
			apiGroup: "rbac.authorization.k8s.io"
			kind:     "ClusterRole"
			name:     "github-app-token-refresh"
		}
		subjects: [{
			kind:      "ServiceAccount"
			name:      "github-app-token-refresh-workflows"
			namespace: "argo-workflows"
		}]
	},
	// argocd ns binding — refresh CronJob writes Secret/github-app-token
	// in argocd so the preview-cap-watchdog has an App token to call the
	// GH issues API with.
	{
		name:      "github-app-token-refresh-argocd"
		namespace: "argocd"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		roleRef: {
			apiGroup: "rbac.authorization.k8s.io"
			kind:     "ClusterRole"
			name:     "github-app-token-refresh"
		}
		subjects: [{
			kind:      "ServiceAccount"
			name:      "github-app-token-refresh-argocd"
			namespace: "argocd"
		}]
	},
]
