package render

#HelmReleaseInput: {
	name:      string
	namespace: string
	chart: {
		name:       string
		repository: string
		version:    string
	}
	values: {...}
	tier:    string
	cluster: string
	owner:   string
}

// Sentinel placeholder consumed by ci/scripts/render-helm.sh, which
// substitutes the multi-doc YAML produced by `helm template`.
#RenderHelmRelease: {
	in: #HelmReleaseInput
	out: {
		apiVersion: "k8-infra/raw-fallback/v1alpha1"
		kind:       "HelmRenderRequest"
		metadata: {
			name:      in.name
			namespace: in.namespace
			labels: (#StandardLabels & {tier: in.tier, cluster: in.cluster, owner: in.owner}).out
		}
		spec: {
			chart:  in.chart
			values: in.values
		}
	}
}
