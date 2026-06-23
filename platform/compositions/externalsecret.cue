package compositions

// ExternalSecretComposition maps an XExternalSecret claim to an ESO ExternalSecret resource.
#ExternalSecretComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "externalsecret-standard"
		labels: {
			"crossplane.io/xrd":    "xexternalsecrets.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XExternalSecret"
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
					name: "externalsecret"
					base: {
						apiVersion: "kubernetes.crossplane.io/v1alpha2"
						kind:       "Object"
						spec: {
							providerConfigRef: {
								name: "in-cluster"
							}
							forProvider: manifest: {
								apiVersion: "external-secrets.io/v1beta1"
								kind:       "ExternalSecret"
								metadata: {
									labels: {
										"app.kubernetes.io/managed-by": "k8-infra"
										"app.kubernetes.io/part-of":    "platform"
										"infra.k8/tier":                ""
										"infra.k8/cluster":             ""
										"infra.k8/owner":               ""
									}
								}
								spec: {
									secretStoreRef: {
										name: ""
										// All preview ExternalSecrets reference the cluster-scoped
										// OpenBao ClusterSecretStore.
										kind: "ClusterSecretStore"
									}
									refreshInterval: "1h"
									target: {
										name: ""
									}
									// Neither `data` nor `dataFrom` in the base —
									// they're injected by the patches below, and ESO's
									// admission webhook rejects requests where one is
									// present-but-empty. Each XR claim must set at
									// least one of `spec.data` or `spec.dataFrom`.
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
							fromFieldPath: "spec.namespace"
							toFieldPath:   "spec.forProvider.manifest.metadata.namespace"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.name"
							toFieldPath:   "spec.forProvider.manifest.spec.target.name"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.secretStoreRef"
							toFieldPath:   "spec.forProvider.manifest.spec.secretStoreRef.name"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.refreshInterval"
							toFieldPath:   "spec.forProvider.manifest.spec.refreshInterval"
							policy: {
								fromFieldPath: "Optional"
							}
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.data"
							toFieldPath:   "spec.forProvider.manifest.spec.data"
							policy: {
								fromFieldPath: "Optional"
							}
						},
						{
							// Optional bulk-discover mode. ESO will sync EVERY key
							// at the referenced remote path into the produced Secret.
							// Use this for env-var-as-secret patterns where the
							// operator drops new keys into OpenBao and expects them
							// to appear automatically in the pod env.
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.dataFrom"
							toFieldPath:   "spec.forProvider.manifest.spec.dataFrom"
							policy: {
								fromFieldPath: "Optional"
							}
						},
						{
							// Optional ESO target.template — only emitted when claim sets it.
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.template"
							toFieldPath:   "spec.forProvider.manifest.spec.target.template"
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

externalSecretComposition: #ExternalSecretComposition
