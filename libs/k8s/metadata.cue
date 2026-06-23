package k8s

import "github.com/k8-infra/libs/tiers"

// StandardLabels defines the required labels for all managed resources.
#StandardLabels: {
	"app.kubernetes.io/managed-by": "k8-infra"
	"app.kubernetes.io/part-of":    string
	"infra.k8/tier":                tiers.#Tier
	"infra.k8/cluster":             string
	"infra.k8/owner":               string
}

// StandardMetadata defines naming and labeling contracts for all resources.
#StandardMetadata: {
	name:       string & =~"^[a-z][a-z0-9-]*$"
	namespace?: string & =~"^[a-z][a-z0-9-]*$"
	labels: #StandardLabels & {[string]: string}
	annotations?: {[string]: string}
}
