package xrd

// XHelmRelease defines the CompositeResourceDefinition for Helm-based installs.
#XHelmRelease: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xhelmreleases.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XHelmRelease"
			plural: "xhelmreleases"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a Helm chart installation managed by the platform."
				properties: spec: {
					type:        "object"
					description: "Desired Helm release settings and placement metadata."
					example: {
						name:      "external-secrets"
						namespace: "external-secrets"
						chart: {
							name:       "external-secrets"
							repository: "https://charts.external-secrets.io"
							version:    "0.10.0"
						}
						values: {}
						tier:    "dev"
						cluster: "new-dev"
						owner:   "platform-team"
					}
					"x-docs": {
						provider: "provider-helm"
						policyRefs: []
						behavior: [
							"Installs or upgrades the chart in the target namespace.",
							"Values are passed through to Helm without validation.",
						]
						gotchas: [
							"The chart repository must be reachable from the cluster.",
							"Chart version changes will trigger an upgrade.",
						]
					}
					properties: {
						name: {
							type:        "string"
							description: "Helm release name. Must be DNS-1123 compatible."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Namespace where the Helm release will be installed."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						chart: {
							type:        "object"
							description: "Chart reference (name, repo, version) — or url for direct tarball fetch."
							properties: {
								name: {
									type:        "string"
									description: "Chart name within the repository."
								}
								repository: {
									type:        "string"
									description: "Chart repository URL."
								}
								version: {
									type:        "string"
									description: "Chart version to install."
								}
								url: {
									type:        "string"
									description: "Direct URL to chart tarball. When set, overrides name/repository/version. Use for repos with non-standard tarball naming (e.g. coder/coder uses `coder_helm_<version>.tgz` instead of `coder-<version>.tgz`, which breaks provider-helm's cache path)."
								}
							}
							required: ["name", "repository", "version"]
						}
						values: {
							type:                                   "object"
							description:                            "Values map passed to the chart (free-form)."
							"x-kubernetes-preserve-unknown-fields": true
						}
						tier: {
							type:        "string"
							description: "Tier used for labeling and policy selection."
							enum: ["dev", "staging", "production"]
						}
						cluster: {
							type:        "string"
							description: "Logical cluster identifier used for labeling and placement."
						}
						owner: {
							type:        "string"
							description: "Owning team or service for accountability and routing."
						}
					}
					required: ["name", "namespace", "chart", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xHelmRelease: #XHelmRelease
