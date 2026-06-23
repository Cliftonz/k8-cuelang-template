package xrd

// XNamespacePolicy defines the CompositeResourceDefinition for namespace policy bundles.
#XNamespacePolicy: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xnamespacepolicies.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XNamespacePolicy"
			plural: "xnamespacepolicies"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a bundle of namespace policies (quota, network policy, limits)."
				properties: spec: {
					type:        "object"
					description: "Namespace policy bundle settings and ownership metadata."
					properties: {
						name: {
							type:        "string"
							description: "Policy bundle name to create."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Target namespace for policy application."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						enableNetworkPolicy: {
							type:        "boolean"
							description: "Whether to apply the default NetworkPolicy bundle."
						}
						enableResourceQuota: {
							type:        "boolean"
							description: "Whether to apply the default ResourceQuota bundle."
						}
						enableLimitRange: {
							type:        "boolean"
							description: "Whether to apply the default LimitRange bundle."
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
							description: "Team or service that owns this policy bundle."
						}
					}
					required: ["name", "namespace", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xNamespacePolicy: #XNamespacePolicy
