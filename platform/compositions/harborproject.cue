package compositions

// HarborProjectComposition maps an XHarborProject claim to a Harbor Project resource.
#HarborProjectComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "harborproject-standard"
		labels: {
			"crossplane.io/xrd":    "xharborprojects.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XHarborProject"
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
					name: "project"
					base: {
						apiVersion: "project.harbor.crossplane.io/v1alpha1"
						kind:       "Project"
						metadata: {
							name: "harbor-project"
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
								name:                     ""
								public:                   false
								vulnerabilityScanning:    true
								autoSbomGeneration:       false
								enableContentTrust:       false
								enableContentTrustCosign: false
								registryIdRef: {
									name: ""
								}
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
							fromFieldPath: "spec.public"
							toFieldPath:   "spec.forProvider.public"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.vulnerabilityScanning"
							toFieldPath:   "spec.forProvider.vulnerabilityScanning"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.autoSbomGeneration"
							toFieldPath:   "spec.forProvider.autoSbomGeneration"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.enableContentTrust"
							toFieldPath:   "spec.forProvider.enableContentTrust"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.enableContentTrustCosign"
							toFieldPath:   "spec.forProvider.enableContentTrustCosign"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.registryRef"
							toFieldPath:   "spec.forProvider.registryIdRef.name"
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

harborProjectComposition: #HarborProjectComposition
