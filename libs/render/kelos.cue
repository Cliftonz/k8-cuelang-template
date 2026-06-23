package render

_kelosBase: {
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

#RenderKelosWorkspace: _kelosBase & {apiVersion: "kelos.dev/v1alpha1", kind: "Workspace"}
#RenderKelosAgentConfig: _kelosBase & {apiVersion: "kelos.dev/v1alpha1", kind: "AgentConfig"}
#RenderKelosTaskSpawner: _kelosBase & {apiVersion: "kelos.dev/v1alpha1", kind: "TaskSpawner"}
