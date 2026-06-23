package compositions

// KelosAgentConfigComposition maps an XKelosAgentConfig claim to a Kelos AgentConfig.
#KelosAgentConfigComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "kelosagentconfig-standard"
		labels: {
			"crossplane.io/xrd":    "xkelosagentconfigs.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XKelosAgentConfig"
		}
		mode: "Pipeline"
		pipeline: [{
			step: "patch-and-transform"
			functionRef: name: "crossplane-contrib-function-patch-and-transform"
			input: {
				apiVersion: "pt.fn.crossplane.io/v1beta1"
				kind:       "Resources"
				resources: [{
					name: "agentconfig"
					base: {
						apiVersion: "kubernetes.crossplane.io/v1alpha2"
						kind:       "Object"
						spec: {
							providerConfigRef: name: "in-cluster"
							forProvider: manifest: {
								apiVersion: "kelos.dev/v1alpha1"
								kind:       "AgentConfig"
								metadata: labels: {
									"app.kubernetes.io/managed-by": "k8-infra"
									"app.kubernetes.io/part-of":    "platform"
									"infra.k8/tier":                ""
									"infra.k8/cluster":             ""
									"infra.k8/owner":               ""
								}
								spec: {}
							}
						}
					}
					patches: [
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.name", toFieldPath: "spec.forProvider.manifest.metadata.name"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.namespace", toFieldPath: "spec.forProvider.manifest.metadata.namespace"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.tier", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/tier\"]"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.cluster", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/cluster\"]"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.owner", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/owner\"]"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.config", toFieldPath: "spec.forProvider.manifest.spec"},
					]
				}]
			}
		}]
	}
}

kelosAgentConfigComposition: #KelosAgentConfigComposition
