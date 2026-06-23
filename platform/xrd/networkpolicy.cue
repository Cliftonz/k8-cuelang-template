package xrd

// XNetworkPolicy defines the CompositeResourceDefinition for NetworkPolicy provisioning.
#XNetworkPolicy: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xnetworkpolicies.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XNetworkPolicy"
			plural: "xnetworkpolicies"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a Kubernetes NetworkPolicy with platform defaults and ownership metadata."
				properties: spec: {
					type:        "object"
					description: "Desired NetworkPolicy settings and placement metadata."
					example: {
						name:      "default-deny"
						namespace: "platform-system"
						tier:      "dev"
						cluster:   "new-dev"
						owner:     "platform-team"
						policy: {
							podSelector: {}
							policyTypes: ["Ingress", "Egress"]
						}
					}
					"x-docs": {
						provider: "provider-kubernetes"
						policyRefs: [
							"platform/policy/networkpolicy.cue",
						]
						behavior: [
							"Applies a NetworkPolicy using the raw Kubernetes spec provided in policy.",
						]
						gotchas: [
							"The policy field is passed through without schema validation by this API.",
							"NetworkPolicy behavior depends on the cluster CNI implementation.",
						]
					}
					properties: {
						name: {
							type:        "string"
							description: "NetworkPolicy resource name to create."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Namespace where the NetworkPolicy will be created."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						tier: {
							type:        "string"
							description: "Tier used for labeling and policy selection."
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
						policy: {
							type:                                   "object"
							description:                            "Raw NetworkPolicy spec (podSelector, ingress, egress, etc.)."
							"x-kubernetes-preserve-unknown-fields": true
						}
					}
					required: ["name", "namespace", "tier", "cluster", "owner", "policy"]
				}
			}
		}]
	}
}

xNetworkPolicy: #XNetworkPolicy
