package xrd

// XServiceMonitor defines the CompositeResourceDefinition for service monitoring requests.
#XServiceMonitor: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xservicemonitors.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XServiceMonitor"
			plural: "xservicemonitors"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a ServiceMonitor for Prometheus scraping."
				properties: spec: {
					type:        "object"
					description: "ServiceMonitor settings and ownership metadata."
					properties: {
						name: {
							type:        "string"
							description: "ServiceMonitor name to create."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Namespace where the ServiceMonitor will be created."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						selector: {
							type:        "object"
							description: "Label selector for target Services."
							additionalProperties: {type: "string"}
						}
						endpoints: {
							type:        "array"
							description: "Scrape endpoints configuration."
							items: {type: "object"}
							minItems: 1
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
							description: "Team or service that owns this ServiceMonitor."
						}
					}
					required: ["name", "namespace", "selector", "endpoints", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xServiceMonitor: #XServiceMonitor
