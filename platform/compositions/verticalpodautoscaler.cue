package compositions

// VerticalPodAutoscalerComposition maps an XVerticalPodAutoscaler claim
// to an autoscaling.k8s.io/v1 VerticalPodAutoscaler via provider-kubernetes.
#VerticalPodAutoscalerComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "verticalpodautoscaler-standard"
		labels: {
			"crossplane.io/xrd":    "xverticalpodautoscalers.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XVerticalPodAutoscaler"
		}
		mode: "Pipeline"
		pipeline: [{
			step: "patch-and-transform"
			functionRef: name: "crossplane-contrib-function-patch-and-transform"
			input: {
				apiVersion: "pt.fn.crossplane.io/v1beta1"
				kind:       "Resources"
				resources: [{
					name: "vpa"
					base: {
						apiVersion: "kubernetes.crossplane.io/v1alpha2"
						kind:       "Object"
						spec: {
							providerConfigRef: name: "in-cluster"
							forProvider: manifest: {
								apiVersion: "autoscaling.k8s.io/v1"
								kind:       "VerticalPodAutoscaler"
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
									targetRef: {
										apiVersion: ""
										kind:       ""
										name:       ""
									}
									updatePolicy: updateMode: "Off"
								}
							}
						}
					}
					patches: [
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.name", toFieldPath: "spec.forProvider.manifest.metadata.name"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.namespace", toFieldPath: "spec.forProvider.manifest.metadata.namespace"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.tier", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/tier\"]"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.cluster", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/cluster\"]"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.owner", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/owner\"]"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.targetRef.apiVersion", toFieldPath: "spec.forProvider.manifest.spec.targetRef.apiVersion"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.targetRef.kind", toFieldPath: "spec.forProvider.manifest.spec.targetRef.kind"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.targetRef.name", toFieldPath: "spec.forProvider.manifest.spec.targetRef.name"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.updateMode", toFieldPath: "spec.forProvider.manifest.spec.updatePolicy.updateMode", policy: fromFieldPath: "Optional"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.resourcePolicy", toFieldPath: "spec.forProvider.manifest.spec.resourcePolicy", policy: fromFieldPath: "Optional"},
					]
				}]
			}
		}]
	}
}

verticalPodAutoscalerComposition: #VerticalPodAutoscalerComposition
