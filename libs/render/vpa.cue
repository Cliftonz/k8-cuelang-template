package render

// VerticalPodAutoscaler — autoscaling.k8s.io/v1, directly applyable.
// Mirrors the Crossplane-mode shape in
// platform/compositions/verticalpodautoscaler.cue.

#VerticalPodAutoscalerInput: {
	name:      string
	namespace: string
	targetRef: {
		apiVersion: string
		kind:       string
		name:       string
	}
	updateMode?:     string
	resourcePolicy?: {...}
	tier:    string
	cluster: string
	owner:   string
}

#RenderVerticalPodAutoscaler: {
	in: #VerticalPodAutoscalerInput
	out: {
		apiVersion: "autoscaling.k8s.io/v1"
		kind:       "VerticalPodAutoscaler"
		metadata: {
			name:      in.name
			namespace: in.namespace
			labels: (#StandardLabels & {tier: in.tier, cluster: in.cluster, owner: in.owner}).out
		}
		spec: {
			targetRef: in.targetRef
			if in.updateMode != _|_ {
				updatePolicy: updateMode: in.updateMode
			}
			if in.resourcePolicy != _|_ {
				resourcePolicy: in.resourcePolicy
			}
		}
	}
}
