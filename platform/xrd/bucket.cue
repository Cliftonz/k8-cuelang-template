package xrd

// XBucket defines the CompositeResourceDefinition for object storage buckets.
#XBucket: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xbuckets.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XBucket"
			plural: "xbuckets"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request an object storage bucket."
				properties: spec: {
					type:        "object"
					description: "Bucket settings and ownership metadata."
					properties: {
						name: {
							type:        "string"
							description: "Bucket name to create."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						region: {
							type:        "string"
							description: "Bucket region."
						}
						versioning: {
							type:        "boolean"
							description: "Whether to enable versioning."
						}
						encryption: {
							type:        "string"
							description: "Encryption mode or key reference."
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
							description: "Team or service that owns this bucket."
						}
					}
					required: ["name", "region", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xBucket: #XBucket
