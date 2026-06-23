package xrd

// XExposedService renders a sibling ClusterIP Service whose only purpose
// is to carry `omni-kube-service-exposer.sidero.dev/*` annotations so
// the Omni workload-proxy advertises a clean URL for an existing UI.
//
// Why a sibling instead of annotating the chart-managed Service: helm
// upgrades clobber kubectl-applied annotations on chart-owned objects.
// A separate Service we own outright is durable.
#XExposedService: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xexposedservices.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XExposedService"
			plural: "xexposedservices"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type: "object"
				properties: spec: {
					type: "object"
					properties: {
						name: {
							type:    "string"
							pattern: "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:    "string"
							pattern: "^[a-z][a-z0-9-]*$"
						}
						selector: {
							type:        "object"
							description: "Pod label selector (must match the chart's pod labels)."
							additionalProperties: type: "string"
						}
						port: {
							type:        "integer"
							description: "Service port."
							default:     80
						}
						targetPort: {
							type:        "integer"
							description: "Pod port the Service forwards to."
						}
						portName: {
							type:    "string"
							default: "http"
						}
						omniPort: {
							type:        "integer"
							description: "Host port Omni binds for this service (e.g. 50082)."
						}
						omniLabel: {
							type:        "string"
							description: "Display label in Omni UI."
						}
						omniPrefix: {
							type:        "string"
							description: "Subdomain prefix for the Omni proxy URL. No dashes."
							pattern:     "^[a-z][a-z0-9]*$"
						}
						tier: {
							type: "string"
							enum: ["dev", "staging", "production"]
						}
						cluster: type: "string"
						owner: type:   "string"
					}
					required: ["name", "namespace", "selector", "targetPort", "omniPort", "omniLabel", "omniPrefix", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xExposedService: #XExposedService
