package home

let C = cluster

resourceQuotas: [
	// MetalLB quota — controller + speaker DaemonSet pods. pods-only:
	// the speaker DaemonSet is chart-managed without per-pod resources,
	// so strict limits.* would FailedCreate it.
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

	// Longhorn quota — pods-only. Longhorn generates manager, driver,
	// engine, replica, and CSI pods without uniform resource specs, so
	// request/limit quotas would block volume operations.
	{
		name:      "longhorn-quota"
		namespace: "longhorn-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		hard: {
			pods: "60"
		}
	},

	// Traefik quota — fixed-size Deployment, so full request/limit quota
	// is safe.
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

	// OpenBao quota — single pod + bootstrap Job.
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

	// External Secrets Operator quota — pods-only.
	// The ESO chart generates webhook + cert-controller Deployments
	// whose pods don't declare per-container resources; a strict
	// limits.*/requests.* quota would FailedCreate those pods.
	{
		name:      "external-secrets-quota"
		namespace: "external-secrets"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		hard: {
			pods: "10"
		}
	},

	// ExternalDNS quota — pods-only.
	// Webhook sidecar pods don't declare resource specs by default.
	{
		name:      "external-dns-quota"
		namespace: "external-dns"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		hard: {
			pods: "3"
		}
	},

	// Argo Events — pods-only. Sensor/EventSource/EventBus controllers
	// generate pods without per-pod resource specs. 40 to accommodate
	// 10 sensor pods + 3 eventbus + 2 eventsources + parallel trigger
	// Jobs (each sensor can spawn its own Job pod, with retries).
	{
		name:      "argo-events-quota"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		hard: {
			pods: "40"
		}
	},

	// Cloudflared tunnel — pods-only. STRRL controller generates the
	// connector Deployment without container resources.
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

	// Homepage — small fixed-size Deployment. Doubled resource quota
	// vs per-pod requests so rolling deploys (maxSurge=1) can briefly
	// run 2 pods during rollout.
	{
		name:      "homepage-quota"
		namespace: "homepage"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		hard: {
			"requests.cpu":    "200m"
			"requests.memory": "256Mi"
			"limits.cpu":      "800m"
			"limits.memory":   "512Mi"
			pods:              "3"
		}
	},
]
