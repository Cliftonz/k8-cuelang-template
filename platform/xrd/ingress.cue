package xrd

// XIngress defines the CompositeResourceDefinition for ingress routing requests.
#XIngress: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xingresses.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XIngress"
			plural: "xingresses"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request an ingress rule for HTTP routing."
				properties: spec: {
					type:        "object"
					description: "Ingress settings and ownership metadata."
					properties: {
						name: {
							type:        "string"
							description: "Ingress resource name to create."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Namespace where the Ingress will be created."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						host: {
							type:        "string"
							description: "Hostname for the ingress rule."
						}
						serviceName: {
							type:        "string"
							description: "Backend Service name."
						}
						servicePort: {
							type:        "integer"
							description: "Backend Service port."
						}
						tlsSecretName: {
							type:        "string"
							description: "TLS Secret name for HTTPS termination."
						}
						ingressClassName: {
							type:        "string"
							description: "IngressClass to use for this rule."
						}
						annotations: {
							type:        "object"
							description: "Extra annotations merged onto the Ingress (e.g. external-dns.alpha.kubernetes.io/target=192.168.1.235, traefik.ingress.kubernetes.io/router.middlewares=...)."
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
							description: "Team or service that owns this ingress."
						}
					}
					required: ["name", "namespace", "host", "serviceName", "servicePort", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xIngress: #XIngress
