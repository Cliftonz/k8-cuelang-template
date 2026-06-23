package render

#RoleBindingInput: {
	name:      string
	namespace: string
	tier:      string
	cluster:   string
	owner:     string
	roleRef: {
		apiGroup: "rbac.authorization.k8s.io"
		kind:     "Role" | "ClusterRole"
		name:     string
	}
	subjects: [...{
		kind:       "User" | "Group" | "ServiceAccount"
		name:       string
		apiGroup?:  string
		namespace?: string
	}]
}

#RenderRoleBinding: {
	in: #RoleBindingInput
	out: {
		apiVersion: "rbac.authorization.k8s.io/v1"
		kind:       "RoleBinding"
		metadata: {
			name:      in.name
			namespace: in.namespace
			labels: {
				"app.kubernetes.io/managed-by": "k8-infra"
				"app.kubernetes.io/part-of":    "platform"
				"infra.k8/tier":                in.tier
				"infra.k8/cluster":             in.cluster
				"infra.k8/owner":               in.owner
			}
		}
		roleRef:  in.roleRef
		subjects: in.subjects
	}
}
