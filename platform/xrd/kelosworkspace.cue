package xrd

// XKelosWorkspace defines the CompositeResourceDefinition for Kelos Workspace provisioning.
#XKelosWorkspace: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xkelosworkspaces.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XKelosWorkspace"
			plural: "xkelosworkspaces"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a Kelos Workspace linking a Git repo to the agent system."
				properties: spec: {
					type:        "object"
					description: "Desired Workspace settings and placement metadata."
					properties: {
						name: {
							type:        "string"
							description: "Workspace resource name."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Namespace where the Workspace will be created (usually kelos-system)."
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
							description:                            "Workspace spec (repo, ref, secretRef, etc.)."
							"x-kubernetes-preserve-unknown-fields": true
						}
					}
					required: ["name", "namespace", "tier", "cluster", "owner", "config"]
				}
			}
		}]
	}
}

xKelosWorkspace: #XKelosWorkspace
