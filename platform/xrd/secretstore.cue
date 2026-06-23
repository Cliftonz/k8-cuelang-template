package xrd

// XSecretStore defines the CompositeResourceDefinition for secret store configuration.
#XSecretStore: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xsecretstores.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XSecretStore"
			plural: "xsecretstores"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a secret store configuration for use by external secrets."
				properties: spec: {
					type:        "object"
					description: "Secret store settings and ownership metadata."
					properties: {
						name: {
							type:        "string"
							description: "Secret store name to create."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Namespace for the secret store."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						provider: {
							type:        "string"
							description: "Secret store provider type (e.g., aws, gcp, azure, vault)."
						}
						config: {
							type:                                   "object"
							description:                            "Provider-specific configuration payload."
							"x-kubernetes-preserve-unknown-fields": true
						}
						tier: {
							type:        "string"
							description: "Deployment tier."
							enum: ["dev", "staging", "production"]
						}
						cluster: {
							type:        "string"
							description: "Target cluster name."
						}
						owner: {
							type:        "string"
							description: "Team or service that owns this secret store."
						}
					}
					required: ["name", "namespace", "provider", "config", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xSecretStore: #XSecretStore
