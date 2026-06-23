package compositions

// IngressComposition maps an XIngress claim to a Kubernetes Ingress resource.
#IngressComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "ingress-standard"
		labels: {
			"crossplane.io/xrd":    "xingresses.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XIngress"
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
					name: "ingress"
					base: {
						apiVersion: "kubernetes.crossplane.io/v1alpha2"
						kind:       "Object"
						spec: {
							providerConfigRef: {
								name: "in-cluster"
							}
							forProvider: manifest: {
								apiVersion: "networking.k8s.io/v1"
								kind:       "Ingress"
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
									rules: [{
										host: ""
										http: {
											paths: [{
												path:     "/"
												pathType: "Prefix"
												backend: {
													service: {
														name: ""
														port: {
															number: 80
														}
													}
												}
											}]
										}
									}]
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
							fromFieldPath: "spec.host"
							toFieldPath:   "spec.forProvider.manifest.spec.rules[0].host"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.serviceName"
							toFieldPath:   "spec.forProvider.manifest.spec.rules[0].http.paths[0].backend.service.name"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.servicePort"
							toFieldPath:   "spec.forProvider.manifest.spec.rules[0].http.paths[0].backend.service.port.number"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.ingressClassName"
							toFieldPath:   "spec.forProvider.manifest.spec.ingressClassName"
							policy: {
								fromFieldPath: "Optional"
							}
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.tlsSecretName"
							toFieldPath:   "spec.forProvider.manifest.spec.tls[0].secretName"
							policy: {
								fromFieldPath: "Optional"
							}
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.host"
							toFieldPath:   "spec.forProvider.manifest.spec.tls[0].hosts[0]"
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
						// Merge caller-supplied annotations (e.g. external-dns
						// target override, traefik router middlewares) onto the
						// Ingress. Optional + MergeObjects so absence is fine
						// and existing chart-set annotations stay.
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.annotations"
							toFieldPath:   "spec.forProvider.manifest.metadata.annotations"
							policy: {
								fromFieldPath: "Optional"
								toFieldPath:   "MergeObjects"
							}
						},
					]
				}]
			}
		}]
	}
}

ingressComposition: #IngressComposition
