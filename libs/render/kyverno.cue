package render

#KyvernoPolicyInput: {
	name: string
	policy: {...}
	tier:    string
	cluster: string
	owner:   string
}

#RenderKyvernoPolicy: {
	in: #KyvernoPolicyInput
	out: {
		apiVersion: "kyverno.io/v1"
		kind:       "ClusterPolicy"
		metadata: {
			name: in.name
			labels: (#StandardLabels & {tier: in.tier, cluster: in.cluster, owner: in.owner}).out
		}
		spec: in.policy
	}
}
