package xrd

// XKyvernoPolicy defines the CompositeResourceDefinition for Kyverno ClusterPolicy provisioning.
#XKyvernoPolicy: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xkyvernopolicies.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XKyvernoPolicy"
			plural: "xkyvernopolicies"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a Kyverno ClusterPolicy with standard metadata and ownership labels."
				properties: spec: {
					type:        "object"
					description: "Kyverno policy settings and ownership metadata."
					example: {
						name: "require-team-contact"
						policy: {
							rules: [...]
						}
						tier:    "dev"
						cluster: "new-dev"
						owner:   "platform-team"
					}
					"x-docs": {
						provider: "provider-kubernetes"
						behavior: [
							"Creates or updates a Kyverno ClusterPolicy.",
							"Deletion behavior follows the composition's deletion policy.",
						]
						gotchas: [
							"ClusterPolicies are cluster-scoped; changes affect all namespaces.",
						]
					}
					properties: {
						name: {
							type:        "string"
							description: "ClusterPolicy name to create."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						policy: {
							type:                                   "object"
							description:                            "Kyverno policy spec to apply."
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
							description: "Team or service that owns this policy."
						}
					}
					required: ["name", "policy", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xKyvernoPolicy: #XKyvernoPolicy
