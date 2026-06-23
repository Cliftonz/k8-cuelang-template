package render

#ClusterRoleInput: {
	name:    string
	cluster: string
	owner:   string
	rules: [...{...}]
	tier?: string
}

#RenderClusterRole: {
	in: #ClusterRoleInput
	let _tier = *in.tier | "production"
	out: {
		apiVersion: "rbac.authorization.k8s.io/v1"
		kind:       "ClusterRole"
		metadata: {
			name: in.name
			labels: (#StandardLabels & {tier: _tier, cluster: in.cluster, owner: in.owner}).out
		}
		rules: in.rules
	}
}

#ClusterRoleBindingInput: {
	name:    string
	cluster: string
	owner:   string
	roleRef: {
		apiGroup: "rbac.authorization.k8s.io"
		kind:     "ClusterRole"
		name:     string
	}
	subjects: [...{
		kind:       "User" | "Group" | "ServiceAccount"
		name:       string
		apiGroup?:  string
		namespace?: string
	}]
	tier?: string
}

#RenderClusterRoleBinding: {
	in: #ClusterRoleBindingInput
	let _tier = *in.tier | "production"
	out: {
		apiVersion: "rbac.authorization.k8s.io/v1"
		kind:       "ClusterRoleBinding"
		metadata: {
			name: in.name
			labels: (#StandardLabels & {tier: _tier, cluster: in.cluster, owner: in.owner}).out
		}
		roleRef:  in.roleRef
		subjects: in.subjects
	}
}

#ServiceAccountInput: {
	name:      string
	namespace: string
	tier:      string
	cluster:   string
	owner:     string
}

#RenderServiceAccount: {
	in: #ServiceAccountInput
	out: {
		apiVersion: "v1"
		kind:       "ServiceAccount"
		metadata: {
			name:      in.name
			namespace: in.namespace
			labels: (#StandardLabels & {tier: in.tier, cluster: in.cluster, owner: in.owner}).out
		}
	}
}
