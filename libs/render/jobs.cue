package render

#CronJobInput: #NamespacedConfigInput
#JobInput:     #NamespacedConfigInput

#RenderCronJob: {
	in: #CronJobInput
	out: {
		apiVersion: "batch/v1"
		kind:       "CronJob"
		metadata: {
			name:      in.name
			namespace: in.namespace
			labels: (#StandardLabels & {tier: in.tier, cluster: in.cluster, owner: in.owner}).out
		}
		spec: in.config
	}
}

#RenderJob: {
	in: #JobInput
	out: {
		apiVersion: "batch/v1"
		kind:       "Job"
		metadata: {
			name:      in.name
			namespace: in.namespace
			labels: (#StandardLabels & {tier: in.tier, cluster: in.cluster, owner: in.owner}).out
		}
		spec: in.config
	}
}
