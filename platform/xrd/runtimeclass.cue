package xrd

// XRuntimeClass defines the CompositeResourceDefinition for RuntimeClass requests.
#XRuntimeClass: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xruntimes.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XRuntimeClass"
			plural: "xruntimes"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a RuntimeClass configuration."
				properties: spec: {
					type:        "object"
					description: "RuntimeClass settings and ownership metadata."
					properties: {
						name: {
							type:        "string"
							description: "RuntimeClass name to create."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						handler: {
							type:        "string"
							description: "Runtime handler name."
						}
						overhead: {
							type:                                   "object"
							description:                            "Overhead settings for the runtime class."
							"x-kubernetes-preserve-unknown-fields": true
						}
						scheduling: {
							type:                                   "object"
							description:                            "Scheduling constraints for the runtime class."
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
							description: "Team or service that owns this runtime class."
						}
					}
					required: ["name", "handler", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xRuntimeClass: #XRuntimeClass
