package compositions

// ObjectPatchComposition maps an XObjectPatch claim to a
// kubernetes.crossplane.io/Object with managementPolicies [Observe, Update].
//
// Because Create/Delete are omitted, the Object never creates or deletes the
// target — it only updates the fields present in the rendered manifest.
// provider-kubernetes uses server-side apply so only the annotations/labels
// we set get owned by this Object's field manager; everything else stays
// owned by the original source (e.g. Helm).
#ObjectPatchComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "objectpatch-standard"
		labels: {
			"crossplane.io/xrd":    "xobjectpatches.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XObjectPatch"
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
					name: "objectpatch"
					base: {
						apiVersion: "kubernetes.crossplane.io/v1alpha2"
						kind:       "Object"
						spec: {
							// provider-kubernetes v0.14 accepts only specific policy
							// presets. [Observe, Create, Update] = never delete the
							// target on XR deletion, but will create it if missing.
							// For a Service managed by Helm, Create is a no-op via
							// server-side apply because the name already exists.
							managementPolicies: ["Observe", "Create", "Update"]
							providerConfigRef: name: "in-cluster"
							forProvider: manifest: {
								apiVersion: ""
								kind:       ""
								metadata: {
									name: ""
									annotations: {}
									labels: {
										"app.kubernetes.io/managed-by": "k8-infra"
										"app.kubernetes.io/part-of":    "platform"
										"infra.k8/tier":                ""
										"infra.k8/cluster":             ""
										"infra.k8/owner":               ""
									}
								}
							}
						}
					}
					patches: [
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.targetRef.apiVersion"
							toFieldPath:   "spec.forProvider.manifest.apiVersion"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.targetRef.kind"
							toFieldPath:   "spec.forProvider.manifest.kind"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.targetRef.name"
							toFieldPath:   "spec.forProvider.manifest.metadata.name"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.targetRef.namespace"
							toFieldPath:   "spec.forProvider.manifest.metadata.namespace"
							policy: fromFieldPath: "Optional"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.annotations"
							toFieldPath:   "spec.forProvider.manifest.metadata.annotations"
							policy: fromFieldPath: "Optional"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.labels"
							toFieldPath:   "spec.forProvider.manifest.metadata.labels"
							policy: fromFieldPath: "Optional"
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

objectPatchComposition: #ObjectPatchComposition
