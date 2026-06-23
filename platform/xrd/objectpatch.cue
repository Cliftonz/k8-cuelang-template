package xrd

// XObjectPatch overlays annotations and/or labels onto an existing
// Kubernetes resource that is owned by something else (typically a Helm
// chart whose values don't expose the annotation fields we need).
//
// The composition does NOT create or delete the target — it only updates
// the metadata fields provided in spec.annotations and spec.labels, via
// server-side apply from provider-kubernetes with managementPolicies
// [Observe, Update]. Other fields on the target stay owned by their
// original field manager (e.g. Helm).
#XObjectPatch: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xobjectpatches.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XObjectPatch"
			plural: "xobjectpatches"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Overlay annotations/labels onto an existing Kubernetes resource."
				properties: spec: {
					type:        "object"
					description: "Target resource and metadata overlay."
					properties: {
						name: {
							type:        "string"
							description: "Logical name for this patch (used to derive the Object name)."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						targetRef: {
							type:        "object"
							description: "Reference to the resource to patch. Must already exist."
							properties: {
								apiVersion: {
									type:        "string"
									description: "apiVersion of the target (e.g. v1, apps/v1)."
								}
								kind: {
									type:        "string"
									description: "Kind of the target (e.g. Service, Deployment)."
								}
								namespace: {
									type:        "string"
									description: "Namespace of the target. Omit for cluster-scoped resources."
								}
								name: {
									type:        "string"
									description: "Name of the target resource."
									pattern:     "^[a-z][a-z0-9-]*$"
								}
							}
							required: ["apiVersion", "kind", "name"]
						}
						annotations: {
							type:        "object"
							description: "Annotations to set on the target. Existing annotations from other field managers are preserved."
							additionalProperties: type: "string"
						}
						labels: {
							type:        "object"
							description: "Labels to set on the target. Existing labels from other field managers are preserved."
							additionalProperties: type: "string"
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
							description: "Team or service that owns this patch."
						}
					}
					required: ["name", "targetRef", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xObjectPatch: #XObjectPatch
