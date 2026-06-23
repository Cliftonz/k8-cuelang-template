package compositions

#ExposedServiceComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "exposedservice-standard"
		labels: {
			"crossplane.io/xrd":    "xexposedservices.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XExposedService"
		}
		mode: "Pipeline"
		pipeline: [{
			step: "patch-and-transform"
			functionRef: name: "crossplane-contrib-function-patch-and-transform"
			input: {
				apiVersion: "pt.fn.crossplane.io/v1beta1"
				kind:       "Resources"
				resources: [{
					name: "service"
					base: {
						apiVersion: "kubernetes.crossplane.io/v1alpha2"
						kind:       "Object"
						spec: {
							providerConfigRef: name: "in-cluster"
							forProvider: manifest: {
								apiVersion: "v1"
								kind:       "Service"
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
									annotations: {
										"omni-kube-service-exposer.sidero.dev/port":   ""
										"omni-kube-service-exposer.sidero.dev/label":  ""
										"omni-kube-service-exposer.sidero.dev/prefix": ""
									}
								}
								spec: {
									type: "ClusterIP"
									ports: [{
										name:       "http"
										port:       80
										targetPort: 80
										protocol:   "TCP"
									}]
								}
							}
						}
					}
					patches: [
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.name", toFieldPath: "spec.forProvider.manifest.metadata.name"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.namespace", toFieldPath: "spec.forProvider.manifest.metadata.namespace"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.selector", toFieldPath: "spec.forProvider.manifest.spec.selector", policy: toFieldPath: "MergeObjects"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.portName", toFieldPath: "spec.forProvider.manifest.spec.ports[0].name"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.port", toFieldPath: "spec.forProvider.manifest.spec.ports[0].port"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.targetPort", toFieldPath: "spec.forProvider.manifest.spec.ports[0].targetPort"},
						// Omni-exposer expects the port annotation as a string.
						// Use %v rather than %d — Crossplane unmarshals JSON
						// numbers as float64, and %d errors on non-int types.
						{
							type: "CombineFromComposite"
							combine: {
								variables: [{fromFieldPath: "spec.omniPort"}]
								strategy: "string"
								string: fmt: "%v"
							}
							toFieldPath: "spec.forProvider.manifest.metadata.annotations[\"omni-kube-service-exposer.sidero.dev/port\"]"
						},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.omniLabel", toFieldPath: "spec.forProvider.manifest.metadata.annotations[\"omni-kube-service-exposer.sidero.dev/label\"]"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.omniPrefix", toFieldPath: "spec.forProvider.manifest.metadata.annotations[\"omni-kube-service-exposer.sidero.dev/prefix\"]"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.tier", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/tier\"]"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.cluster", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/cluster\"]"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.owner", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/owner\"]"},
					]
				}]
			}
		}]
	}
}

exposedServiceComposition: #ExposedServiceComposition
