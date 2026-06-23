package xrd

// XClusterRole defines the CompositeResourceDefinition for Kubernetes ClusterRole provisioning.
#XClusterRole: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xclusterroles.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XClusterRole"
			plural: "xclusterroles"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a Kubernetes ClusterRole with standard labels and ownership metadata."
				properties: spec: {
					type:        "object"
					description: "Desired ClusterRole settings and ownership metadata."
					properties: {
						name: {
							type:        "string"
							description: "ClusterRole resource name."
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
						rules: {
							type:        "array"
							description: "RBAC policy rules for this ClusterRole."
							items: {
								type:                                   "object"
								"x-kubernetes-preserve-unknown-fields": true
							}
						}
					}
					required: ["name", "cluster", "owner", "rules"]
				}
			}
		}]
	}
}

xClusterRole: #XClusterRole
