package policy

import "github.com/k8-infra/libs/tiers"

// ResourceQuotaByTier maps tier defaults into ResourceQuota hard limits.
#ResourceQuotaByTier: {
	dev: {
		"requests.cpu":    tiers.dev.resourceQuota.requests.cpu
		"requests.memory": tiers.dev.resourceQuota.requests.memory
		"limits.cpu":      tiers.dev.resourceQuota.limits.cpu
		"limits.memory":   tiers.dev.resourceQuota.limits.memory
	}
	staging: {
		"requests.cpu":    tiers.staging.resourceQuota.requests.cpu
		"requests.memory": tiers.staging.resourceQuota.requests.memory
		"limits.cpu":      tiers.staging.resourceQuota.limits.cpu
		"limits.memory":   tiers.staging.resourceQuota.limits.memory
	}
	production: {
		"requests.cpu":    tiers.production.resourceQuota.requests.cpu
		"requests.memory": tiers.production.resourceQuota.requests.memory
		"limits.cpu":      tiers.production.resourceQuota.limits.cpu
		"limits.memory":   tiers.production.resourceQuota.limits.memory
	}
}
