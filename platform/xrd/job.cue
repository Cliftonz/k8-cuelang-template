package xrd

// XJob defines the CompositeResourceDefinition for Kubernetes Job provisioning.
// Use for one-shot bootstrap tasks (e.g., configuring OpenBao auth, seeding
// databases, registering webhooks). For recurring work use XCronJob instead.
#XJob: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xjobs.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XJob"
			plural: "xjobs"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a Kubernetes Job with standard labels and ownership metadata."
				properties: spec: {
					type:        "object"
					description: "Desired Job settings and placement metadata."
					properties: {
						name: {
							type:        "string"
							description: "Job resource name."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Namespace where the Job will be created."
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
							description:                            "Job spec (template, backoffLimit, activeDeadlineSeconds, etc.)."
							"x-kubernetes-preserve-unknown-fields": true
						}
					}
					required: ["name", "namespace", "tier", "cluster", "owner", "config"]
				}
			}
		}]
	}
}

xJob: #XJob
