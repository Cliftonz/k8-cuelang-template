package k8s

// NetworkPolicy defines the schema for a Kubernetes NetworkPolicy resource.
#NetworkPolicy: {
	apiVersion: "networking.k8s.io/v1"
	kind:       "NetworkPolicy"
	metadata: #StandardMetadata & {
		namespace: string & =~"^[a-z][a-z0-9-]*$"
	}
	spec: {
		podSelector: {[string]: string} | {}
		policyTypes: [...("Ingress" | "Egress")]
		ingress?: [...#IngressRule]
		egress?: [...#EgressRule]
	}
}

#IngressRule: _
#EgressRule:  _
