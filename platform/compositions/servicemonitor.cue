package compositions

// ServiceMonitorComposition maps an XServiceMonitor claim to a Prometheus ServiceMonitor.
#ServiceMonitorComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "servicemonitor-standard"
		labels: {
			"crossplane.io/xrd":    "xservicemonitors.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XServiceMonitor"
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
					name: "servicemonitor"
					base: {
						apiVersion: "kubernetes.crossplane.io/v1alpha2"
						kind:       "Object"
						spec: {
							providerConfigRef: {
								name: "in-cluster"
							}
							forProvider: manifest: {
								apiVersion: "monitoring.coreos.com/v1"
								kind:       "ServiceMonitor"
								metadata: {
									labels: {
										"app.kubernetes.io/managed-by": "k8-infra"
										"app.kubernetes.io/part-of":    "monitoring"
										"infra.k8/tier":                ""
										"infra.k8/cluster":             ""
										"infra.k8/owner":               ""
									}
								}
								spec: {
									selector: {
										matchLabels: {}
									}
									endpoints: []
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
							fromFieldPath: "spec.selector"
							toFieldPath:   "spec.forProvider.manifest.spec.selector.matchLabels"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.endpoints"
							toFieldPath:   "spec.forProvider.manifest.spec.endpoints"
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

serviceMonitorComposition: #ServiceMonitorComposition
