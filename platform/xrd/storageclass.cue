package xrd

// XStorageClass defines the CompositeResourceDefinition for StorageClass provisioning.
#XStorageClass: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xstorageclasses.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XStorageClass"
			plural: "xstorageclasses"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a Kubernetes StorageClass with standard metadata and policy defaults."
				properties: spec: {
					type:        "object"
					description: "StorageClass settings and ownership metadata."
					example: {
						name:        "nfs-storage"
						provisioner: "nfs-subdir-external-provisioner"
						parameters: {
							pathPattern: "${namespace}/${pvcName}"
							onDelete:    "retain"
						}
						reclaimPolicy:        "Retain"
						volumeBindingMode:    "Immediate"
						allowVolumeExpansion: true
						mountOptions: ["nfsvers=4.1"]
						tier:    "production"
						cluster: "infra-prod"
						owner:   "platform-team"
					}
					"x-docs": {
						provider: "provider-kubernetes"
						policyRefs: []
						behavior: [
							"Creates or updates a cluster-scoped StorageClass.",
							"Deletion behavior follows the composition's deletion policy.",
						]
						gotchas: [
							"StorageClasses are cluster-scoped; changes affect all namespaces.",
						]
					}
					properties: {
						name: {
							type:        "string"
							description: "StorageClass name to create."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						provisioner: {
							type:        "string"
							description: "CSI provisioner name."
						}
						parameters: {
							type:                                   "object"
							description:                            "Provisioner-specific parameters."
							"x-kubernetes-preserve-unknown-fields": true
						}
						reclaimPolicy: {
							type:        "string"
							description: "Reclaim policy for dynamically provisioned volumes."
							enum: ["Delete", "Retain"]
						}
						volumeBindingMode: {
							type:        "string"
							description: "Volume binding mode for the StorageClass."
							enum: ["Immediate", "WaitForFirstConsumer"]
						}
						allowVolumeExpansion: {
							type:        "boolean"
							description: "Allow volume expansion for PVCs using this StorageClass."
						}
						mountOptions: {
							type:        "array"
							description: "Mount options for the StorageClass."
							items: {type: "string"}
						}
						allowedTopologies: {
							type:        "array"
							description: "Allowed topologies for volume provisioning."
							items: {type: "object"}
						}
						tier: {
							type:        "string"
							description: "Deployment tier."
							enum: ["dev", "staging", "production"]
						}
						cluster: {
							type:        "string"
							description: "Target cluster name."
						}
						owner: {
							type:        "string"
							description: "Team or service that owns this StorageClass."
						}
					}
					required: ["name", "provisioner", "parameters", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xStorageClass: #XStorageClass
