package xrd

// XGithubRepositoryWebhook defines the CompositeResourceDefinition for
// declaratively-managed GitHub repository webhooks. Wraps the
// crossplane-contrib-provider-upjet-github RepositoryWebhook resource.
#XGithubRepositoryWebhook: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xgithubrepositorywebhooks.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XGithubRepositoryWebhook"
			plural: "xgithubrepositorywebhooks"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a Crossplane-managed GitHub webhook on a example-org repository."
				properties: spec: {
					type:        "object"
					description: "Desired webhook settings."
					properties: {
						name: {
							type:        "string"
							description: "RepositoryWebhook resource name (k8s side)."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						repository: {
							type:        "string"
							description: "GitHub repo (owner inferred from ProviderConfig)."
						}
						events: {
							type:        "array"
							description: "GitHub event types to subscribe."
							items: type: "string"
						}
						urlSecretRef: {
							type:        "object"
							description: "Secret holding the webhook destination URL."
							properties: {
								name: type:      "string"
								key: type:       "string"
								namespace: type: "string"
							}
							required: ["name", "key", "namespace"]
						}
						secretSecretRef: {
							type:        "object"
							description: "Secret holding the webhook signing secret."
							properties: {
								name: type:      "string"
								key: type:       "string"
								namespace: type: "string"
							}
							required: ["name", "key", "namespace"]
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
					}
					required: ["name", "repository", "events", "urlSecretRef", "secretSecretRef", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xGithubRepositoryWebhook: #XGithubRepositoryWebhook
