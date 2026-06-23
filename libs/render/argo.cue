package render

// Common shape for namespaced Argo* CRs that simply pass `config` through
// to `spec`.
#NamespacedConfigInput: {
	name:      string
	namespace: string
	tier:      string
	cluster:   string
	owner:     string
	config: {...}
}

_argoBase: {
	in:         #NamespacedConfigInput
	apiVersion: string
	kind:       string
	out: {
		"apiVersion": apiVersion
		"kind":       kind
		metadata: {
			name:      in.name
			namespace: in.namespace
			labels: (#StandardLabels & {tier: in.tier, cluster: in.cluster, owner: in.owner}).out
		}
		spec: in.config
	}
}

#RenderArgoEventBus: _argoBase & {apiVersion: "argoproj.io/v1alpha1", kind: "EventBus"}
#RenderArgoEventSource: _argoBase & {apiVersion: "argoproj.io/v1alpha1", kind: "EventSource"}
#RenderArgoSensor: _argoBase & {apiVersion: "argoproj.io/v1alpha1", kind: "Sensor"}
#RenderArgoAppProject: _argoBase & {apiVersion: "argoproj.io/v1alpha1", kind: "AppProject"}
#RenderArgoApplicationSet: _argoBase & {apiVersion: "argoproj.io/v1alpha1", kind: "ApplicationSet"}
