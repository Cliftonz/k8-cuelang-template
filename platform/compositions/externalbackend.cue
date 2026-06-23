package compositions

// ExternalBackendComposition renders a selector-less Service plus a
// matching EndpointSlice that points at out-of-cluster IPs.
#ExternalBackendComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "externalbackend-standard"
		labels: {
			"crossplane.io/xrd":    "xexternalbackends.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XExternalBackend"
		}
		mode: "Pipeline"
		pipeline: [{
			step: "patch-and-transform"
			functionRef: name: "crossplane-contrib-function-patch-and-transform"
			input: {
				apiVersion: "pt.fn.crossplane.io/v1beta1"
				kind:       "Resources"
				resources: [
					{
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
									}
									spec: {
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
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.portName", toFieldPath: "spec.forProvider.manifest.spec.ports[0].name"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.port", toFieldPath: "spec.forProvider.manifest.spec.ports[0].port"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.targetPort", toFieldPath: "spec.forProvider.manifest.spec.ports[0].targetPort"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.protocol", toFieldPath: "spec.forProvider.manifest.spec.ports[0].protocol"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.tier", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/tier\"]"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.cluster", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/cluster\"]"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.owner", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/owner\"]"},
							{
								type:          "FromCompositeFieldPath"
								fromFieldPath: "spec.annotations"
								toFieldPath:   "spec.forProvider.manifest.metadata.annotations"
								policy: {fromFieldPath: "Optional", toFieldPath: "MergeObjects"}
							},
						]
					},
					{
						name: "endpointslice"
						base: {
							apiVersion: "kubernetes.crossplane.io/v1alpha2"
							kind:       "Object"
							spec: {
								providerConfigRef: name: "in-cluster"
								forProvider: manifest: {
									apiVersion: "discovery.k8s.io/v1"
									kind:       "EndpointSlice"
									metadata: {
										name:      ""
										namespace: ""
										labels: {
											"app.kubernetes.io/managed-by": "k8-infra"
											"app.kubernetes.io/part-of":    "platform"
											"kubernetes.io/service-name":   ""
											"infra.k8/tier":                ""
											"infra.k8/cluster":             ""
											"infra.k8/owner":               ""
										}
									}
									addressType: "IPv4"
									ports: [{
										name:     "http"
										port:     80
										protocol: "TCP"
									}]
									endpoints: [{
										addresses: []
										conditions: ready: true
									}]
								}
							}
						}
						patches: [
							// Slice name = serviceName-1; service-name label same as serviceName.
							{
								type: "CombineFromComposite"
								combine: {
									variables: [{fromFieldPath: "spec.name"}]
									strategy: "string"
									string: fmt: "%s-1"
								}
								toFieldPath: "spec.forProvider.manifest.metadata.name"
							},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.namespace", toFieldPath: "spec.forProvider.manifest.metadata.namespace"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.name", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"kubernetes.io/service-name\"]"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.portName", toFieldPath: "spec.forProvider.manifest.ports[0].name"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.targetPort", toFieldPath: "spec.forProvider.manifest.ports[0].port"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.protocol", toFieldPath: "spec.forProvider.manifest.ports[0].protocol"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.addresses", toFieldPath: "spec.forProvider.manifest.endpoints[0].addresses"},
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

externalBackendComposition: #ExternalBackendComposition
