package xrd

// XMetalLBPool defines the CompositeResourceDefinition for a MetalLB
// IPAddressPool + L2Advertisement pair. Always paired because L2 mode
// is useless without an addresses block to announce, and an
// IPAddressPool with no L2/BGP advertisement assigns IPs that aren't
// reachable from the LAN.
#XMetalLBPool: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xmetallbpools.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XMetalLBPool"
			plural: "xmetallbpools"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a MetalLB IPAddressPool with paired L2Advertisement."
				properties: spec: {
					type:        "object"
					description: "Pool addresses + ownership metadata."
					properties: {
						name: {
							type:        "string"
							description: "Pool name (used for both IPAddressPool and L2Advertisement)."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Namespace where MetalLB is installed."
							default:     "metallb-system"
						}
						addresses: {
							type:        "array"
							description: "List of CIDRs or hyphenated ranges (e.g. 192.168.3.240-192.168.3.250)."
							items: type: "string"
						}
						autoAssign: {
							type:        "boolean"
							description: "Auto-assign IPs in this pool to LoadBalancer Services."
							default:     true
						}
						avoidBuggyIPs: {
							type:        "boolean"
							description: "Skip .0 / .255 boundary IPs."
							default:     true
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
							description: "Team or service that owns this pool."
						}
					}
					required: ["name", "addresses", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xMetalLBPool: #XMetalLBPool
