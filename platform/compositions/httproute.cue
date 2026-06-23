package compositions

// HTTPRouteComposition maps an XHTTPRoute claim to a Gateway API HTTPRoute resource.
#HTTPRouteComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "httproute-standard"
		labels: {
			"crossplane.io/xrd":    "xhttproutes.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XHTTPRoute"
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
					name: "httproute"
					base: {
						apiVersion: "kubernetes.crossplane.io/v1alpha2"
						kind:       "Object"
						spec: {
							providerConfigRef: {
								name: "in-cluster"
							}
							forProvider: manifest: {
								apiVersion: "gateway.networking.k8s.io/v1"
								kind:       "HTTPRoute"
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
									hostnames: []
									parentRefs: []
									rules: []
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
							fromFieldPath: "spec.hostnames"
							toFieldPath:   "spec.forProvider.manifest.spec.hostnames"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.parentRefs"
							toFieldPath:   "spec.forProvider.manifest.spec.parentRefs"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.rules"
							toFieldPath:   "spec.forProvider.manifest.spec.rules"
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

httpRouteComposition: #HTTPRouteComposition
