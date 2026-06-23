package compositions

// GithubRepositoryWebhookComposition maps an XGithubRepositoryWebhook claim
// to a RepositoryWebhook managed resource from
// crossplane-contrib-provider-upjet-github.
#GithubRepositoryWebhookComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "githubrepositorywebhook-standard"
		labels: {
			"crossplane.io/xrd":    "xgithubrepositorywebhooks.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XGithubRepositoryWebhook"
		}
		mode: "Pipeline"
		pipeline: [{
			step: "patch-and-transform"
			functionRef: name: "crossplane-contrib-function-patch-and-transform"
			input: {
				apiVersion: "pt.fn.crossplane.io/v1beta1"
				kind:       "Resources"
				resources: [{
					name: "webhook"
					base: {
						apiVersion: "repo.github.upbound.io/v1alpha1"
						kind:       "RepositoryWebhook"
						metadata: labels: {
							"app.kubernetes.io/managed-by": "k8-infra"
							"app.kubernetes.io/part-of":    "platform"
							"infra.k8/tier":                ""
							"infra.k8/cluster":             ""
							"infra.k8/owner":               ""
						}
						spec: {
							providerConfigRef: name: "default"
							forProvider: {
								active: true
								configuration: [{
									contentType: "json"
									insecureSsl: false
								}]
							}
						}
					}
					patches: [
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.name", toFieldPath: "metadata.name"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.tier", toFieldPath: "metadata.labels[\"infra.k8/tier\"]"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.cluster", toFieldPath: "metadata.labels[\"infra.k8/cluster\"]"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.owner", toFieldPath: "metadata.labels[\"infra.k8/owner\"]"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.repository", toFieldPath: "spec.forProvider.repository"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.events", toFieldPath: "spec.forProvider.events"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.urlSecretRef.name", toFieldPath: "spec.forProvider.configuration[0].urlSecretRef.name"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.urlSecretRef.key", toFieldPath: "spec.forProvider.configuration[0].urlSecretRef.key"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.urlSecretRef.namespace", toFieldPath: "spec.forProvider.configuration[0].urlSecretRef.namespace"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.secretSecretRef.name", toFieldPath: "spec.forProvider.configuration[0].secretSecretRef.name"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.secretSecretRef.key", toFieldPath: "spec.forProvider.configuration[0].secretSecretRef.key"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.secretSecretRef.namespace", toFieldPath: "spec.forProvider.configuration[0].secretSecretRef.namespace"},
					]
				}]
			}
		}]
	}
}

githubRepositoryWebhookComposition: #GithubRepositoryWebhookComposition
