// Package render expands composite inputs directly into raw Kubernetes
// manifests, mirroring the effect that Crossplane Compositions would
// achieve at reconcile time. Used by the raw-fallback export mode for
// clusters that cannot or should not run Crossplane.
//
// Each resource type has a #Render<Kind> definition that takes the same
// input shape consumers author in composites/<cluster>/*.cue and returns
// the expanded manifest under .out. Output is intentionally not unified
// against libs/k8s schemas here — those schemas are stricter than the
// real Kubernetes API for some fields (e.g. NetworkPolicy podSelector).
// Phase 2 adds explicit cue-vet validation against the upstream API
// schemas as a separate step.
package render

#NamespaceInput: {
	name:    string
	tier:    string
	cluster: string
	owner:   string
	labels?: {[string]: string}
}

#RenderNamespace: {
	in: #NamespaceInput
	out: {
		apiVersion: "v1"
		kind:       "Namespace"
		metadata: {
			name: in.name
			labels: {
				"app.kubernetes.io/managed-by": "k8-infra"
				"app.kubernetes.io/part-of":    "platform"
				"infra.k8/tier":                in.tier
				"infra.k8/cluster":             in.cluster
				"infra.k8/owner":               in.owner
				if in.labels != _|_ {
					for k, v in in.labels {(k): v}
				}
			}
		}
	}
}
