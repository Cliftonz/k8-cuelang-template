package xrd

// XKelosAgentConfig defines the CompositeResourceDefinition for Kelos AgentConfig provisioning.
#XKelosAgentConfig: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xkelosagentconfigs.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XKelosAgentConfig"
			plural: "xkelosagentconfigs"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a Kelos AgentConfig defining an AI agent persona."
				properties: spec: {
					type:        "object"
					description: "Desired AgentConfig settings and placement metadata."
					properties: {
						name: {
							type:        "string"
							description: "AgentConfig resource name."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Namespace where the AgentConfig will be created (usually kelos-system)."
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
							description:                            "AgentConfig spec (systemPrompt, skills, etc.)."
							"x-kubernetes-preserve-unknown-fields": true
						}
					}
					required: ["name", "namespace", "tier", "cluster", "owner", "config"]
				}
			}
		}]
	}
}

xKelosAgentConfig: #XKelosAgentConfig
