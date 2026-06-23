package compositions

// StorageClassComposition maps an XStorageClass request to a Kubernetes StorageClass.
#StorageClassComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "storageclass-standard"
		labels: {
			"crossplane.io/xrd":    "xstorageclasses.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XStorageClass"
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
					name: "storageclass"
					base: {
						apiVersion: "kubernetes.crossplane.io/v1alpha2"
						kind:       "Object"
						spec: {
							deletionPolicy: "Orphan"
							providerConfigRef: {
								name: "in-cluster"
							}
							forProvider: manifest: {
								apiVersion: "storage.k8s.io/v1"
								kind:       "StorageClass"
								metadata: {}
								parameters: {}
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
							fromFieldPath: "spec.provisioner"
							toFieldPath:   "spec.forProvider.manifest.provisioner"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.parameters"
							toFieldPath:   "spec.forProvider.manifest.parameters"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.reclaimPolicy"
							toFieldPath:   "spec.forProvider.manifest.reclaimPolicy"
							policy: {
								fromFieldPath: "Optional"
							}
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.volumeBindingMode"
							toFieldPath:   "spec.forProvider.manifest.volumeBindingMode"
							policy: {
								fromFieldPath: "Optional"
							}
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.allowVolumeExpansion"
							toFieldPath:   "spec.forProvider.manifest.allowVolumeExpansion"
							policy: {
								fromFieldPath: "Optional"
							}
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.mountOptions"
							toFieldPath:   "spec.forProvider.manifest.mountOptions"
							policy: {
								fromFieldPath: "Optional"
							}
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.allowedTopologies"
							toFieldPath:   "spec.forProvider.manifest.allowedTopologies"
							policy: {
								fromFieldPath: "Optional"
							}
						},
					]
				}]
			}
		}]
	}
}

storageClassComposition: #StorageClassComposition
