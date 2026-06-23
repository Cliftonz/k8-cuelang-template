package compositions

// NamespaceComposition maps an XNamespace claim to a concrete Kubernetes
// Namespace resource with standard labels and annotations applied.
#NamespaceComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "namespace-standard"
		labels: {
			"crossplane.io/xrd":    "xnamespaces.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XNamespace"
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
					name: "namespace"
					base: {
						apiVersion: "kubernetes.crossplane.io/v1alpha2"
						kind:       "Object"
						spec: {
							providerConfigRef: {
								name: "in-cluster"
							}
							forProvider: manifest: {
								apiVersion: "v1"
								kind:       "Namespace"
								metadata: {
									labels: {
										"app.kubernetes.io/managed-by": "k8-infra"
										"app.kubernetes.io/part-of":    "platform"
										"infra.k8/tier":                ""
										"infra.k8/cluster":             ""
										"infra.k8/owner":               ""
									}
								}
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
						// Merge caller-supplied labels (e.g. pod-security.kubernetes.io/*)
						// on top of the platform-managed labels above. fromFieldPath
						// is Optional because spec.labels is not required;
						// toFieldPath: MergeObjects keeps existing keys instead
						// of replacing the whole map.
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.labels"
							toFieldPath:   "spec.forProvider.manifest.metadata.labels"
							policy: {
								fromFieldPath: "Optional"
								toFieldPath:   "MergeObjects"
							}
						},
					]
				}]
			}
		}]
	}
}

namespaceComposition: #NamespaceComposition
