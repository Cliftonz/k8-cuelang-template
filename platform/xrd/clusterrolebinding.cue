package xrd

// XClusterRoleBinding defines the CompositeResourceDefinition for Kubernetes ClusterRoleBinding provisioning.
#XClusterRoleBinding: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xclusterrolebindings.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XClusterRoleBinding"
			plural: "xclusterrolebindings"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a Kubernetes ClusterRoleBinding with standard labels and ownership metadata."
				properties: spec: {
					type:        "object"
					description: "Desired ClusterRoleBinding settings and subject/role references."
					properties: {
						name: {
							type:        "string"
							description: "ClusterRoleBinding resource name."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						cluster: {
							type:        "string"
							description: "Target cluster name."
						}
						owner: {
							type:        "string"
							description: "Owning team or service."
						}
						roleRef: {
							type:        "object"
							description: "Reference to the ClusterRole to bind."
							properties: {
								apiGroup: {
									type:        "string"
									description: "API group of the referenced role."
								}
								kind: {
									type:        "string"
									description: "Must be ClusterRole."
									enum: ["ClusterRole"]
								}
								name: {
									type:        "string"
									description: "Name of the referenced ClusterRole."
								}
							}
							required: ["apiGroup", "kind", "name"]
						}
						subjects: {
							type:        "array"
							description: "Subjects to bind to the role."
							items: {
								type: "object"
								properties: {
									kind: {
										type: "string"
										enum: ["User", "Group", "ServiceAccount"]
									}
									name: {
										type: "string"
									}
									apiGroup: {
										type: "string"
									}
									namespace: {
										type: "string"
									}
								}
								required: ["kind", "name"]
							}
						}
					}
					required: ["name", "cluster", "owner", "roleRef", "subjects"]
				}
			}
		}]
	}
}

xClusterRoleBinding: #XClusterRoleBinding
