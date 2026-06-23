package compositions

// RuntimeClassComposition maps an XRuntimeClass claim to a Kubernetes RuntimeClass.
#RuntimeClassComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "runtimeclass-standard"
		labels: {
			"crossplane.io/xrd":    "xruntimes.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XRuntimeClass"
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
					name: "runtimeclass"
					base: {
						apiVersion: "kubernetes.crossplane.io/v1alpha2"
						kind:       "Object"
						spec: {
							providerConfigRef: {
								name: "in-cluster"
							}
							forProvider: manifest: {
								apiVersion: "node.k8s.io/v1"
								kind:       "RuntimeClass"
								metadata: {
									labels: {
										"app.kubernetes.io/managed-by": "k8-infra"
										"app.kubernetes.io/part-of":    "platform"
										"infra.k8/tier":                ""
										"infra.k8/cluster":             ""
										"infra.k8/owner":               ""
									}
								}
								handler: ""
							}
						}
					}
					patches: [
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.name"
							toFieldPath:   "spec.forProvider.manifest.metadata.name"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.handler"
							toFieldPath:   "spec.forProvider.manifest.handler"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.overhead"
							toFieldPath:   "spec.forProvider.manifest.overhead"
							policy: {
								fromFieldPath: "Optional"
							}
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.scheduling"
							toFieldPath:   "spec.forProvider.manifest.scheduling"
							policy: {
								fromFieldPath: "Optional"
							}
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.tier"
							toFieldPath:   "spec.forProvider.manifest.metadata.labels[\"infra.k8/tier\"]"
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
					]
				}]
			}
		}]
	}
}

runtimeClassComposition: #RuntimeClassComposition
