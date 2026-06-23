package tiers

// Tier represents the deployment environment classification.
#Tier: "dev" | "staging" | "production"

// TierConfig defines the contract that every tier must satisfy.
// Each tier file (dev.cue, staging.cue, production.cue) provides
// concrete values that unify with this structure.
#TierConfig: {
	tier: #Tier

	resourceQuota: {
		requests: {
			cpu:    string
			memory: string
		}
		limits: {
			cpu:    string
			memory: string
		}
	}

	kyverno: {
		validationFailureAction: "Audit" | "Enforce"
	}

	networkPolicy: {
		defaultDenyIngress: bool
		defaultDenyEgress:  bool
		allowDNS:           bool
		allowMonitoring:    bool
	}
}

// ClusterConfig binds a cluster name to its tier and provider.
#ClusterConfig: {
	name:     string & =~"^[a-z][a-z0-9-]*$"
	tier:     #Tier
	provider: "rancher" | "eks" | "gke" | "aks"
	region:   string | *"on-prem"
}
