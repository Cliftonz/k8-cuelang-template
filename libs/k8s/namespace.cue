package k8s

// Namespace defines the schema for a Kubernetes Namespace resource
// with organizational constraints enforced.
#Namespace: {
	apiVersion: "v1"
	kind:       "Namespace"
	metadata: #StandardMetadata & {
		// Namespaces cannot themselves be namespaced
		namespace?: _|_ // explicitly disallowed
	}
}
