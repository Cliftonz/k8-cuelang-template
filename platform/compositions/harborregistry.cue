package compositions

// HarborRegistryComposition maps an XHarborRegistry claim to a Harbor Registry resource.
#HarborRegistryComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "harborregistry-standard"
		labels: {
			"crossplane.io/xrd":    "xharborregistries.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XHarborRegistry"
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
					name: "registry"
					base: {
						apiVersion: "registry.harbor.crossplane.io/v1alpha1"
						kind:       "Registry"
						metadata: {
							name: "harbor-registry"
							annotations: {
								"crossplane.io/external-name": ""
							}
							labels: {
								"app.kubernetes.io/managed-by": "k8-infra"
								"infra.k8/tier":                ""
								"infra.k8/cluster":             ""
								"infra.k8/owner":               ""
							}
						}
						spec: {
							deletionPolicy: "Orphan"
							providerConfigRef: {
								name: "default"
							}
							forProvider: {
								name:         ""
								endpointUrl:  ""
								providerName: ""
								description:  ""
								insecure:     false
							}
						}
					}
					patches: [
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.name"
							toFieldPath:   "metadata.name"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.name"
							toFieldPath:   "metadata.annotations[\"crossplane.io/external-name\"]"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.name"
							toFieldPath:   "spec.forProvider.name"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.endpointUrl"
							toFieldPath:   "spec.forProvider.endpointUrl"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.providerName"
							toFieldPath:   "spec.forProvider.providerName"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.description"
							toFieldPath:   "spec.forProvider.description"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.insecure"
							toFieldPath:   "spec.forProvider.insecure"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.deletionPolicy"
							toFieldPath:   "spec.deletionPolicy"
							policy: {
								fromFieldPath: "Optional"
							}
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.tier"
							toFieldPath:   "metadata.labels[\"infra.k8/tier\"]"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.cluster"
							toFieldPath:   "metadata.labels[\"infra.k8/cluster\"]"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.owner"
							toFieldPath:   "metadata.labels[\"infra.k8/owner\"]"
						},
					]
				}]
			}
		}]
	}
}

harborRegistryComposition: #HarborRegistryComposition
