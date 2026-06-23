package xrd

// XExternalBackend defines a selector-less Service paired with an
// EndpointSlice pointing at one or more out-of-cluster IPs. Used to
// front external services (e.g. NodePorts on other VMs, household
// appliances) behind cluster Ingress so they get DNS + Traefik routing.
//
// Renders:
//   - Service (no selector, port → targetPort mapping)
//   - EndpointSlice (IPv4 addresses, single port)
#XExternalBackend: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xexternalbackends.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XExternalBackend"
			plural: "xexternalbackends"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Selector-less Service + EndpointSlice for routing to an out-of-cluster IP."
				properties: spec: {
					type: "object"
					properties: {
						name: {
							type:        "string"
							description: "Service + EndpointSlice base name."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Namespace where Service and EndpointSlice will live."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						port: {
							type:        "integer"
							description: "Service port (in-cluster)."
						}
						targetPort: {
							type:        "integer"
							description: "Backend port on the external host."
						}
						protocol: {
							type:        "string"
							description: "Port protocol."
							enum: ["TCP", "UDP"]
							default: "TCP"
						}
						portName: {
							type:        "string"
							description: "Port name on Service + EndpointSlice."
							default:     "http"
						}
						addresses: {
							type:        "array"
							description: "External IPv4 addresses to forward to."
							items: type: "string"
						}
						annotations: {
							type:        "object"
							description: "Extra annotations on the Service (e.g. traefik.ingress.kubernetes.io/service.serversscheme=https)."
							additionalProperties: type: "string"
						}
						tier: {
							type: "string"
							enum: ["dev", "staging", "production"]
						}
						cluster: type: "string"
						owner: type:   "string"
					}
					required: ["name", "namespace", "port", "targetPort", "addresses", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xExternalBackend: #XExternalBackend
