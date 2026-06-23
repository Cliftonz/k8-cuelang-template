package tiers

// production defines the tier defaults for production clusters.
production: #TierConfig & {
	tier: "production"
	resourceQuota: {
		requests: {
			cpu:    "4"
			memory: "4Gi"
		}
		limits: {
			cpu:    "8"
			memory: "8Gi"
		}
	}
	kyverno: {
		validationFailureAction: "Enforce"
	}
	networkPolicy: {
		defaultDenyIngress: true
		defaultDenyEgress:  true
		allowDNS:           true
		allowMonitoring:    true
	}
}
