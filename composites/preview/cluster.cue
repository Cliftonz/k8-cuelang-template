package preview

import "github.com/k8-infra/libs/tiers"

cluster: tiers.#ClusterConfig & {
	name:     "preview"
	tier:     "dev"
	provider: "rancher"
	region:   "on-prem"
}
