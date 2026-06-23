package xrd

// XArgoAppProject defines the CompositeResourceDefinition for Argo CD AppProject provisioning.
#XArgoAppProject: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xargoappprojects.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XArgoAppProject"
			plural: "xargoappprojects"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request an Argo CD AppProject with scoped permissions."
				properties: spec: {
					type:        "object"
					description: "Desired AppProject settings and placement metadata."
					properties: {
						name: {
							type:        "string"
							description: "AppProject resource name."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Namespace where the AppProject will be created (usually argocd)."
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
							description:                            "AppProject spec (destinations, sourceRepos, clusterResourceWhitelist, etc.)."
							"x-kubernetes-preserve-unknown-fields": true
						}
					}
					required: ["name", "namespace", "tier", "cluster", "owner", "config"]
				}
			}
		}]
	}
}

xArgoAppProject: #XArgoAppProject
