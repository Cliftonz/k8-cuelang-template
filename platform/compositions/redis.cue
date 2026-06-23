package compositions

// RedisComposition maps an XRedis claim to a Helm-based Redis deployment.
#RedisComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "redis-standard"
		labels: {
			"crossplane.io/xrd":    "xredises.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XRedis"
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
					name: "release"
					base: {
						apiVersion: "helm.crossplane.io/v1beta1"
						kind:       "Release"
						metadata: {
							name: "redis"
						}
						spec: {
							providerConfigRef: {
								name: "in-cluster"
							}
							rollbackLimit: 3
							forProvider: {
								chart: {
									name:       "redis"
									repository: "https://charts.bitnami.com/bitnami"
									version:    "20.6.0"
								}
								namespace: "databases"
								values: {}
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
							fromFieldPath: "spec.version"
							toFieldPath:   "spec.forProvider.values.image.tag"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.size"
							toFieldPath:   "spec.forProvider.values.master.resources.requests.memory"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.nodeCount"
							toFieldPath:   "spec.forProvider.values.replica.replicaCount"
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

redisComposition: #RedisComposition
