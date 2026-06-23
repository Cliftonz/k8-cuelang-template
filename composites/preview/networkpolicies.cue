package preview

let C = cluster

networkPolicies: [
	// OpenBao isolation — the secret store is the crown jewel. Ingress is
	// restricted to the external-secrets namespace (ESO syncing secrets) and
	// to the openbao namespace itself (bootstrap Job, UI sidecar). Egress is
	// restricted to DNS and the Kubernetes API (for kubernetes auth).
	{
		name:      "openbao-isolation"
		namespace: "openbao"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		policy: {
			podSelector: {}
			policyTypes: ["Ingress", "Egress"]
			ingress: [
				// External Secrets Operator reads secrets from OpenBao API
				{
					from: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "external-secrets"
					}]
					ports: [{port: 8200, protocol: "TCP"}]
				},
				// openbao-bootstrap Job and pod-to-pod within openbao ns
				{
					from: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "openbao"
					}]
				},
			]
			egress: [
				// DNS resolution
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				// Kubernetes API server — required for kubernetes auth method
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [{port: 443, protocol: "TCP"}]
				},
				// Pod-to-pod within openbao ns (raft-style HA if enabled later)
				{
					to: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "openbao"
					}]
				},
			]
		}
	},

	// External Secrets Operator egress — needs DNS, Kubernetes API, and
	// access to OpenBao on 8200.
	{
		name:      "external-secrets-egress"
		namespace: "external-secrets"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		policy: {
			podSelector: {}
			policyTypes: ["Egress"]
			egress: [
				// DNS
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				// Kubernetes API
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [{port: 443, protocol: "TCP"}]
				},
				// OpenBao
				{
					to: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "openbao"
					}]
					ports: [{port: 8200, protocol: "TCP"}]
				},
			]
		}
	},

	// Argo CD egress — controller needs Kubernetes API, repo-server needs
	// HTTPS to chart/git repositories, notifications controller needs HTTPS
	// to api.github.com, ApplicationSet pullRequest generator needs HTTPS
	// to api.github.com. Ingress is allowed from traefik (for the UI, if used)
	// and from within the argocd namespace.
	{
		name:      "argocd-traffic"
		namespace: "argocd"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		policy: {
			podSelector: {}
			policyTypes: ["Ingress", "Egress"]
			ingress: [
				{
					from: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "traefik"
					}]
				},
				{
					from: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "argo-events"
					}]
				},
				{
					from: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "argocd"
					}]
				},
			]
			egress: [
				// DNS
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				// HTTPS — chart repos, GitHub API, git over HTTPS
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [{port: 443, protocol: "TCP"}]
				},
				// External Secrets for argocd-notifications-secret + github-token
				{
					to: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "external-secrets"
					}]
				},
			]
		}
	},

	// Cloudflared tunnel egress — cloudflared pods need outbound access to
	// Cloudflare edge (443/TCP and 7844/TCP+UDP for QUIC) and to the Traefik
	// service inside the cluster. No ingress allowed.
	{
		name:      "cloudflared-egress"
		namespace: "cloudflared"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		policy: {
			podSelector: {}
			policyTypes: ["Ingress", "Egress"]
			ingress: []
			egress: [
				// DNS resolution
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				// Cloudflare edge — HTTPS fallback
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [{port: 443, protocol: "TCP"}]
				},
				// Cloudflare edge — QUIC preferred transport
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [
						{port: 7844, protocol: "TCP"},
						{port: 7844, protocol: "UDP"},
					]
				},
				// Forward to Traefik service for ingress routing
				{
					to: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "traefik"
					}]
					ports: [{port: 80, protocol: "TCP"}]
				},
			]
		}
	},

	// Argo Events namespace isolation — restricts Argo Events pods to DNS,
	// HTTPS (GitHub webhooks, container registry), and the Kubernetes API.
	{
		name:      "argo-events-isolation"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		policy: {
			podSelector: {}
			policyTypes: ["Ingress", "Egress"]
			ingress: [
				// Cloudflared routes events.example.com/{github/pr,registry/push}
				// directly to the EventSource services on ports 12000/13000,
				// bypassing Traefik. Allow ingress from the cloudflared namespace.
				{
					from: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "cloudflared"
					}]
					ports: [
						{port: 12000, protocol: "TCP"},
						{port: 13000, protocol: "TCP"},
					]
				},
			]
			egress: [
				// DNS resolution
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				// HTTPS — Argo CD server, external APIs
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [{port: 443, protocol: "TCP"}]
				},
				// Kubernetes API server
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [{port: 6443, protocol: "TCP"}]
				},
				// Argo CD gRPC
				{
					to: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "argocd"
					}]
					ports: [{port: 8080, protocol: "TCP"}]
				},
			]
		}
	},
]
