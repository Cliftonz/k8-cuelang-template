package home

let C = cluster

// VerticalPodAutoscaler claims for stateless workloads where in-place
// resize is safe. K8s 1.36's InPlacePodVerticalScaling lets the kubelet
// adjust container resources without rescheduling the pod; VPA's
// InPlaceOrRecreate update mode tries that path first and falls back
// to evict+recreate if the kubelet refuses.
//
// Skipped (stateful / restart-sensitive):
//   - openbao-0          (StatefulSet, file storage; keep stable)
//   - longhorn-manager   (StatefulSet; replica state)
//   - eventbus-default-stan (NATS-streaming StatefulSet; clustering)
//   - argo-cd-application-controller (StatefulSet; workqueue state)
//   - kelos-controller-manager (operator with leader-election;
//     in-place safe later, but de-risk the rollout first)
//
// Resource policy minAllowed/maxAllowed bounds prevent VPA from
// recommending absurd numbers when usage is bursty. For most homelab
// services, 50m/64Mi is a reasonable floor and 1/1Gi a reasonable
// ceiling. Per-workload overrides where the application is a known
// outlier (Traefik, opencost-prometheus-server).
let _stdResourcePolicy = {
	containerPolicies: [{
		containerName: "*"
		minAllowed: {cpu: "50m", memory: "64Mi"}
		maxAllowed: {cpu: "1", memory: "1Gi"}
		controlledResources: ["cpu", "memory"]
		controlledValues: "RequestsAndLimits"
	}]
}
let _largeResourcePolicy = {
	containerPolicies: [{
		containerName: "*"
		minAllowed: {cpu: "100m", memory: "128Mi"}
		maxAllowed: {cpu: "2", memory: "4Gi"}
		controlledResources: ["cpu", "memory"]
		controlledValues: "RequestsAndLimits"
	}]
}

