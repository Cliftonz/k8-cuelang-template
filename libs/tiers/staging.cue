package tiers

// staging defines the tier defaults for staging clusters.
staging: #TierConfig & {
	tier: "staging"
	resourceQuota: {
		requests: {
			cpu:    "2"
			memory: "2Gi"
		}
		limits: {
			cpu:    "4"
			memory: "4Gi"
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
