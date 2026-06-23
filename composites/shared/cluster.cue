package shared

// Cluster is supplied by export/all.cue to parameterize shared resources.
// Defaults keep cue vet ./... complete when this package is evaluated alone.
cluster: {
	name: *"shared" | string
	tier: *"dev" | "staging" | "production"
}
