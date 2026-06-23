package policy

import "github.com/k8-infra/libs/tiers"

// NetworkPolicyByTier maps tier defaults for use in policy templates.
#NetworkPolicyByTier: {
	dev:        tiers.dev.networkPolicy
	staging:    tiers.staging.networkPolicy
	production: tiers.production.networkPolicy
}
