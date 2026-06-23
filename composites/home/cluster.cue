package home

import "github.com/k8-infra/libs/tiers"

cluster: tiers.#ClusterConfig & {
	name:     "home"
	tier:     "production"
	provider: "rancher"
	region:   "on-prem"
}
