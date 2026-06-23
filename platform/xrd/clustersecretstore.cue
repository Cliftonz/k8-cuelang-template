package xrd

// XClusterSecretStore defines the CompositeResourceDefinition for
// ESO ClusterSecretStore provisioning. A ClusterSecretStore is a cluster-scoped
// secret backend (e.g., OpenBao, Vault, AWS SSM) that can be referenced by
// ExternalSecret and ClusterExternalSecret resources from any namespace.
#XClusterSecretStore: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xclustersecretstores.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XClusterSecretStore"
			plural: "xclustersecretstores"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a ClusterSecretStore backed by an external secret manager."
				properties: spec: {
					type:        "object"
					description: "Desired ClusterSecretStore configuration and ownership metadata."
					properties: {
						name: {
							type:        "string"
							description: "ClusterSecretStore resource name."
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
							description:                            "ClusterSecretStore spec (provider, retrySettings, etc.)."
							"x-kubernetes-preserve-unknown-fields": true
						}
					}
					required: ["name", "cluster", "owner", "config"]
				}
			}
		}]
	}
}

xClusterSecretStore: #XClusterSecretStore
