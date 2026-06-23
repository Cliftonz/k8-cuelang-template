package preview

let C = cluster

resourceQuotas: [
	// Argo Events namespace quota — bounds pod count only.
	// Argo-Events controller generates pods (sensors/eventsources/eventbus)
	// without resource specs, so limits.*/requests.* entries would force
	// FailedCreate on every generated pod. Use pod-count cap instead.
	{
		name:      "argo-events-quota"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		hard: {
			pods: "15"
		}
	},

	// Cloudflared tunnel quota — bounds pod count only.
	// STRRL's controller-generated connector Deployment does not set
	// container resources, so limits.*/requests.* entries would force
	// FailedCreate. Use a pod-count cap instead.
	{
		name:      "cloudflared-quota"
		namespace: "cloudflared"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		hard: {
			pods: "5"
		}
	},

	// OpenBao secret store quota.
	{
		name:      "openbao-quota"
		namespace: "openbao"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		hard: {
			"requests.cpu":    "250m"
			"requests.memory": "512Mi"
			"limits.cpu":      "1"
			"limits.memory":   "1Gi"
			pods:              "5"
		}
	},

	// MetalLB quota — controller + speaker DaemonSet pods (one per node).
	// pods-only: speaker pods come from a chart-managed DaemonSet without
	// per-pod resources; strict limits.* would FailedCreate them.
	{
		name:      "metallb-quota"
		namespace: "metallb-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		hard: {
			pods: "10"
		}
	},

	// Traefik ingress controller quota.
	{
		name:      "traefik-quota"
		namespace: "traefik"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		hard: {
			"requests.cpu":    "250m"
			"requests.memory": "256Mi"
			"limits.cpu":      "1"
			"limits.memory":   "512Mi"
			pods:              "5"
		}
	},

]
