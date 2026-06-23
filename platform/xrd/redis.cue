package xrd

// XRedis defines the CompositeResourceDefinition for Redis provisioning.
#XRedis: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xredises.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XRedis"
			plural: "xredises"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a managed Redis instance."
				properties: spec: {
					type:        "object"
					description: "Redis settings and ownership metadata."
					properties: {
						name: {
							type:        "string"
							description: "Redis instance name."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						version: {
							type:        "string"
							description: "Redis version."
						}
						size: {
							type:        "string"
							description: "Instance size or SKU."
						}
						nodeCount: {
							type:        "integer"
							description: "Number of nodes in the Redis cluster."
						}
						networkRef: {
							type:        "string"
							description: "Network or VPC reference for placement."
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
							description: "Team or service that owns this Redis instance."
						}
					}
					required: ["name", "version", "size", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xRedis: #XRedis
