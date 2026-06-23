package compositions

// NodeTaintComposition maps an XNodeTaint claim to a Kubernetes Node object with taints.
#NodeTaintComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "nodetaint-standard"
		labels: {
			"crossplane.io/xrd":    "xnodetaints.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XNodeTaint"
		}
		mode: "Pipeline"
		pipeline: [{
			step: "patch-and-transform"
			functionRef: {
				name: "crossplane-contrib-function-patch-and-transform"
			}
			input: {
				apiVersion: "pt.fn.crossplane.io/v1beta1"
				kind:       "Resources"
				resources: [{
					name: "nodetaint"
					base: {
						apiVersion: "kubernetes.crossplane.io/v1alpha2"
						kind:       "Object"
						spec: {
							deletionPolicy: "Orphan"
							managementPolicies: ["Observe", "Update"]
							providerConfigRef: {
								name: "in-cluster"
							}
							forProvider: manifest: {
								apiVersion: "v1"
								kind:       "Node"
								metadata: {
									labels: {
										"app.kubernetes.io/managed-by": "k8-infra"
										"app.kubernetes.io/part-of":    "platform"
										"infra.k8/cluster":             ""
										"infra.k8/owner":               ""
									}
								}
								spec: {
									taints: []
								}
							}
						}
					}
					patches: [
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.nodeName"
							toFieldPath:   "spec.forProvider.manifest.metadata.name"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.cluster"
							toFieldPath:   "spec.forProvider.manifest.metadata.labels[\"infra.k8/cluster\"]"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.owner"
							toFieldPath:   "spec.forProvider.manifest.metadata.labels[\"infra.k8/owner\"]"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.taints"
							toFieldPath:   "spec.forProvider.manifest.spec.taints"
						},
					]
				}]
			}
		}]
	}
}

nodeTaintComposition: #NodeTaintComposition
