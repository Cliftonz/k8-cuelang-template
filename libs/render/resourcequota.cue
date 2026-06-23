package render

#ResourceQuotaInput: {
	name:      string
	namespace: string
	tier:      string
	cluster:   string
	owner:     string
	hard: {[string]: string}
}

#RenderResourceQuota: {
	in: #ResourceQuotaInput
	out: {
		apiVersion: "v1"
		kind:       "ResourceQuota"
		metadata: {
			name:      in.name
			namespace: in.namespace
			labels: {
				"app.kubernetes.io/managed-by": "k8-infra"
				"app.kubernetes.io/part-of":    "platform"
				"infra.k8/tier":                in.tier
				"infra.k8/cluster":             in.cluster
				"infra.k8/owner":               in.owner
			}
		}
		spec: hard: in.hard
	}
}
