package xrd

// XNodeTaint defines the CompositeResourceDefinition for applying taints to specific nodes.
#XNodeTaint: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xnodetaints.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XNodeTaint"
			plural: "xnodetaints"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request taints to be applied to a specific Kubernetes node."
				properties: spec: {
					type:        "object"
					description: "Desired node taints and ownership metadata."
					example: {
						name:     "gpu-nodes"
						cluster:  "new-dev"
						owner:    "platform-team"
						nodeName: "ip-10-0-0-10.us-east-2.compute.internal"
						taints: [
							{
								key:    "dedicated"
								value:  "gpu"
								effect: "PreferNoSchedule"
							},
						]
					}
					"x-docs": {
						provider: "provider-kubernetes"
						policyRefs: []
						behavior: [
							"Patches the target Node to include the specified taints.",
							"The Node resource is orphaned on composite deletion.",
						]
						gotchas: [
							"The composite does not remove taints when deleted.",
							"Node names are cluster-specific; ensure the node exists.",
						]
					}
					properties: {
						name: {
							type:        "string"
							description: "Unique identifier for this node taint request."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						cluster: {
							type:        "string"
							description: "Logical cluster identifier used for labeling and placement."
						}
						owner: {
							type:        "string"
							description: "Owning team or service for accountability and routing."
						}
						nodeName: {
							type:        "string"
							description: "Kubernetes node name to receive the taint."
							pattern:     "^[a-z][a-z0-9.-]*$"
						}
						taints: {
							type:        "array"
							description: "List of taints to apply to the node."
							items: {
								type: "object"
								properties: {
									key: {
										type:        "string"
										description: "Taint key to apply."
									}
									value: {
										type:        "string"
										description: "Optional taint value."
									}
									effect: {
										type:        "string"
										description: "Taint effect applied by the scheduler."
										enum: ["NoSchedule", "NoExecute", "PreferNoSchedule"]
									}
								}
								required: ["key", "effect"]
							}
							minItems: 1
						}
					}
					required: ["name", "cluster", "owner", "nodeName", "taints"]
				}
			}
		}]
	}
}

xNodeTaint: #XNodeTaint
