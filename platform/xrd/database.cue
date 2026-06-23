package xrd

// XDatabase defines the CompositeResourceDefinition for database provisioning.
#XDatabase: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xdatabases.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XDatabase"
			plural: "xdatabases"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a managed database instance."
				properties: spec: {
					type:        "object"
					description: "Database settings and ownership metadata."
					properties: {
						name: {
							type:        "string"
							description: "Database name to create."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						engine: {
							type:        "string"
							description: "Database engine (e.g., postgres, mysql)."
						}
						version: {
							type:        "string"
							description: "Database engine version."
						}
						size: {
							type:        "string"
							description: "Instance size or SKU."
						}
						storageGB: {
							type:        "integer"
							description: "Allocated storage size in GB."
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
							description: "Team or service that owns this database."
						}
					}
					required: ["name", "engine", "version", "size", "storageGB", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xDatabase: #XDatabase
