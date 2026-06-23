package xrd

// XCronJob defines the CompositeResourceDefinition for Kubernetes CronJob provisioning.
#XCronJob: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xcronjobs.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XCronJob"
			plural: "xcronjobs"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a Kubernetes CronJob with standard labels and ownership metadata."
				properties: spec: {
					type:        "object"
					description: "Desired CronJob settings and placement metadata."
					properties: {
						name: {
							type:        "string"
							description: "CronJob resource name."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Namespace where the CronJob will be created."
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
							description:                            "CronJob spec (schedule, jobTemplate, etc.)."
							"x-kubernetes-preserve-unknown-fields": true
						}
					}
					required: ["name", "namespace", "tier", "cluster", "owner", "config"]
				}
			}
		}]
	}
}

xCronJob: #XCronJob
