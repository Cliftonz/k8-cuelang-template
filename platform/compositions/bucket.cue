package compositions

// BucketComposition maps an XBucket claim to an S3-compatible bucket via provider-aws
// or a generic object store Helm chart depending on the environment.
#BucketComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "bucket-standard"
		labels: {
			"crossplane.io/xrd":    "xbuckets.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XBucket"
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
					name: "bucket"
					base: {
						apiVersion: "helm.crossplane.io/v1beta1"
						kind:       "Release"
						metadata: {
							name: "bucket"
						}
						spec: {
							providerConfigRef: {
								name: "in-cluster"
							}
							rollbackLimit: 3
							forProvider: {
								chart: {
									name:       "minio"
									repository: "https://charts.min.io/"
									version:    "5.4.0"
								}
								namespace: "storage"
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
							fromFieldPath: "spec.name"
							toFieldPath:   "spec.forProvider.values.buckets[0].name"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.versioning"
							toFieldPath:   "spec.forProvider.values.buckets[0].versioning"
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

bucketComposition: #BucketComposition
