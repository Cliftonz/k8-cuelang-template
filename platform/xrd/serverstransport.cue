package xrd

// XServersTransport wraps Traefik's `ServersTransport` CRD — used to
// configure HTTPS backends with options like insecureSkipVerify (for
// self-signed certs on appliances like Home Assistant).
#XServersTransport: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xserverstransports.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XServersTransport"
			plural: "xserverstransports"
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
						insecureSkipVerify: {
							type:        "boolean"
							description: "Disable TLS verification for the backend (self-signed certs)."
							default:     false
						}
						tier: {
							type: "string"
							enum: ["dev", "staging", "production"]
						}
						cluster: type: "string"
						owner: type:   "string"
					}
					required: ["name", "namespace", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xServersTransport: #XServersTransport
