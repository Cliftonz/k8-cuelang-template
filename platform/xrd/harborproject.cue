package xrd

// XHarborProject defines the CompositeResourceDefinition for Harbor projects.
#XHarborProject: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xharborprojects.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XHarborProject"
			plural: "xharborprojects"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a Harbor project for proxy cache usage."
				properties: spec: {
					type:        "object"
					description: "Project settings and placement metadata."
					properties: {
						name: {
							type:        "string"
							description: "Harbor project name."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						registryRef: {
							type:        "string"
							description: "Registry resource name used for proxy cache."
						}
						public: {
							type:        "boolean"
							description: "Whether the project is public."
						}
						vulnerabilityScanning: {
							type:        "boolean"
							description: "Enable vulnerability scanning on push."
						}
						autoSbomGeneration: {
							type:        "boolean"
							description: "Enable automatic SBOM generation."
						}
						enableContentTrust: {
							type:        "boolean"
							description: "Enable Harbor content trust."
						}
						enableContentTrustCosign: {
							type:        "boolean"
							description: "Enable Cosign content trust."
						}
						deletionPolicy: {
							type:        "string"
							description: "Whether to delete or orphan the external project on removal."
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
					required: ["name", "registryRef", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xHarborProject: #XHarborProject
