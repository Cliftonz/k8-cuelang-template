package xrd

// XArgoApplicationSet defines the CompositeResourceDefinition for Argo CD ApplicationSet provisioning.
#XArgoApplicationSet: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xargoapplicationsets.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XArgoApplicationSet"
			plural: "xargoapplicationsets"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request an Argo CD ApplicationSet for dynamic Application generation."
				properties: spec: {
					type:        "object"
					description: "Desired ApplicationSet settings and placement metadata."
					properties: {
						name: {
							type:        "string"
							description: "ApplicationSet resource name."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Namespace where the ApplicationSet will be created (usually argocd)."
							pattern:     "^[a-z][a-z0-9-]*$"
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
							description: "Owning team or service."
						}
						config: {
							type:                                   "object"
							description:                            "ApplicationSet spec (generators, template, syncPolicy, etc.)."
							"x-kubernetes-preserve-unknown-fields": true
						}
					}
					required: ["name", "namespace", "tier", "cluster", "owner", "config"]
				}
			}
		}]
	}
}

xArgoApplicationSet: #XArgoApplicationSet
