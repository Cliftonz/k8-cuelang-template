package render

#NetworkPolicyInput: {
	name:      string
	namespace: string
	tier:      string
	cluster:   string
	owner:     string
	policy: {...}
}

#RenderNetworkPolicy: {
	in: #NetworkPolicyInput
	out: {
		apiVersion: "networking.k8s.io/v1"
		kind:       "NetworkPolicy"
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
		spec: in.policy
	}
}
