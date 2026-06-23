package k8s

// RoleBinding defines the schema for a namespaced RoleBinding resource.
#RoleBinding: {
	apiVersion: "rbac.authorization.k8s.io/v1"
	kind:       "RoleBinding"
	metadata: #StandardMetadata & {
		namespace: string & =~"^[a-z][a-z0-9-]*$"
	}
	subjects: [...#Subject]
	roleRef: #RoleRef
}

#Subject: {
	kind:       "User" | "Group" | "ServiceAccount"
	name:       string
	apiGroup?:  "rbac.authorization.k8s.io"
	namespace?: string & =~"^[a-z][a-z0-9-]*$"
}

#RoleRef: {
	apiGroup: "rbac.authorization.k8s.io"
	kind:     "Role" | "ClusterRole"
	name:     string
}
