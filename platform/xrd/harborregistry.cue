package xrd

// XHarborRegistry defines the CompositeResourceDefinition for Harbor registry entries.
#XHarborRegistry: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xharborregistries.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XHarborRegistry"
			plural: "xharborregistries"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a Harbor registry entry for proxy cache projects."
				properties: spec: {
					type:        "object"
					description: "Registry settings and placement metadata."
					properties: {
						name: {
							type:        "string"
							description: "Registry name in Harbor."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						endpointUrl: {
							type:        "string"
							description: "External registry endpoint URL."
						}
						providerName: {
							type:        "string"
							description: "Harbor registry provider type."
							enum: [
								"alibaba",
								"artifact-hub",
								"aws",
								"azure",
								"docker-hub",
								"docker-registry",
								"gitlab",
								"github",
								"google",
								"harbor",
								"huawei",
								"jfrog",
								"quay",
							]
						}
						description: {
							type:        "string"
							description: "Optional registry description."
						}
						insecure: {
							type:        "boolean"
							description: "Skip TLS verification for the registry."
						}
						deletionPolicy: {
							type:        "string"
							description: "Whether to delete or orphan the external registry on removal."
							enum: ["Delete", "Orphan"]
						}
						tier: {
							type:        "string"
							description: "Tier used for labeling and policy selection."
							enum: ["dev", "staging", "production"]
						}
						cluster: {
							type:        "string"
							description: "Logical cluster identifier."
						}
						owner: {
							type:        "string"
							description: "Owning team or service."
						}
					}
					required: ["name", "endpointUrl", "providerName", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xHarborRegistry: #XHarborRegistry
