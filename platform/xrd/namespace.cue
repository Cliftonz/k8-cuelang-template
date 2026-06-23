package xrd

// XNamespace defines the CompositeResourceDefinition for namespace provisioning.
// This is the platform API that cluster consumers use to request namespaces
// with standard labels, annotations, and organizational policies applied.
#XNamespace: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xnamespaces.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XNamespace"
			plural: "xnamespaces"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a Kubernetes namespace with standard labels and policy defaults applied by the platform."
				properties: spec: {
					type:        "object"
					description: "Desired namespace settings and ownership metadata used by the platform."
					example: {
						name:    "team-platform"
						tier:    "dev"
						cluster: "new-dev"
						owner:   "platform-team"
					}
					"x-docs": {
						provider: "provider-kubernetes"
						policyRefs: [
							"libs/tiers/tier.cue",
							"platform/policy/networkpolicy.cue",
							"platform/policy/resourcequota.cue",
						]
						behavior: [
							"Creates a Kubernetes Namespace with standard labels applied.",
							"Deletion behavior follows the composition's deletion policy.",
						]
						gotchas: [
							"Namespace names must be DNS-1123 compatible and unique per cluster.",
						]
					}
					properties: {
						name: {
							type:        "string"
							description: "Namespace name to create in the target cluster. Must be DNS-1123 compatible."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						tier: {
							type:        "string"
							description: "Tier used to select defaults like quota and policy behavior."
							enum: ["dev", "staging", "production"]
						}
						cluster: {
							type:        "string"
							description: "Logical cluster identifier used for labeling and placement."
						}
						owner: {
							type:        "string"
							description: "Owning team or service for accountability and routing."
						}
						labels: {
							type:        "object"
							description: "Extra labels merged onto the namespace (e.g. pod-security.kubernetes.io/enforce=privileged)."
							additionalProperties: type: "string"
						}
					}
					required: ["name", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xNamespace: #XNamespace