verticalPodAutoscalers: [
	// ── Argo CD components (stateless Deployments) ──────────────────
	{
		name:      "argo-cd-server"
		namespace: "argocd"
		targetRef: {apiVersion: "apps/v1", kind: "Deployment", name: "argo-cd-argocd-server"}
		updateMode:     "InPlaceOrRecreate"
		resourcePolicy: _stdResourcePolicy
		tier:           C.tier
		cluster:        C.name
		owner:          "platform-team"
	},
	{
		name:      "argo-cd-repo-server"
		namespace: "argocd"
		targetRef: {apiVersion: "apps/v1", kind: "Deployment", name: "argo-cd-argocd-repo-server"}
		updateMode:     "InPlaceOrRecreate"
		resourcePolicy: _largeResourcePolicy // git clones spike memory
		tier:           C.tier
		cluster:        C.name
		owner:          "platform-team"
	},
	{
		name:      "argo-cd-applicationset-controller"
		namespace: "argocd"
		targetRef: {apiVersion: "apps/v1", kind: "Deployment", name: "argo-cd-argocd-applicationset-controller"}
		updateMode:     "InPlaceOrRecreate"
		resourcePolicy: _stdResourcePolicy
		tier:           C.tier
		cluster:        C.name
		owner:          "platform-team"
	},
	{
		name:      "argo-cd-notifications-controller"
		namespace: "argocd"
		targetRef: {apiVersion: "apps/v1", kind: "Deployment", name: "argo-cd-argocd-notifications-controller"}
		updateMode:     "InPlaceOrRecreate"
		resourcePolicy: _stdResourcePolicy
		tier:           C.tier
		cluster:        C.name
		owner:          "platform-team"
	},
	{
		name:      "argo-cd-redis"
		namespace: "argocd"
		targetRef: {apiVersion: "apps/v1", kind: "Deployment", name: "argo-cd-argocd-redis"}
		updateMode:     "InPlaceOrRecreate"
		resourcePolicy: _stdResourcePolicy
		tier:           C.tier
		cluster:        C.name
		owner:          "platform-team"
	},
	{
		name:      "argo-cd-dex-server"
		namespace: "argocd"
		targetRef: {apiVersion: "apps/v1", kind: "Deployment", name: "argo-cd-argocd-dex-server"}
		updateMode:     "InPlaceOrRecreate"
		resourcePolicy: _stdResourcePolicy
		tier:           C.tier
		cluster:        C.name
		owner:          "platform-team"
	},

	// ── Edge / ingress ─────────────────────────────────────────────
	{
		name:      "traefik"
		namespace: "traefik"
		targetRef: {apiVersion: "apps/v1", kind: "Deployment", name: "traefik"}
		updateMode:     "InPlaceOrRecreate"
		resourcePolicy: _largeResourcePolicy // proxy throughput-dependent
		tier:           C.tier
		cluster:        C.name
		owner:          "platform-team"
	},
	{
		name:      "external-dns-unifi"
		namespace: "external-dns"
		targetRef: {apiVersion: "apps/v1", kind: "Deployment", name: "external-dns-unifi"}
		updateMode:     "InPlaceOrRecreate"
		resourcePolicy: _stdResourcePolicy
		tier:           C.tier
		cluster:        C.name
		owner:          "platform-team"
	},
	{
		name:      "cloudflare-tunnel-ingress-controller"
		namespace: "cloudflared"
		targetRef: {apiVersion: "apps/v1", kind: "Deployment", name: "cloudflare-tunnel-ingress-controller"}
		updateMode:     "InPlaceOrRecreate"
		resourcePolicy: _stdResourcePolicy
		tier:           C.tier
		cluster:        C.name
		owner:          "platform-team"
	},

	// ── cert-manager components ────────────────────────────────────
	{
		name:      "cert-manager"
		namespace: "cert-manager"
		targetRef: {apiVersion: "apps/v1", kind: "Deployment", name: "cert-manager"}
		updateMode:     "InPlaceOrRecreate"
		resourcePolicy: _stdResourcePolicy
		tier:           C.tier
		cluster:        C.name
		owner:          "platform-team"
	},
	{
		name:      "cert-manager-cainjector"
		namespace: "cert-manager"
		targetRef: {apiVersion: "apps/v1", kind: "Deployment", name: "cert-manager-cainjector"}
		updateMode:     "InPlaceOrRecreate"
		resourcePolicy: _stdResourcePolicy
		tier:           C.tier
		cluster:        C.name
		owner:          "platform-team"
	},
	{
		name:      "cert-manager-webhook"
		namespace: "cert-manager"
		targetRef: {apiVersion: "apps/v1", kind: "Deployment", name: "cert-manager-webhook"}
		updateMode:     "InPlaceOrRecreate"
		resourcePolicy: _stdResourcePolicy
		tier:           C.tier
		cluster:        C.name
		owner:          "platform-team"
	},

	// ── ESO ────────────────────────────────────────────────────────
	{
		name:      "external-secrets"
		namespace: "external-secrets"
		targetRef: {apiVersion: "apps/v1", kind: "Deployment", name: "external-secrets"}
		updateMode:     "InPlaceOrRecreate"
		resourcePolicy: _stdResourcePolicy
		tier:           C.tier
		cluster:        C.name
		owner:          "platform-team"
	},
	{
		name:      "external-secrets-cert-controller"
		namespace: "external-secrets"
		targetRef: {apiVersion: "apps/v1", kind: "Deployment", name: "external-secrets-cert-controller"}
		updateMode:     "InPlaceOrRecreate"
		resourcePolicy: _stdResourcePolicy
		tier:           C.tier
		cluster:        C.name
		owner:          "platform-team"
	},
	{
		name:      "external-secrets-webhook"
		namespace: "external-secrets"
		targetRef: {apiVersion: "apps/v1", kind: "Deployment", name: "external-secrets-webhook"}
		updateMode:     "InPlaceOrRecreate"
		resourcePolicy: _stdResourcePolicy
		tier:           C.tier
		cluster:        C.name
		owner:          "platform-team"
	},

	// ── User-facing tiles (stateless) ──────────────────────────────
	{
		name:      "homepage"
		namespace: "homepage"
		targetRef: {apiVersion: "apps/v1", kind: "Deployment", name: "homepage"}
		updateMode:     "InPlaceOrRecreate"
		resourcePolicy: _stdResourcePolicy
		tier:           C.tier
		cluster:        C.name
		owner:          "platform-team"
	},

	// ── Backup / cost ──────────────────────────────────────────────
	{
		name:      "velero"
		namespace: "velero"
		targetRef: {apiVersion: "apps/v1", kind: "Deployment", name: "velero"}
		updateMode:     "InPlaceOrRecreate"
		resourcePolicy: _stdResourcePolicy
		tier:           C.tier
		cluster:        C.name
		owner:          "platform-team"
	},
	// OpenCost VPAs removed 2026-05-16 — see helmreleases.cue comment.

	// ── Goldilocks (eat your own dog food) ─────────────────────────
	{
		name:      "goldilocks-controller"
		namespace: "goldilocks"
		targetRef: {apiVersion: "apps/v1", kind: "Deployment", name: "goldilocks-controller"}
		updateMode:     "InPlaceOrRecreate"
		resourcePolicy: _stdResourcePolicy
		tier:           C.tier
		cluster:        C.name
		owner:          "platform-team"
	},
	{
		name:      "goldilocks-dashboard"
		namespace: "goldilocks"
		targetRef: {apiVersion: "apps/v1", kind: "Deployment", name: "goldilocks-dashboard"}
		updateMode:     "InPlaceOrRecreate"
		resourcePolicy: _stdResourcePolicy
		tier:           C.tier
		cluster:        C.name
		owner:          "platform-team"
	},
]
