package compositions

// CronJobComposition maps an XCronJob claim to a Kubernetes CronJob.
#CronJobComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "cronjob-standard"
		labels: {
			"crossplane.io/xrd":    "xcronjobs.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XCronJob"
		}
		mode: "Pipeline"
		pipeline: [{
			step: "patch-and-transform"
			functionRef: name: "crossplane-contrib-function-patch-and-transform"
			input: {
				apiVersion: "pt.fn.crossplane.io/v1beta1"
				kind:       "Resources"
				resources: [{
					name: "cronjob"
					base: {
						apiVersion: "kubernetes.crossplane.io/v1alpha2"
						kind:       "Object"
						spec: {
							providerConfigRef: name: "in-cluster"
							forProvider: manifest: {
								apiVersion: "batch/v1"
								kind:       "CronJob"
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

cronJobComposition: #CronJobComposition
