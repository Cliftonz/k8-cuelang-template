package compositions

// BackupPolicyComposition maps an XBackupPolicy claim to a Velero
// Schedule. The Schedule lands in the velero namespace; Velero's own
// controller then materializes Backup CRs on the cron cadence.
#BackupPolicyComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "backuppolicy-standard"
		labels: {
			"crossplane.io/xrd":    "xbackuppolicies.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XBackupPolicy"
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
					name: "schedule"
					base: {
						apiVersion: "kubernetes.crossplane.io/v1alpha2"
						kind:       "Object"
						spec: {
							providerConfigRef: {
								name: "in-cluster"
							}
							forProvider: manifest: {
								apiVersion: "velero.io/v1"
								kind:       "Schedule"
								metadata: {
									namespace: "velero"
									labels: {
										"app.kubernetes.io/managed-by": "k8-infra"
										"app.kubernetes.io/part-of":    "platform"
										"infra.k8/tier":                ""
										"infra.k8/cluster":             ""
										"infra.k8/owner":               ""
									}
								}
								spec: {
									schedule:        ""
									skipImmediately: false
									template: {
										ttl:                      "720h0m0s"
										snapshotVolumes:          false
										defaultVolumesToFsBackup: false
										includeClusterResources:  false
										includedNamespaces: []
										excludedNamespaces: []
										excludedResources: []
										labelSelector: matchLabels: {}
									}
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
							fromFieldPath: "spec.schedule"
							toFieldPath:   "spec.forProvider.manifest.spec.schedule"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.ttl"
							toFieldPath:   "spec.forProvider.manifest.spec.template.ttl"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.snapshotVolumes"
							toFieldPath:   "spec.forProvider.manifest.spec.template.snapshotVolumes"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.defaultVolumesToFsBackup"
							toFieldPath:   "spec.forProvider.manifest.spec.template.defaultVolumesToFsBackup"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.includedNamespaces"
							toFieldPath:   "spec.forProvider.manifest.spec.template.includedNamespaces"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.excludedNamespaces"
							toFieldPath:   "spec.forProvider.manifest.spec.template.excludedNamespaces"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.excludedResources"
							toFieldPath:   "spec.forProvider.manifest.spec.template.excludedResources"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.includeClusterResources"
							toFieldPath:   "spec.forProvider.manifest.spec.template.includeClusterResources"
						},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.selector"
							toFieldPath:   "spec.forProvider.manifest.spec.template.labelSelector.matchLabels"
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

backupPolicyComposition: #BackupPolicyComposition
