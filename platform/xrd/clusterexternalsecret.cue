package xrd

// XClusterExternalSecret defines the CompositeResourceDefinition for ESO ClusterExternalSecret provisioning.
#XClusterExternalSecret: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xclusterexternalsecrets.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XClusterExternalSecret"
			plural: "xclusterexternalsecrets"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a ClusterExternalSecret for cross-namespace secret distribution."
				properties: spec: {
					type:        "object"
					description: "Desired ClusterExternalSecret settings and ownership metadata."
					properties: {
						name: {
							type:        "string"
							description: "ClusterExternalSecret resource name."
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
						config: {
							type:                                   "object"
							description:                            "ClusterExternalSecret spec (namespaceSelector, externalSecretSpec, etc.)."
							"x-kubernetes-preserve-unknown-fields": true
						}
					}
					required: ["name", "cluster", "owner", "config"]
				}
			}
		}]
	}
}

xClusterExternalSecret: #XClusterExternalSecret
