package xrd

// XLogSink defines the CompositeResourceDefinition for log sink requests.
#XLogSink: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xlogsinks.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XLogSink"
			plural: "xlogsinks"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a log sink configuration."
				properties: spec: {
					type:        "object"
					description: "Log sink settings and ownership metadata."
					properties: {
						name: {
							type:        "string"
							description: "Log sink name to create."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Namespace for log sink resources."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						backend: {
							type:        "string"
							description: "Log backend type (e.g., elastic, loki, cloudwatch)."
						}
						config: {
							type:                                   "object"
							description:                            "Backend configuration payload."
							"x-kubernetes-preserve-unknown-fields": true
						}
						selector: {
							type:        "object"
							description: "Label selector for workload log inclusion."
							additionalProperties: {type: "string"}
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
							description: "Team or service that owns this log sink."
						}
					}
					required: ["name", "namespace", "backend", "config", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xLogSink: #XLogSink
