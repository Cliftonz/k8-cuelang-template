package compositions

// ClusterRoleBindingComposition maps an XClusterRoleBinding claim to a Kubernetes ClusterRoleBinding.
#ClusterRoleBindingComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "clusterrolebinding-standard"
		labels: {
			"crossplane.io/xrd":    "xclusterrolebindings.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XClusterRoleBinding"
		}
		mode: "Pipeline"
		pipeline: [{
			step: "patch-and-transform"
			functionRef: name: "crossplane-contrib-function-patch-and-transform"
			input: {
				apiVersion: "pt.fn.crossplane.io/v1beta1"
				kind:       "Resources"
				resources: [{
					name: "clusterrolebinding"
					base: {
						apiVersion: "kubernetes.crossplane.io/v1alpha2"
						kind:       "Object"
						spec: {
							providerConfigRef: name: "in-cluster"
							forProvider: manifest: {
								apiVersion: "rbac.authorization.k8s.io/v1"
								kind:       "ClusterRoleBinding"
								metadata: labels: {
									"app.kubernetes.io/managed-by": "k8-infra"
									"app.kubernetes.io/part-of":    "platform"
									"infra.k8/cluster":             ""
									"infra.k8/owner":               ""
								}
								subjects: []
								roleRef: {
									apiGroup: ""
									kind:     ""
									name:     ""
								}
							}
						}
					}
					patches: [
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.name", toFieldPath: "spec.forProvider.manifest.metadata.name"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.cluster", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/cluster\"]"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.owner", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/owner\"]"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.roleRef", toFieldPath: "spec.forProvider.manifest.roleRef"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.subjects", toFieldPath: "spec.forProvider.manifest.subjects"},
					]
				}]
			}
		}]
	}
}

clusterRoleBindingComposition: #ClusterRoleBindingComposition
