package xrd

// XServiceAccount defines the CompositeResourceDefinition for service account provisioning.
#XServiceAccount: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xserviceaccounts.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XServiceAccount"
			plural: "xserviceaccounts"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a Kubernetes ServiceAccount with standard metadata."
				properties: spec: {
					type:        "object"
					description: "ServiceAccount settings and ownership metadata."
					properties: {
						name: {
							type:        "string"
							description: "ServiceAccount name to create."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Namespace where the ServiceAccount will be created."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						annotations: {
							type:        "object"
							description: "Optional annotations for the ServiceAccount."
							additionalProperties: {type: "string"}
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
							description: "Team or service that owns this service account."
						}
					}
					required: ["name", "namespace", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xServiceAccount: #XServiceAccount
