package compositions

// MetalLBPoolComposition maps an XMetalLBPool claim to a pair of
// kubernetes.crossplane.io/Object resources wrapping a MetalLB
// IPAddressPool and a matching L2Advertisement.
#MetalLBPoolComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "metallbpool-standard"
		labels: {
			"crossplane.io/xrd":    "xmetallbpools.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XMetalLBPool"
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
				resources: [
					{
						name: "ipaddresspool"
						base: {
							apiVersion: "kubernetes.crossplane.io/v1alpha2"
							kind:       "Object"
							spec: {
								providerConfigRef: name: "in-cluster"
								forProvider: manifest: {
									apiVersion: "metallb.io/v1beta1"
									kind:       "IPAddressPool"
									metadata: {
										name:      ""
										namespace: ""
										labels: {
											"app.kubernetes.io/managed-by": "k8-infra"
											"app.kubernetes.io/part-of":    "platform"
											"infra.k8/tier":                ""
											"infra.k8/cluster":             ""
											"infra.k8/owner":               ""
										}
									}
									spec: {
										addresses: []
										autoAssign:    true
										avoidBuggyIPs: true
									}
								}
							}
						}
						patches: [
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.name", toFieldPath: "spec.forProvider.manifest.metadata.name"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.namespace", toFieldPath: "spec.forProvider.manifest.metadata.namespace"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.addresses", toFieldPath: "spec.forProvider.manifest.spec.addresses"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.autoAssign", toFieldPath: "spec.forProvider.manifest.spec.autoAssign", policy: fromFieldPath: "Optional"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.avoidBuggyIPs", toFieldPath: "spec.forProvider.manifest.spec.avoidBuggyIPs", policy: fromFieldPath: "Optional"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.tier", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/tier\"]"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.cluster", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/cluster\"]"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.owner", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/owner\"]"},
						]
					},
					{
						name: "l2advertisement"
						base: {
							apiVersion: "kubernetes.crossplane.io/v1alpha2"
							kind:       "Object"
							spec: {
								providerConfigRef: name: "in-cluster"
								forProvider: manifest: {
									apiVersion: "metallb.io/v1beta1"
									kind:       "L2Advertisement"
									metadata: {
										name:      ""
										namespace: ""
										labels: {
											"app.kubernetes.io/managed-by": "k8-infra"
											"app.kubernetes.io/part-of":    "platform"
											"infra.k8/tier":                ""
											"infra.k8/cluster":             ""
											"infra.k8/owner":               ""
										}
									}
									spec: {
										ipAddressPools: []
									}
								}
							}
						}
						patches: [
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.name", toFieldPath: "spec.forProvider.manifest.metadata.name"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.namespace", toFieldPath: "spec.forProvider.manifest.metadata.namespace"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.name", toFieldPath: "spec.forProvider.manifest.spec.ipAddressPools[0]"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.tier", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/tier\"]"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.cluster", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/cluster\"]"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.owner", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/owner\"]"},
						]
					},
				]
			}
		}]
	}
}

metallbPoolComposition: #MetalLBPoolComposition
