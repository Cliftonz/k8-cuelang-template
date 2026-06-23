package compositions

#ServersTransportComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "serverstransport-standard"
		labels: {
			"crossplane.io/xrd":    "xserverstransports.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XServersTransport"
		}
		mode: "Pipeline"
		pipeline: [{
			step: "patch-and-transform"
			functionRef: name: "crossplane-contrib-function-patch-and-transform"
			input: {
				apiVersion: "pt.fn.crossplane.io/v1beta1"
				kind:       "Resources"
				resources: [{
					name: "serverstransport"
					base: {
						apiVersion: "kubernetes.crossplane.io/v1alpha2"
						kind:       "Object"
						spec: {
							providerConfigRef: name: "in-cluster"
							forProvider: manifest: {
								apiVersion: "traefik.io/v1alpha1"
								kind:       "ServersTransport"
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
									insecureSkipVerify: false
								}
							}
						}
					}
					patches: [
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.name", toFieldPath: "spec.forProvider.manifest.metadata.name"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.namespace", toFieldPath: "spec.forProvider.manifest.metadata.namespace"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.insecureSkipVerify", toFieldPath: "spec.forProvider.manifest.spec.insecureSkipVerify", policy: fromFieldPath: "Optional"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.tier", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/tier\"]"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.cluster", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/cluster\"]"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.owner", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/owner\"]"},
					]
				}]
			}
		}]
	}
}

serversTransportComposition: #ServersTransportComposition
