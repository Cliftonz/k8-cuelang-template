package xrd

// XHTTPRoute defines the CompositeResourceDefinition for Gateway API HTTPRoute requests.
#XHTTPRoute: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xhttproutes.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XHTTPRoute"
			plural: "xhttproutes"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request an HTTPRoute for Gateway API routing."
				properties: spec: {
					type:        "object"
					description: "HTTPRoute settings and ownership metadata."
					properties: {
						name: {
							type:        "string"
							description: "HTTPRoute resource name to create."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Namespace where the HTTPRoute will be created."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						hostnames: {
							type:        "array"
							description: "Hostnames for the route."
							items: {type: "string"}
							minItems: 1
						}
						parentRefs: {
							type:        "array"
							description: "Gateway parent references."
							items: {type: "object"}
							minItems: 1
						}
						rules: {
							type:        "array"
							description: "HTTPRoute rules definition."
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
							description: "Team or service that owns this route."
						}
					}
					required: ["name", "namespace", "hostnames", "parentRefs", "rules", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xHTTPRoute: #XHTTPRoute
