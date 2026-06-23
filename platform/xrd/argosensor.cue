package xrd

// XArgoSensor defines the CompositeResourceDefinition for Argo Events Sensor provisioning.
#XArgoSensor: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xargosensors.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XArgoSensor"
			plural: "xargosensors"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request an Argo Events Sensor for event correlation and triggering."
				properties: spec: {
					type:        "object"
					description: "Desired Sensor settings and placement metadata."
					properties: {
						name: {
							type:        "string"
							description: "Sensor resource name."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Namespace where the Sensor will be created."
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
							description:                            "Sensor spec (dependencies, triggers, etc.)."
							"x-kubernetes-preserve-unknown-fields": true
						}
					}
					required: ["name", "namespace", "tier", "cluster", "owner", "config"]
				}
			}
		}]
	}
}

xArgoSensor: #XArgoSensor
