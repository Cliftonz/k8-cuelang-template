package compositions

// NamespacePolicyComposition maps an XNamespacePolicy claim to a bundle of
// namespace-scoped policies (ResourceQuota, NetworkPolicy, LimitRange).
#NamespacePolicyComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "namespacepolicy-standard"
		labels: {
			"crossplane.io/xrd":    "xnamespacepolicies.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XNamespacePolicy"
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
						name: "default-deny-networkpolicy"
						base: {
							apiVersion: "kubernetes.crossplane.io/v1alpha2"
							kind:       "Object"
							spec: {
								providerConfigRef: {
									name: "in-cluster"
								}
								forProvider: manifest: {
									apiVersion: "networking.k8s.io/v1"
									kind:       "NetworkPolicy"
									metadata: {
										labels: {
											"app.kubernetes.io/managed-by": "k8-infra"
											"app.kubernetes.io/part-of":    "policy"
											"infra.k8/tier":                ""
											"infra.k8/cluster":             ""
											"infra.k8/owner":               ""
										}
									}
									spec: {
										podSelector: {}
										policyTypes: ["Ingress", "Egress"]
										egress: [{
											to: []
											ports: [{
												protocol: "UDP"
												port:     53
											}, {
												protocol: "TCP"
												port:     53
											}]
										}]
									}
								}
							}
						}
						patches: [
							{
								type:          "FromCompositeFieldPath"
								fromFieldPath: "spec.namespace"
								toFieldPath:   "spec.forProvider.manifest.metadata.namespace"
							},
							{
								type: "CombineFromComposite"
								combine: {
									variables: [{fromFieldPath: "spec.name"}]
									strategy: "string"
									string: {fmt: "%s-default-deny"}
								}
								toFieldPath: "spec.forProvider.manifest.metadata.name"
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
					},
					{
						name: "limitrange"
						base: {
							apiVersion: "kubernetes.crossplane.io/v1alpha2"
							kind:       "Object"
							spec: {
								providerConfigRef: {
									name: "in-cluster"
								}
								forProvider: manifest: {
									apiVersion: "v1"
									kind:       "LimitRange"
									metadata: {
										labels: {
											"app.kubernetes.io/managed-by": "k8-infra"
											"app.kubernetes.io/part-of":    "policy"
											"infra.k8/tier":                ""
											"infra.k8/cluster":             ""
											"infra.k8/owner":               ""
										}
									}
									spec: {
										limits: [{
											type: "Container"
											defaultRequest: {
												cpu:    "100m"
												memory: "128Mi"
											}
											default: {
												cpu:    "500m"
												memory: "512Mi"
											}
										}]
									}
								}
							}
						}
						patches: [
							{
								type:          "FromCompositeFieldPath"
								fromFieldPath: "spec.namespace"
								toFieldPath:   "spec.forProvider.manifest.metadata.namespace"
							},
							{
								type: "CombineFromComposite"
								combine: {
									variables: [{fromFieldPath: "spec.name"}]
									strategy: "string"
									string: {fmt: "%s-limitrange"}
								}
								toFieldPath: "spec.forProvider.manifest.metadata.name"
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
					},
				]
			}
		}]
	}
}

namespacePolicyComposition: #NamespacePolicyComposition
