package xrd

// XWorkloadIdentity defines the CompositeResourceDefinition for workload identity bindings.
#XWorkloadIdentity: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xworkloadidentities.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XWorkloadIdentity"
			plural: "xworkloadidentities"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a workload identity binding for a service account."
				properties: spec: {
					type:        "object"
					description: "Workload identity settings and ownership metadata."
					properties: {
						name: {
							type:        "string"
							description: "Binding name to create."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Namespace of the ServiceAccount."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						serviceAccountName: {
							type:        "string"
							description: "ServiceAccount to bind."
						}
						provider: {
							type:        "string"
							description: "Cloud provider for workload identity (aws, gcp, azure)."
						}
						identityRef: {
							type:        "string"
							description: "Provider-specific identity reference (e.g., role ARN)."
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
							description: "Team or service that owns this binding."
						}
					}
					required: ["name", "namespace", "serviceAccountName", "provider", "identityRef", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xWorkloadIdentity: #XWorkloadIdentity
