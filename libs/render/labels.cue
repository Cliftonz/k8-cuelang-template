package render

// Standard label block applied to every rendered manifest. Mirrors the
// patches in platform/compositions/<resource>.cue so raw-mode output is
// label-identical to Crossplane-mode output for the same composite input.
#StandardLabels: {
	tier:    string
	cluster: string
	owner:   string
	out: {
		"app.kubernetes.io/managed-by": "k8-infra"
		"app.kubernetes.io/part-of":    "platform"
		"infra.k8/tier":                tier
		"infra.k8/cluster":             cluster
		"infra.k8/owner":               owner
	}
}
