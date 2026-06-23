package preview

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
]
