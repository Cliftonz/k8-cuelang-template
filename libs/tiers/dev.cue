package tiers

// dev defines the tier defaults for development clusters.
dev: #TierConfig & {
	tier: "dev"
	resourceQuota: {
		requests: {
			cpu:    "1"
			memory: "1Gi"
		}
		limits: {
			cpu:    "2"
			memory: "2Gi"
		}
	}
	kyverno: {
		validationFailureAction: "Audit"
	}
	networkPolicy: {
		defaultDenyIngress: true
		defaultDenyEgress:  true
		allowDNS:           true
		allowMonitoring:    false
	}
}
