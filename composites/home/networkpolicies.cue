package home

let C = cluster

// Minimal egress baselines. Tighten once real backends live on-cluster.
// Traefik currently allows broad egress because the set of backends is
// not yet declared.
networkPolicies: [
	// Traefik egress — DNS, HTTPS/HTTP to any destination (external + the
	// kube-apiserver), and crucially every in-cluster namespace so Traefik
	// can proxy to any backend Service. Without the namespaceSelector
	// rule, Cilium denies Traefik egress to backend pod identities (e.g.
	// homepage on 3000, argocd-server on 8080) even though the legacy
	// `ipBlock: 0.0.0.0/0` rule looks like it should cover everything.
	// CIDR rules don't match in-cluster pod identities under Cilium, so
	// the namespace-allow is required. No ingress restriction (chart
	// Service is LoadBalancer; MetalLB forwards traffic direct to pod).
	{
		name:      "traefik-egress"
		namespace: "traefik"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		policy: {
			podSelector: {}
			policyTypes: ["Egress"]
			egress: [
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [
						{port: 80, protocol: "TCP"},
						{port: 443, protocol: "TCP"},
						{port: 6443, protocol: "TCP"},
					]
				},
				// LAN proxy backends. Several Ingresses point at off-cluster
				// hosts (e.g. metube, it-tools, recipes, n8n, webui,
				// home-assistant on 192.168.1.148) via Service+Endpoints
				// pairs that target NodePort-range ports on the LAN. Without
				// allowing egress to that port range, Traefik can't proxy
				// to any of these services. Range matches K8s default
				// NodePort allocation (30000-32767).
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [
						{port: 30000, endPort: 32767, protocol: "TCP"},
					]
				},
				// In-cluster proxy egress: allow Traefik to reach any pod
				// in any namespace on common HTTP/gRPC service ports. This
				// is what every Ingress backend lookup needs (homepage on
				// 3000, argocd-server on 8080, opencost on 9090, etc.).
				// Without this, Cilium silently drops Traefik->backend
				// traffic (since the destination has a pod identity, not
				// world). Ports listed cover the ports declared in
				// composites/home/helmreleases.cue Ingress backends; add
				// new ones here when adding new ingresses.
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 80, protocol: "TCP"},
						{port: 443, protocol: "TCP"},
						{port: 3000, protocol: "TCP"}, // homepage, redis, n8n
						{port: 5678, protocol: "TCP"}, // n8n editor
						{port: 8000, protocol: "TCP"}, // metube, recipes
						{port: 8080, protocol: "TCP"}, // argocd-server, traefik-dashboard, generic
						{port: 8081, protocol: "TCP"}, // argocd-repo-server gRPC
						{port: 8200, protocol: "TCP"}, // openbao
						{port: 8443, protocol: "TCP"}, // argocd-server tls
						{port: 4180, protocol: "TCP"}, // oauth2-proxy
						{port: 5556, protocol: "TCP"}, // dex
						{port: 9090, protocol: "TCP"}, // opencost / prometheus
						{port: 9100, protocol: "TCP"}, // node-exporter
						{port: 9200, protocol: "TCP"}, // velero metrics
						{port: 4318, protocol: "TCP"}, // OTLP/HTTP → jarvy-telemetry forwarder
					]
				},
			]
		}
	},

	// Longhorn internal — allow all within the namespace (manager ↔ engine
	// ↔ replica ↔ CSI), DNS, kube-api, and iSCSI to node-local targets.
	{
		name:      "longhorn-internal"
		namespace: "longhorn-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		policy: {
			podSelector: {}
			policyTypes: ["Ingress", "Egress"]
			ingress: [
				{
					from: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "longhorn-system"
					}]
				},
			]
			egress: [
				{
					to: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "longhorn-system"
					}]
				},
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [
						{port: 443, protocol: "TCP"},
						{port: 6443, protocol: "TCP"},
						{port: 3260, protocol: "TCP"},
					]
				},
			]
		}
	},

	// OpenBao isolation — the secret store is the crown jewel. Ingress
	// restricted to ESO (secret sync) and to the openbao namespace itself
	// (bootstrap Job + UI sidecar). Egress: DNS + kube-api (kubernetes auth).
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
				{
					from: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "external-secrets"
					}]
					ports: [{port: 8200, protocol: "TCP"}]
				},
				{
					// cert-manager calls OpenBao's Vault auth + PKI sign
					// endpoints to mint TLS certs (clusterissuer
					// openbao-example-internal). Without this rule, every
					// new Certificate resource hangs in "Failed to
					// initialize Vault client: context deadline exceeded"
					// (revealed during the 2026-05-06 Flannel→Cilium
					// migration when NPs started being enforced).
					from: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "cert-manager"
					}]
					ports: [{port: 8200, protocol: "TCP"}]
				},
				{
					from: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "openbao"
					}]
				},
				{
					// Traefik proxies the openbao-lan Ingress to the
					// openbao-ui Service on 8200. Without this, hits to
					// https://openbao.example.internal time out.
					from: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "traefik"
					}]
					ports: [{port: 8200, protocol: "TCP"}]
				},
				{
					// cert-distribution's openbao-ca-page init container
					// curls /v1/pki_home/ca/pem on every pod start to keep
					// the served root CA fresh. Public PKI endpoint, but
					// still gated through this NP since the openbao ns is
					// default-deny.
					from: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "cert-distribution"
					}]
					ports: [{port: 8200, protocol: "TCP"}]
				},
			]
			egress: [
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [{port: 443, protocol: "TCP"}]
				},
				{
					to: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "openbao"
					}]
				},
				// Dex OIDC discovery for OpenBao's oidc auth method.
				// dex.example.com CoreDNS-rewrites to traefik-internal;
				// kube-proxy-replacement targets traefik pods' websecure
				// container port 8443 (not Service port 443).
				{
					to: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "traefik"
					}]
					ports: [
						{port: 8000, protocol: "TCP"},
						{port: 8443, protocol: "TCP"},
					]
				},
			]
		}
	},

	// ESO egress — DNS, kube-api, and OpenBao on 8200.
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
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [{port: 443, protocol: "TCP"}]
				},
				{
					to: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "openbao"
					}]
					ports: [{port: 8200, protocol: "TCP"}]
				},
			]
		}
	},

	// ExternalDNS egress — DNS, kube-api, and the UniFi controller on the
	// LAN. UniFi IP is fluid per deployment; allow any LAN destination on
	// 443/TCP (UniFi HTTPS) and 8443/TCP (some controllers).
	{
		name:      "external-dns-egress"
		namespace: "external-dns"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		policy: {
			podSelector: {}
			policyTypes: ["Egress"]
			egress: [
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [
						{port: 443, protocol: "TCP"},
						{port: 8443, protocol: "TCP"},
					]
				},
			]
		}
	},

	// Cloudflared egress — DNS + Cloudflare edge (443 HTTPS + 7844 QUIC)
	// + forward into Traefik for ingress routing.
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
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [{port: 443, protocol: "TCP"}]
				},
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [
						{port: 7844, protocol: "TCP"},
						{port: 7844, protocol: "UDP"},
					]
				},
				{
					to: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "traefik"
					}]
					ports: [{port: 80, protocol: "TCP"}]
				},
				// Argo Events webhook EventSources — github-webhook (port
				// 12000) for GitHub deliveries, container-registry-webhook
				// (13000) for image-push events. Without this rule
				// cloudflared returns 502 with "i/o timeout dialing
				// 10.x.x.x:12000". Inert under Flannel; Cilium enforces.
				{
					to: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "argo-events"
					}]
					ports: [
						{port: 12000, protocol: "TCP"},
						{port: 13000, protocol: "TCP"},
					]
				},
				// Dex tunnel — cloudflared proxies off-LAN browser auth
				// flows to dex:5556 (OIDC discovery + /auth + /token).
				// Without this rule, dex.example.com via CF tunnel
				// times out at the cloudflared→dex hop.
				{
					to: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "dex"
					}]
					ports: [{port: 5556, protocol: "TCP"}]
				},
				// Jarvy telemetry forwarder — cloudflared proxies public
				// OTLP/HTTP from jarvyotel.example.com to the
				// jarvy-telemetry Service on 4318.
				{
					to: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "jarvy-telemetry"
					}]
					ports: [{port: 4318, protocol: "TCP"}]
				},
			]
		}
	},

	// Reloader (stakater) — pure controller. Egress: DNS + kube-apiserver
	// (via the cluster-wide allow-egress-to-kube-apiserver CCNP for the
	// 6443/CIDR path, plus 443 to 0.0.0.0/0 for the in-cluster Service
	// route to kubernetes.default.svc). No ingress; nothing else needs
	// to call it.
	{
		name:      "reloader-egress"
		namespace: "reloader"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		policy: {
			podSelector: {}
			policyTypes: ["Egress"]
			egress: [
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [{port: 443, protocol: "TCP"}]
				},
			]
		}
	},

	// Argo CD — ingress from traefik/argo-events/argocd; egress to DNS,
	// HTTPS (chart repos + GitHub API), external-secrets, plus intra-ns
	// (server↔repo-server↔redis↔app-controller↔applicationset-controller).
	// Cilium enforces NetworkPolicy in earnest, so intra-ns flows that
	// looked OK under Flannel must be declared explicitly.
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
				{from: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "traefik"}]},
				{from: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "argo-events"}]},
				{from: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "argocd"}]},
			]
			egress: [
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [{port: 443, protocol: "TCP"}]
				},
				{
					to: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "external-secrets"}]
				},
				// Dex OIDC discovery for ArgoCD's `oidc.config` (which
				// points at https://dex.example.com). CoreDNS rewrites
				// dex.example.com → traefik-internal.traefik.svc, then
				// Cilium kube-proxy-replacement DNATs to the Traefik pod's
				// containerPort 8443 (not Service port 443). Without this,
				// argocd-server's OIDC sign-in fails with "dial tcp
				// 192.168.1.235:443: i/o timeout". Mirror of the
				// openbao-traffic Dex egress allowance above.
				{
					to: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "traefik"
					}]
					ports: [
						{port: 8000, protocol: "TCP"},
						{port: 8443, protocol: "TCP"},
					]
				},
				// Intra-namespace: every Argo CD component talks to the others
				// (server→repo-server gRPC 8081, server→redis 6379, controller
				// →repo-server, applicationset-controller→repo-server, dex on
				// 5556 + 5557, notifications, image-updater, redis-ha). Allow
				// the whole namespace rather than enumerate every port — they
				// are stable and known-good intra-component flows.
				{
					to: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "argocd"}]
				},
			]
		}
	},

	// Argo Workflows — workflow-controller + argo-server + per-workflow
	// Pods. Controller watches Workflows via apiserver; workflow Pods
	// build container images with BuildKit and push to GHCR. The build
	// also posts to events.example.com/registry/push (via cloudflared)
	// to force ArgoCD sync. Argo Events spawns Workflows by creating
	// Workflow CRs, not via direct pod-to-pod — apiserver is the only
	// hop, so no ingress from argo-events needed.
	{
		name:      "argo-workflows-traffic"
		namespace: "argo-workflows"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		policy: {
			podSelector: {}
			policyTypes: ["Ingress", "Egress"]
			ingress: [
				// Traefik → argo-server UI (LAN only at workflows.example.internal).
				{from: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "traefik"}]},
				// Intra-namespace traffic (controller ↔ server ↔ workflow Pods).
				{from: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "argo-workflows"}]},
			]
			egress: [
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				// HTTPS to: GitHub (clone + App token mint + GHCR push),
				// events.example.com (registry-push notify).
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [{port: 443, protocol: "TCP"}]
				},
				// External-secrets in case the workflow needs a freshly
				// synced Secret (e.g. github-app-token at build time).
				{
					to: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "external-secrets"}]
				},
				// ArgoCD API for force-sync after image push (alternative
				// to the registry-push webhook path).
				{
					to: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "argocd"}]
				},
				// Intra-namespace.
				{
					to: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "argo-workflows"}]
				},
			]
		}
	},

	// Argo Events — ingress from cloudflared (webhook/registry events on
	// 12000/13000); egress to DNS, kube-api (via 6443/CIDR + the
	// allow-egress-to-kube-apiserver CCNP), ArgoCD gRPC, and intra-ns
	// (sensors→eventbus on NATS 4222; sensor leader-election; metrics).
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
				{
					from: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "cloudflared"}]
					ports: [
						{port: 12000, protocol: "TCP"},
						{port: 13000, protocol: "TCP"},
					]
				},
				// Intra-namespace ingress — eventbus pods accept NATS (4222),
				// monitoring (8222), routing (6222), and metrics (7777) from
				// sensors and event-sources in the same namespace. Sensors
				// also poll each other for leader election.
				{
					from: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "argo-events"}]
				},
			]
			egress: [
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [{port: 443, protocol: "TCP"}]
				},
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [{port: 6443, protocol: "TCP"}]
				},
				{
					to: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "argocd"}]
					ports: [{port: 8080, protocol: "TCP"}]
				},
				// Intra-namespace egress — sensors must reach the NATS
				// eventbus (4222) for leader election + event delivery.
				// Without this rule every sensor crash-loops with
				// "failed to new Nats Rpc: dial tcp <eventbus-ip>:4222
				// i/o timeout" once Cilium is the CNI.
				{
					to: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "argo-events"}]
				},
			]
		}
	},

	// Homepage — egress to kube-api (auto-discovery + widget metrics) +
	// DNS. Ingress allowed from Traefik (LAN clients reach via Ingress).
	{
		name:      "homepage-egress"
		namespace: "homepage"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		policy: {
			podSelector: {}
			policyTypes: ["Egress"]
			egress: [
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [{port: 443, protocol: "TCP"}]
				},
			]
		}
	},

	// OpenCost egress NetworkPolicy removed 2026-05-16 — see
	// helmreleases.cue comment. The kelos-egress rule that allows
	// kelos-system → opencost.9091 is left in place; it's a no-op
	// while the namespace is absent and re-enables the pushgateway path
	// instantly when OpenCost comes back.

	// Velero — egress to DNS, R2/S3 backup target on 443/HTTPS, Longhorn
	// for PVC mounts (intra-cluster traffic to longhorn-system), intra-ns
	// for kopia maintenance jobs talking to the velero deployment.
	{
		name:      "velero-egress"
		namespace: "velero"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		policy: {
			podSelector: {}
			policyTypes: ["Egress"]
			egress: [
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				// R2 (Cloudflare) for off-cluster backup storage — HTTPS
				// only; the bucket endpoint resolves to a fluid CDN IP.
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [{port: 443, protocol: "TCP"}]
				},
				// Velero's node-agent reads from any pod's volume during
				// kopia FS backup; Longhorn engine endpoints are on the
				// same node but use intra-cluster IPs that fall outside
				// 0.0.0.0/0 ipBlock under Cilium policyCIDRMatchMode.
				{
					to: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "longhorn-system"}]
				},
				// Intra-namespace — kopia maintenance jobs and Velero
				// itself talk to each other for backup metadata sync.
				{
					to: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "velero"}]
				},
			]
		}
	},

	// MetalLB — speaker runs on hostNetwork and needs to ARP/NDP-announce.
	// podSelector matches nothing restrictive: allow ingress/egress for
	// the controller pod; the speaker's hostNetwork bypasses pod-level
	// NetworkPolicy anyway.
	{
		name:      "metallb-controller"
		namespace: "metallb-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		policy: {
			podSelector: matchLabels: "app.kubernetes.io/component": "controller"
			policyTypes: ["Egress"]
			egress: [
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [{port: 6443, protocol: "TCP"}]
				},
			]
		}
	},

	// Dex — accept ingress on 5556 from traefik (browser flow) and from
	// in-cluster OIDC clients (argocd, openbao, oauth-proxy) for token
	// validation + discovery. Egress: DNS, kube-api (CCNP), Google OAuth
	// HTTPS, OpenBao (for ESO sync), kubernetes storage backend on
	// apiserver (also CCNP).
	{
		name:      "dex-traffic"
		namespace: "dex"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		policy: {
			podSelector: {}
			policyTypes: ["Ingress", "Egress"]
			ingress: [
				{
					from: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "traefik"}]
					ports: [{port: 5556, protocol: "TCP"}]
				},
				{
					// Cloudflared tunnel daemon proxies off-LAN browser
					// traffic from CF edge to dex:5556. Without this rule,
					// public access via dex.example.com tunnel times out
					// at the last hop (NP drop).
					from: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "cloudflared"}]
					ports: [{port: 5556, protocol: "TCP"}]
				},
				{
					from: [
						{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "argocd"},
						{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "openbao"},
						{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "oauth-proxy"},
					]
					ports: [{port: 5556, protocol: "TCP"}]
				},
				// Intra-namespace (no-op for single-pod Dex today, but
				// future replica count > 1 needs it for leader election).
				{
					from: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "dex"}]
				},
			]
			egress: [
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				// Google OAuth API (accounts.google.com, googleapis.com).
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [{port: 443, protocol: "TCP"}]
				},
				// ESO sync from OpenBao (dex-google + dex-static-clients).
				{
					to: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "openbao"}]
					ports: [{port: 8200, protocol: "TCP"}]
				},
			]
		}
	},

	// CloudNativePG operator — reconciles Cluster CRs into Postgres
	// StatefulSets across the cluster. Egress to kube-apiserver (CRD
	// watch + writes), DNS, and the namespaces hosting CNPG Cluster
	// instances (Coder so far). Ingress: webhook callbacks from
	// kube-apiserver (validating webhook on Cluster CRs).
	{
		name:      "cnpg-traffic"
		namespace: "cnpg-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		policy: {
			podSelector: {}
			policyTypes: ["Ingress", "Egress"]
			ingress: [
				// kube-apiserver -> CNPG validating webhook (port 9443).
				// apiserver is host-networked; allow from anywhere.
				{
					from: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [{port: 9443, protocol: "TCP"}]
				},
				// Metrics scrape from monitoring (future). OpenCost
				// removed 2026-05-16 — drop the allowance until a
				// monitoring stack is wired back in.
			]
			egress: [
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				// Operator manages CNPG Cluster pods (cnpg.io/cluster=*)
				// across any namespace. Allow egress to every ns on
				// the Postgres + monitoring ports.
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 5432, protocol: "TCP"},  // postgres
						{port: 8000, protocol: "TCP"},  // cnpg instance probe
						{port: 8080, protocol: "TCP"},  // cnpg instance probe (alt)
						{port: 9187, protocol: "TCP"},  // postgres_exporter
					]
				},
			]
		}
	},

	// oauth2-proxy — accepts ForwardAuth callbacks from Traefik plus the
	// browser-side OAuth flow at oauth.example.internal. Egress to Dex
	// for OIDC discovery + token exchange.
	{
		name:      "oauth-proxy-traffic"
		namespace: "oauth-proxy"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		policy: {
			podSelector: {}
			policyTypes: ["Ingress", "Egress"]
			ingress: [
				{
					// Cilium evaluates NP ports AFTER Service DNAT — the
					// oauth-redirect-page Service maps :80 → pod :8080,
					// and ForwardAuth from Traefik to oauth-redirect-page
					// would silently drop without allowing 8080 here.
					// Same trap as the coder-traffic NP. See
					// docs/troubleshooting-2026-05-14-cluster-recovery.md.
					from: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "traefik"}]
					ports: [
						{port: 4180, protocol: "TCP"}, // oauth2-proxy
						{port: 80, protocol: "TCP"},   // oauth2-proxy Service port (no DNAT)
						{port: 8080, protocol: "TCP"}, // oauth-redirect-page pod port (post-DNAT)
					]
				},
			]
			egress: [
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				// Dex OIDC discovery + token exchange. CoreDNS rewrites
				// dex.example.com -> traefik-internal.traefik.svc; with
				// Cilium kube-proxy replacement, the Service VIP rewrites
				// to the actual traefik pod IP and the TARGET port (not
				// Service port). Traefik's container ports are 8000 (web)
				// and 8443 (websecure) — those are what we need to allow.
				{
					to: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "traefik"}]
					ports: [
						{port: 8000, protocol: "TCP"},
						{port: 8443, protocol: "TCP"},
					]
				},
				// Direct path if cluster DNS ever stops rewriting, oauth2-proxy
				// can still reach Dex on its internal port.
				{
					to: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "dex"}]
					ports: [{port: 5556, protocol: "TCP"}]
				},
				// ESO sync from OpenBao.
				{
					to: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "openbao"}]
					ports: [{port: 8200, protocol: "TCP"}]
				},
			]
		}
	},

	// cert-manager — controller + webhook + cainjector. Egress: DNS,
	// kube-apiserver (covered by CCNP), Cloudflare API (DNS01), Let's
	// Encrypt ACME endpoints. Ingress: apiserver→webhook is covered by
	// the cluster-wide allow-ingress-from-host CCNP, so no per-ns rule.
	{
		name:      "cert-manager-traffic"
		namespace: "cert-manager"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		policy: {
			podSelector: {}
			policyTypes: ["Egress"]
			egress: [
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				// Cloudflare DNS01 challenge + Let's Encrypt ACME directory.
				// Both external HTTPS; covers acme-v02 + acme-staging too.
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [{port: 443, protocol: "TCP"}]
				},
			]
		}
	},

	// Descheduler — pure controller workload. Talks to apiserver only
	// (kubectl-style list + evict). No ingress; egress to DNS +
	// kube-apiserver via CCNP.
	{
		name:      "descheduler-egress"
		namespace: "descheduler"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		policy: {
			podSelector: {}
			policyTypes: ["Egress"]
			egress: [
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
			]
		}
	},

	// Goldilocks — VPA-recommendation dashboard + controller. Ingress
	// from Traefik for the dashboard UI (Service :80 → pod :8080, both
	// allowed to dodge the post-DNAT trap). Controller hits apiserver
	// via CCNP.
	{
		name:      "goldilocks-traffic"
		namespace: "goldilocks"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		policy: {
			podSelector: {}
			policyTypes: ["Ingress", "Egress"]
			ingress: [
				{
					from: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "traefik"}]
					ports: [
						{port: 80, protocol: "TCP"},
						{port: 8080, protocol: "TCP"},
					]
				},
			]
			egress: [
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
			]
		}
	},

	// kelos-system — operator + spawner pods + claude-code task pods.
	// Egress: DNS, kube-apiserver (CCNP), GitHub API, Anthropic API,
	// container-registry pulls (all external HTTPS), OpenBao for secret
	// reads, opencost pushgateway for per-task cost metrics, argo-events
	// eventsources for Discord webhooks.
	{
		name:      "kelos-egress"
		namespace: "kelos-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		policy: {
			podSelector: {}
			policyTypes: ["Egress"]
			egress: [
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				{
					to: [{ipBlock: cidr: "0.0.0.0/0"}]
					ports: [{port: 443, protocol: "TCP"}]
				},
				{
					to: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "openbao"}]
					ports: [{port: 8200, protocol: "TCP"}]
				},
				{
					to: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "opencost"}]
					ports: [{port: 9091, protocol: "TCP"}]
				},
				{
					to: [{namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "argo-events"}]
					ports: [
						{port: 12000, protocol: "TCP"},
						{port: 13000, protocol: "TCP"},
					]
				},
			]
		}
	},

	// VPA system — recommender + updater + admission-controller.
	// Talks to apiserver only (covered by CCNP). The admission webhook
	// is reached BY apiserver (covered by allow-ingress-from-host CCNP).
	{
		name:      "vpa-egress"
		namespace: "vpa-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		policy: {
			podSelector: {}
			policyTypes: ["Egress"]
			egress: [
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
			]
		}
	},

	// cert-distribution — openbao-ca-page. Ingress only from Traefik
	// (port 8080, the nginx-unprivileged containerPort — NPs evaluate
	// post-DNAT so the targetPort is the gate, not Service port 80).
	// Egress to DNS and to OpenBao:8200 for the init container's
	// PKI root fetch.
	{
		name:      "cert-distribution-default"
		namespace: "cert-distribution"
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
					ports: [{port: 8080, protocol: "TCP"}]
				},
			]
			egress: [
				{
					to: [{namespaceSelector: {}}]
					ports: [
						{port: 53, protocol: "UDP"},
						{port: 53, protocol: "TCP"},
					]
				},
				{
					to: [{
						namespaceSelector: matchLabels: "kubernetes.io/metadata.name": "openbao"
					}]
					ports: [{port: 8200, protocol: "TCP"}]
				},
			]
		}
	},
]
