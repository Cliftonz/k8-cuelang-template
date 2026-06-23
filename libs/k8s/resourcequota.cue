package k8s

// ResourceQuota defines the schema for a Kubernetes ResourceQuota resource.
#ResourceQuota: {
	apiVersion: "v1"
	kind:       "ResourceQuota"
	metadata: #StandardMetadata & {
		namespace: string & =~"^[a-z][a-z0-9-]*$"
	}
	spec: {
		hard: {[string]: string}
	}
}
