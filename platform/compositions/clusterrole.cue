package compositions

// ClusterRoleComposition maps an XClusterRole claim to a Kubernetes ClusterRole.
#ClusterRoleComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "clusterrole-standard"
		labels: {
			"crossplane.io/xrd":    "xclusterroles.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XClusterRole"
		}
		mode: "Pipeline"
		pipeline: [{
			step: "patch-and-transform"
			functionRef: name: "crossplane-contrib-function-patch-and-transform"
			input: {
				apiVersion: "pt.fn.crossplane.io/v1beta1"
				kind:       "Resources"
				resources: [{
					name: "clusterrole"
					base: {
						apiVersion: "kubernetes.crossplane.io/v1alpha2"
						kind:       "Object"
						spec: {
							providerConfigRef: name: "in-cluster"
							forProvider: manifest: {
								apiVersion: "rbac.authorization.k8s.io/v1"
								kind:       "ClusterRole"
								metadata: labels: {
									"app.kubernetes.io/managed-by": "k8-infra"
									"app.kubernetes.io/part-of":    "platform"
									"infra.k8/cluster":             ""
									"infra.k8/owner":               ""
								}
								rules: []
							}
						}
					}
					patches: [
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.name", toFieldPath: "spec.forProvider.manifest.metadata.name"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.cluster", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/cluster\"]"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.owner", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/owner\"]"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.rules", toFieldPath: "spec.forProvider.manifest.rules"},
					]
				}]
			}
		}]
	}
}

clusterRoleComposition: #ClusterRoleComposition
