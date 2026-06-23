package home

import "encoding/yaml"

let C = cluster

helmReleases: [
	// MetalLB — LAN load-balancer. Two pools are declared in metallb.cue
	// (lan-dmz, lan-internal), both opt-in. Speaker DaemonSet runs on
	// every node in the L2 segment and ARP-announces the allocated IPs.
	//
	// Reserve both IP ranges OUTSIDE UniFi DHCP before this release comes
	// up. FRR disabled — pure L2 mode, no BGP.
	{
		name:      "metallb"
		namespace: "metallb-system"
		chart: {
			name:       "metallb"
			repository: "https://metallb.github.io/metallb"
			version:    "0.16.1"
		}
		values: {
			controller: {
				resources: {
					requests: {cpu: "50m", memory: "64Mi"}
					limits: {cpu: "200m", memory: "128Mi"}
				}
			}
			speaker: {
				resources: {
					requests: {cpu: "50m", memory: "64Mi"}
					limits: {cpu: "200m", memory: "128Mi"}
				}
				frr: enabled: false
			}
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// Longhorn — block storage. 2-replica HA across worker nodes once
	// the cluster has ≥3 healthy workers. Each PVC's data is kept on
	// two different nodes so a single-node disk loss doesn't lose
	// the volume — the surviving replica gets re-replicated to a
	// third node automatically.
	//
	// NOTE: bumping `defaultReplicaCount` does NOT retroactively
	// add a second replica to existing volumes. To upgrade existing
	// PVCs in place:
	//   kubectl -n longhorn-system patch volumes.longhorn.io <name> \
	//     --type=merge -p '{"spec":{"numberOfReplicas":2}}'
	// Longhorn then rebuilds the second replica from the live one
	// (online, no downtime). Bumped 2026-05-15 after the 4-node
	// cluster recovery.
	//
	// Node prereqs (tracked in infrastructure/talos/longhorn-uservolume.yaml
	// and infrastructure/longhorn/install.sh):
	//   1. iscsi-tools + util-linux-tools Talos extensions (boot log confirms)
	//   2. UserVolumeConfig mounting /var/mnt/longhorn on a non-root disk
	{
		name:      "longhorn"
		namespace: "longhorn-system"
		chart: {
			name:       "longhorn"
			repository: "https://charts.longhorn.io"
			version:    "1.7.2"
		}
		values: {
			defaultSettings: {
				defaultDataPath:                   "/var/mnt/longhorn"
				defaultReplicaCount:               2
				persistentVolumeReclaimPolicy:     "Delete"
				replicaAutoBalance:                "best-effort"
				storageMinimalAvailablePercentage: 10
				orphanAutoDeletion:                false
			}
			persistence: {
				defaultClass:             true
				defaultClassReplicaCount: 2
				reclaimPolicy:            "Delete"
				defaultDataLocality:      "best-effort"
				defaultFsType:            "ext4"
			}
			ingress: enabled: false
			longhornManager: resources: {
				requests: {cpu: "100m", memory: "128Mi"}
				limits: {cpu: "1", memory: "512Mi"}
			}
			longhornDriver: resources: {
				requests: {cpu: "100m", memory: "128Mi"}
				limits: {cpu: "500m", memory: "256Mi"}
			}
			longhornUI: {
				replicas: 1
				resources: {
					requests: {cpu: "50m", memory: "64Mi"}
					limits: {cpu: "200m", memory: "128Mi"}
				}
			}
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// OpenBao — secret store. Standalone file-backed, 10Gi PVC on Longhorn.
	// Bootstrapped by the openbao-bootstrap Job (see jobs.cue) which inits,
	// unseals, enables the kubernetes auth method, and creates the ESO
	// policy + role. Unseal key + root token land in the `openbao-keys`
	// Secret — back that Secret up out-of-band.
	//
	// Paths on home follow the preview convention but under `home/`:
	//   secret/home/unifi → host, api_key, external
	{
		name:      "openbao"
		namespace: "openbao"
		chart: {
			name:       "openbao"
			repository: "https://openbao.github.io/openbao-helm"
			version:    "0.13.0"
		}
		values: {
			server: {
				dev: enabled: false
				standalone: {
					enabled: true
					config: #"""
						ui = true

						listener "tcp" {
						  tls_disable = 1
						  address = "[::]:8200"
						  cluster_address = "[::]:8201"
						}

						storage "file" {
						  path = "/openbao/data"
						}
						"""#
				}
				dataStorage: {
					enabled:      true
					size:         "10Gi"
					storageClass: "longhorn"
					accessMode:   "ReadWriteOnce"
				}
				resources: {
					requests: {cpu: "100m", memory: "256Mi"}
					limits: {cpu: "500m", memory: "512Mi"}
				}
				readinessProbe: {
					enabled: true
					path:    "/v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204"
				}
			}
			ui: {
				enabled:      true
				serviceType:  "ClusterIP"
				externalPort: 8200
				annotations: {
					"omni-kube-service-exposer.sidero.dev/port":   "50081"
					"omni-kube-service-exposer.sidero.dev/label":  "OpenBao (home)"
					"omni-kube-service-exposer.sidero.dev/prefix": "openbaohome"
				}
			}
			injector: enabled: false
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// External Secrets Operator — reads secrets from OpenBao via the
	// openbao-backend ClusterSecretStore (defined in clustersecretstores.cue)
	// and syncs them into cluster Secrets for the various consumer
	// namespaces (external-dns, ...).
	{
		name:      "external-secrets"
		namespace: "external-secrets"
		chart: {
			name:       "external-secrets"
			repository: "https://charts.external-secrets.io"
			version:    "0.12.1"
		}
		values: {
			crds: createClusterExternalSecret: true
			resources: {
				requests: {cpu: "50m", memory: "64Mi"}
				limits: {cpu: "200m", memory: "128Mi"}
			}
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// ExternalDNS — publishes A/CNAME records to a UniFi controller for
	// the home.example.internal zone. Runs in webhook mode with the
	// kashalls/external-dns-unifi-webhook sidecar. UniFi credentials
	// come from OpenBao via the external-dns-unifi-secret ExternalSecret.
	//
	// Required OpenBao seed (secret/home/unifi):
	//   host:     "https://192.168.x.x"     (UniFi controller URL)
	//   api_key:  "<UniFi admin API key>"
	//   external: "false"                   (true if non-UniFi hardware)
	{
		name:      "external-dns-unifi"
		namespace: "external-dns"
		chart: {
			name:       "external-dns"
			repository: "https://kubernetes-sigs.github.io/external-dns/"
			version:    "1.21.1"
		}
		values: {
			fullnameOverride: "external-dns-unifi"
			logLevel:         "info"

			provider: {
				name: "webhook"
				webhook: {
					image: {
						repository: "ghcr.io/kashalls/external-dns-unifi-webhook"
						tag:        "v0.8.2"
					}
					env: [
						{name: "UNIFI_HOST", valueFrom: secretKeyRef: {name: "external-dns-unifi-secret", key: "host"}},
						{name: "UNIFI_API_KEY", valueFrom: secretKeyRef: {name: "external-dns-unifi-secret", key: "api_key"}},
						{name: "UNIFI_EXTERNAL_CONTROLLER", valueFrom: secretKeyRef: {name: "external-dns-unifi-secret", key: "external"}},
						{name: "LOG_LEVEL", value: "info"},
					]
					livenessProbe: httpGet: {path: "/healthz", port: "http-webhook"}
					readinessProbe: httpGet: {path: "/readyz", port: "http-webhook"}
				}
			}

			extraArgs: ["--ignore-ingress-tls-spec"]
			policy: "sync"
			sources: ["ingress", "service"]
			txtOwnerId: "k8-infra-home"
			txtPrefix:  "k8s."
			// home.example.internal — cluster-scoped zone
			// example.internal     — apex zone for ad-hoc household services
			//                        (e.g. it-tools.example.internal). Ownership
			//                        is enforced by txtOwnerId TXT records, so
			//                        preview's external-dns won't touch records
			//                        we publish here and vice-versa.
			// example.com        — public TLD used only for hosts that need
			//                        a publicly-trusted Let's Encrypt cert
			//                        (Google OAuth rejects .internal TLDs).
			//                        UniFi serves these LAN-only; the public
			//                        Cloudflare zone never holds A records for
			//                        these hosts, only ACME challenge TXTs.
			domainFilters: ["home.example.internal", "example.internal", "example.com"]

			resources: {
				requests: {cpu: "50m", memory: "64Mi"}
				limits: {cpu: "200m", memory: "128Mi"}
			}
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// Traefik — reverse proxy serving two L2 segments. The chart's primary
	// Service is pinned to the DMZ MetalLB pool; a second LoadBalancer
	// Service (extraObjects) selects the same Traefik pods and is pinned
	// to the internal pool. Both advertise web/websecure.
	//
	// The Talos node needs a NIC on vlan10 for MetalLB speaker to
	// ARP-announce 192.168.1.x. Without it, the lan-internal Service will
	// allocate an IP but be unreachable from the internal segment.
	//
	// Zone isolation is enforced at UniFi (firewall rules between vlan10
	// and vlan50), not inside Traefik. Traefik itself host-routes by the
	// HTTP Host header; any hostname that resolves to either IP reaches
	// the same router.
	{
		name:      "traefik"
		namespace: "traefik"
		chart: {
			name:       "traefik"
			repository: "https://traefik.github.io/charts"
			version:    "33.2.1"
		}
		values: {
			deployment: replicas: 1

			// Primary Service — pinned to DMZ pool, specific IP.
			service: {
				type: "LoadBalancer"
				annotations: {
					"metallb.universe.tf/address-pool":    "lan-dmz"
					"metallb.universe.tf/loadBalancerIPs": "192.168.2.240"
				}
			}

			// Dashboard on :8080, no auth — reachable only via Omni
			// workload-proxy (authenticated at the Omni edge).
			api: {
				dashboard: true
				insecure:  true
			}

			// Access log + tracing — debug aid for the oauth2-proxy /
			// ForwardAuth chain (oauth.example.internal not bouncing
			// back to the originating host). Access log goes to stdout
			// in JSON so `kubectl -n traefik logs` shows every request
			// with router, middleware, downstream/upstream timings, and
			// the post-middleware Location header. Tracing forwards
			// OTLP/HTTP to the in-cluster jarvy-telemetry forwarder,
			// which already ships to Grafana Cloud.
			//
			// sampleRate 1.0 = capture every request. Dial down once
			// debugging is done; high QPS routers can blow Grafana
			// Cloud quota at 1.0.
			logs: {
				general: level: "INFO"
				access: {
					enabled: true
					format:  "json"
					fields: {
						general: {
							defaultmode: "keep"
							// Drop the noisy ClientUsername field
							// (always "-" since we don't do basic auth).
							names: ClientUsername: "drop"
						}
						headers: {
							// Default drop, then opt-in to headers
							// that matter for the oauth flow. Avoid
							// Cookie / Set-Cookie / Authorization to
							// keep session tokens out of logs.
							defaultmode: "drop"
							names: {
								Host:                "keep"
								"X-Forwarded-Host":  "keep"
								"X-Forwarded-Proto": "keep"
								"X-Forwarded-For":   "keep"
								"X-Real-Ip":         "keep"
								// Cloudflare always sets Cf-Connecting-Ip
								// to the original client IP — capturing it
								// lets us audit whether the jarvy-telemetry
								// rate-limit middleware is seeing real
								// client IPs (vs the cloudflared pod IP
								// when the chain is misconfigured).
								"Cf-Connecting-Ip": "keep"
								"Cf-Ipcountry":     "keep"
								"Cf-Ray":           "keep"
								Location:           "keep"
								Referer:            "keep"
								"User-Agent":       "keep"
							}
						}
					}
				}
			}
			tracing: {
				sampleRate: 1.0
				// Don't capture Cookie / Authorization headers — they
				// carry session secrets. Stick to routing-relevant
				// headers that mirror the access-log allow-list.
				capturedRequestHeaders: [
					"Host",
					"X-Forwarded-Host",
					"X-Forwarded-Proto",
					"X-Forwarded-For",
					"Cf-Connecting-Ip",
					"Cf-Ipcountry",
					"Cf-Ray",
					"Referer",
					"User-Agent",
				]
				capturedResponseHeaders: [
					"Location",
					"Content-Type",
				]
				otlp: {
					enabled: true
					http: {
						enabled: true
						// In-cluster OTLP/HTTP endpoint — avoids
						// round-tripping through the Cloudflare
						// tunnel that fronts jarvyotel.example.com.
						endpoint: "http://jarvy-telemetry-jarvy-telemetry-forwarder.jarvy-telemetry.svc.cluster.local:4318/v1/traces"
					}
				}
			}

			// (allowExternalNameServices is set in the providers block below)
			ingressRoute: dashboard: enabled: true
			ports: {
				traefik: expose: default: true
				web: {
					forwardedHeaders: trustedIPs: [
						"192.168.2.0/24",
						"192.168.1.0/24",
					]
					// Auto-redirect all HTTP traffic to HTTPS. Without this,
					// http://argocd.example.internal stays on HTTP and
					// browser HSTS doesn't kick in until the user manually
					// visits HTTPS once. 301 redirect at the entrypoint
					// covers every Ingress without per-Ingress annotations.
					redirectTo: {
						port: "websecure"
						// Priority must beat Ingress-generated routers (which
						// chart attaches to both web + websecure entrypoints,
						// priority based on rule specificity, typically 40-60).
						// 1000 ensures redirect always wins on the web port.
						priority: 1000
					}
				}
				websecure: forwardedHeaders: trustedIPs: [
					"192.168.2.0/24",
					"192.168.1.0/24",
				]
			}

			// Secondary LoadBalancer Service — pinned to internal pool,
			// selects the same Traefik pods as the chart's primary Service.
			// Plus the Omni-exposer Service for the dashboard.
			extraObjects: [
				{
					apiVersion: "v1"
					kind:       "Service"
					metadata: {
						name:      "traefik-internal"
						namespace: "traefik"
						annotations: {
							"metallb.universe.tf/address-pool":    "lan-internal"
							"metallb.universe.tf/loadBalancerIPs": "192.168.1.235"
						}
						labels: {
							"app.kubernetes.io/managed-by": "k8-infra"
							"app.kubernetes.io/part-of":    "platform"
						}
					}
					spec: {
						type: "LoadBalancer"
						selector: {
							"app.kubernetes.io/instance": "traefik-traefik"
							"app.kubernetes.io/name":     "traefik"
						}
						ports: [
							{name: "web", port: 80, targetPort: "web", protocol: "TCP"},
							{name: "websecure", port: 443, targetPort: "websecure", protocol: "TCP"},
						]
					}
				},
				{
					apiVersion: "v1"
					kind:       "Service"
					metadata: {
						name:      "traefik-dashboard"
						namespace: "traefik"
						annotations: {
							"omni-kube-service-exposer.sidero.dev/port":   "50083"
							"omni-kube-service-exposer.sidero.dev/label":  "Traefik (home)"
							"omni-kube-service-exposer.sidero.dev/prefix": "traefikhome"
						}
						labels: {
							"app.kubernetes.io/managed-by": "k8-infra"
							"app.kubernetes.io/part-of":    "platform"
						}
					}
					spec: {
						type: "ClusterIP"
						selector: {
							"app.kubernetes.io/instance": "traefik-traefik"
							"app.kubernetes.io/name":     "traefik"
						}
						ports: [{
							name:       "traefik"
							port:       8080
							targetPort: 8080
							protocol:   "TCP"
						}]
					}
				},
				// Redirect `/` on the traefik entrypoint (port 8080) to
				// `/dashboard/` so the Omni workload-proxy URL lands on
				// the UI instead of Traefik's 404.
				{
					apiVersion: "traefik.io/v1alpha1"
					kind:       "Middleware"
					metadata: {
						name:      "dashboard-root-redirect"
						namespace: "traefik"
					}
					spec: redirectRegex: {
						regex:       "^(https?://[^/]+)/?$"
						replacement: "${1}/dashboard/"
						permanent:   false
					}
				},
				{
					apiVersion: "traefik.io/v1alpha1"
					kind:       "IngressRoute"
					metadata: {
						name:      "dashboard-root"
						namespace: "traefik"
					}
					spec: {
						entryPoints: ["traefik"]
						routes: [{
							match: "PathPrefix(`/`) && !PathPrefix(`/dashboard`) && !PathPrefix(`/api`)"
							kind:  "Rule"
							services: [{name: "api@internal", kind: "TraefikService"}]
							middlewares: [{name: "dashboard-root-redirect"}]
						}]
					}
				},

				// Browser Cache-Control for the Homepage dashboard
				// (home.example.internal). Referenced by the homepage Ingress
				// as homepage-html-cache@kubernetescrd. Lives here (Traefik
				// owns Middlewares) because the jameswynn homepage chart has
				// no extraObjects hook. Was infrastructure/homepage/middleware-html-cache.yaml,
				// which bootstrap never applied → homepage 404'd on recreate.
				{
					apiVersion: "traefik.io/v1alpha1"
					kind:       "Middleware"
					metadata: {
						name:      "html-cache"
						namespace: "homepage"
						labels: {
							"app.kubernetes.io/managed-by": "k8-infra"
							"app.kubernetes.io/part-of":    "platform"
						}
					}
					spec: headers: customResponseHeaders: "Cache-Control": "public, max-age=300, must-revalidate"
				},

				// Strip X-Forwarded-For before requests reach Home Assistant. HA
				// has use_x_forwarded_for: true but its trusted_proxies list omits
				// the SNAT'd cluster node IPs, so it returns 400: Bad Request on
				// any proxied request carrying XFF. HA runs off-cluster
				// (192.168.1.148:30103) and we can't push config to it, so we
				// drop the header at the edge. Referenced by the home-assistant
				// Ingress as home-assistant-strip-xff@kubernetescrd. Tradeoff: HA
				// sees the node IP as the client (login-ban / geolocation become
				// per-proxy — acceptable for a LAN-only dashboard).
				{
					apiVersion: "traefik.io/v1alpha1"
					kind:       "Middleware"
					metadata: {
						name:      "strip-xff"
						namespace: "home-assistant"
						labels: {
							"app.kubernetes.io/managed-by": "k8-infra"
							"app.kubernetes.io/part-of":    "platform"
						}
					}
					spec: headers: customRequestHeaders: "X-Forwarded-For": ""
				},

				// ──────────────────────────────────────────────────────────
				// jarvy-telemetry OTLP rate-limit (Option B from the
				// telemetry-forwarder security review).
				//
				// Path: cloudflare edge → cloudflared tunnel → Traefik (this
				// IngressRoute on the `web` entrypoint with priority 2000 to
				// bypass the global HTTP→HTTPS redirect) → forwarder Service.
				// The cloudflare-tunnel Ingress for jarvyotel.example.com
				// is repointed at the `traefik` Service in ingresses.cue so
				// requests land here.
				//
				// Defense layers (Cloudflare WAF/rate-limit handles tier 1
				// at the edge; this is the cluster-local backstop):
				//   - bodylimit: cap at 64 KiB per request
				//   - ratelimit: 60 req/min/IP, 30 burst, depth=2 on
				//     X-Forwarded-For to strip cloudflared + cf-edge and
				//     read the real client IP. Verify with a curl loop —
				//     if 429s never fire, source IP at Traefik is the
				//     cloudflared pod (single source) and depth needs a
				//     bump.
				//   - method+path filter on the IngressRoute: only
				//     POST /v1/{logs,metrics,traces} matches; anything
				//     else 404s before hitting middlewares.
				// ──────────────────────────────────────────────────────────
				{
					apiVersion: "traefik.io/v1alpha1"
					kind:       "Middleware"
					metadata: {
						name:      "jarvy-telemetry-ratelimit"
						namespace: "jarvy-telemetry"
					}
					spec: rateLimit: {
						average: 60
						burst:   30
						period:  "1m"
						sourceCriterion: requestHeaderName: "Cf-Connecting-Ip"
					}
				},
				{
					apiVersion: "traefik.io/v1alpha1"
					kind:       "Middleware"
					metadata: {
						name:      "jarvy-telemetry-bodylimit"
						namespace: "jarvy-telemetry"
					}
					spec: buffering: {
						maxRequestBodyBytes: 65536
						memRequestBodyBytes: 65536
					}
				},
				{
					apiVersion: "traefik.io/v1alpha1"
					kind:       "IngressRoute"
					metadata: {
						name:      "jarvy-telemetry-otlp"
						namespace: "jarvy-telemetry"
					}
					spec: {
						// Web entrypoint only — cloudflared terminates TLS at
						// the edge and forwards HTTP cluster-internal. Priority
						// 2000 wins over the entrypoint-level HTTP→HTTPS
						// redirect (priority 1000), so requests land here
						// instead of being 301'd back through Cloudflare.
						entryPoints: ["web"]
						routes: [{
							match:    "(Host(`jarvyotel.example.com`) || Host(`telemetry.jarvy.dev`)) && Method(`POST`) && (PathPrefix(`/v1/logs`) || PathPrefix(`/v1/metrics`) || PathPrefix(`/v1/traces`))"
							kind:     "Rule"
							priority: 2000
							middlewares: [
								{name: "jarvy-telemetry-bodylimit"},
								{name: "jarvy-telemetry-ratelimit"},
							]
							services: [{
								name: "jarvy-telemetry-jarvy-telemetry-forwarder"
								port: 4318
							}]
						}]
					}
				},
			]
			ingressClass: {
				enabled:        true
				isDefaultClass: true
			}
			providers: {
				kubernetesIngress: {
					// Required for per-host /oauth2/* bridge Services in
					// goldilocks / opencost / traefik that forward to
					// oauth2-proxy via ExternalName (cross-namespace).
					allowExternalNameServices: true
					allowEmptyServices:        true
					// Ingresses in goldilocks / opencost / traefik reference
					// Middleware CRDs in the `oauth-proxy` namespace
					// (`oauth-proxy-auth-with-redirect@kubernetescrd`).
					// Without this flag Traefik silently 404s those routes
					// with "middleware does not exist".
					allowCrossNamespace: true
				}
				kubernetesCRD: {
					// Same cross-namespace need for IngressRoute / Middleware
					// CRD references that span namespaces.
					allowCrossNamespace: true
				}
				// Gateway API provider — registers Traefik as the
				// `traefik` GatewayClass. Requires Gateway API CRDs +
				// the Traefik kubernetes-gateway RBAC bundle (apply
				// once via infrastructure/gateway-api/install.sh).
				kubernetesGateway: enabled: true
			}
			resources: {
				requests: {cpu: "100m", memory: "128Mi"}
				limits: {cpu: "500m", memory: "256Mi"}
			}
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// Argo Events — webhook-driven CI/CD orchestration. Receives GitHub
	// webhooks + container registry events and triggers downstream Jobs
	// (sync-preview, spawn-agent, etc.).
	{
		name:      "argo-events"
		namespace: "argo-events"
		chart: {
			name:       "argo-events"
			repository: "https://argoproj.github.io/argo-helm"
			version:    "2.4.22"
		}
		values: {
			crds: install: true
			controller: {
				replicas: 1
				resources: {
					requests: {cpu: "100m", memory: "128Mi"}
					limits: {cpu: "500m", memory: "256Mi"}
				}
			}
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// Argo CD — GitOps engine. Manages preview Application lifecycle.
	// ApplicationSet generates one Application per open PR, notifications
	// posts deployment status to GitHub + AI-outage alerts to Discord.
	// Notification placeholders ($name) resolve against argocd-notifications-secret
	// which ESO syncs from OpenBao (see externalsecrets.cue).
	{
		name:      "argo-cd"
		namespace: "argocd"
		chart: {
			name:       "argo-cd"
			repository: "https://argoproj.github.io/argo-helm"
			// chart 9.6.0 ships argocd v3.x. Bumped from 7.7.16/v2.13.3
			// to fix the resource-tree walker bug where Application
			// .status.summary.images stays empty for most apps (Pods/RS
			// not added to the tree), which broke argocd-image-updater's
			// "image is live" check.
			version: "9.6.0"
		}
		values: {
			crds: install: true
			// Run argocd-server in HTTP mode — Traefik (LAN) and Omni proxy
			// terminate TLS upstream. Without this argocd issues a 308
			// redirect to https for every request and the Ingress hits
			// ERR_TOO_MANY_REDIRECTS.
			configs: {
				params: "server.insecure": true

				// OIDC via standalone Dex at dex.example.com. Embedded
				// Dex (argocd-dex-server) is disabled below since we have
				// a shared Dex serving OpenBao + oauth2-proxy too.
				// `$argocd-dex-client:client_secret` resolves to the secret
				// of the same name in the argocd namespace (ESO-synced
				// from secret/home/dex/clients property `argocd`).
				cm: {
					// Canonical URL. Argo CD validates post-login
					// return_url against this; without it the chart's
					// default `https://argocd.example.com` rejects every
					// real return_url with "Invalid redirect URL: the
					// protocol and host (including port) must match...".
					url: "https://argocd.example.internal"
					"oidc.config": """
						name: Dex
						issuer: https://dex.example.com
						clientID: argocd
						clientSecret: $argocd-dex-client:client_secret
						requestedScopes:
						  - openid
						  - profile
						  - email
						  - groups
						requestedIDTokenClaims:
						  groups:
						    essential: true
						"""
				}

				// Group → role bindings. Mirrors Dex Google connector
				// group claims. eng-admin@ gets full admin, eng-readonly@
				// gets argocd's built-in `readonly` role (view-only across
				// projects). Any user not in either group can authenticate
				// (Workspace internal-only consent screen) but has no
				// permissions until added to a group.
				rbac: {
					"policy.default": "role:readonly"
					"policy.csv": """
						g, eng-admin@example.com, role:admin
						g, eng-readonly@example.com, role:readonly
						"""
				}
			}
			server: {
				replicas: 1
				resources: {
					requests: {cpu: "100m", memory: "128Mi"}
					limits: {cpu: "500m", memory: "256Mi"}
				}
				service: annotations: {
					"omni-kube-service-exposer.sidero.dev/port":   "50080"
					"omni-kube-service-exposer.sidero.dev/label":  "Argo CD"
					"omni-kube-service-exposer.sidero.dev/prefix": "argocd"
				}
			}
			controller: {
				replicas: 1
				resources: {
					// 512Mi limit OOMed the controller on 2026-05-23 while
					// prune-finalizing a preview env concurrent with a
					// stuck Supabase reconcile. Bumped to give headroom for
					// peak load (large manifest sets + multiple in-progress
					// ops).
					requests: {cpu: "250m", memory: "1Gi"}
					limits: {cpu: "1", memory: "2Gi"}
				}
			}
			applicationSet: {
				replicas: 1
				resources: {
					requests: {cpu: "100m", memory: "128Mi"}
					limits: {cpu: "500m", memory: "256Mi"}
				}
			}
			repoServer: {
				replicas: 1
				resources: {
					requests: {cpu: "100m", memory: "128Mi"}
					// Git clones spike memory; large repos can OOM with
					// stricter caps. Bump if the repo-server pod gets
					// repeatedly evicted under load.
					limits: {cpu: "1", memory: "512Mi"}
				}
			}
			// Disable Argo CD's embedded Dex — we run a standalone Dex at
			// dex.example.com that serves OpenBao + oauth2-proxy too.
			// One Google OAuth client and one set of group bindings cover
			// every consumer.
			dex: enabled: false
			redis: {
				resources: {
					requests: {cpu: "50m", memory: "64Mi"}
					limits: {cpu: "200m", memory: "128Mi"}
				}
			}
			notifications: {
				enabled: true
				resources: {
					requests: {cpu: "50m", memory: "64Mi"}
					limits: {cpu: "200m", memory: "128Mi"}
				}
				// Hostname for notification body URLs. Uses Argo Notifications'
				// label syntax (`.app.metadata.labels.X`) rather than
				// ApplicationSet's generator-param syntax. Always the base
				// host that the chart's index page lives at — Discord/GitHub
				// links land devs on the index, which then hops them to
				// app/mailpit/supabase as needed.
				_notifyPreviewHost: "{{.app.metadata.labels.appslug}}-pr-{{.app.metadata.labels.pr-number}}.example.internal"
				services: {
					"service.webhook.github": """
						url: https://api.github.com
						headers:
						- name: Authorization
						  value: token $github-token
						- name: Accept
						  value: application/vnd.github+json
						"""
					"service.webhook.discord": """
						url: $discord-webhook-url
						headers:
						- name: Content-Type
						  value: application/json
						"""
				}
				triggers: {
					"trigger.on-deployed": """
						- description: Preview synced and healthy
						  send: [github-deployment-status]
						  when: app.status.operationState.phase in ['Succeeded'] and app.status.health.status == 'Healthy'
						"""
					"trigger.on-health-degraded": """
						- description: Preview health degraded
						  send: [github-pr-comment-degraded]
						  when: app.status.health.status == 'Degraded'
						"""
					"trigger.on-ai-outage": """
						- description: Preview with AI dependency degraded
						  send: [discord-ai-outage]
						  when: app.status.health.status == 'Degraded' and app.metadata.annotations['preview.example.com/depends-on-ai'] == 'true'
						"""
				}
				templates: {
					"template.github-deployment-status":   """
webhook:
  github:
    method: POST
    path: /repos/\(##"{{.app.spec.source.repoURL | call "trimPrefix" "https://github.com/" | call "trimSuffix" ".git"}}"##)/issues/{{.app.metadata.labels.pr-number}}/comments
    body: |
      {"body": "Preview deployed: https://\(_notifyPreviewHost)"}
"""
					"template.github-pr-comment-degraded": """
webhook:
  github:
    method: POST
    path: /repos/\(##"{{.app.spec.source.repoURL | call "trimPrefix" "https://github.com/" | call "trimSuffix" ".git"}}"##)/issues/{{.app.metadata.labels.pr-number}}/comments
    body: |
      {"body": "Preview health degraded for \(_notifyPreviewHost)"}
"""
					"template.discord-ai-outage":          """
webhook:
  discord:
    method: POST
    body: |
      {"content": ":rotating_light: **AI outage detected** — `{{.app.metadata.name}}` is Degraded.\\nApp: {{.app.metadata.labels.appslug}}  PR: #{{.app.metadata.labels.pr-number}}\\nPreview: https://\(_notifyPreviewHost)\\nHealth: `{{.app.status.health.message}}`"}
"""
				}
			}
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// Argo Workflows — Kubernetes-native workflow engine. Used by the
	// preview pipeline to build container images in-cluster (BuildKit
	// rootless) when a PR is labeled `preview`. The Sensor in
	// argoevents.cue spawns a WorkflowTemplate-rendered Workflow per PR
	// event; the workflow clones, builds, and pushes to GHCR with the
	// short-lived GitHub App install token.
	//
	// Chart 1.0.14 ships Argo Workflows v4.0.5.
	{
		name:      "argo-workflows"
		namespace: "argo-workflows"
		chart: {
			name:       "argo-workflows"
			repository: "https://argoproj.github.io/argo-helm"
			version:    "1.0.16"
		}
		values: {
			crds: install: true
			workflow: {
				// ServiceAccount the rendered Workflow Pods run as. Created
				// + bound to workflowRole below. Workflow steps that mutate
				// cluster state (e.g. patching Applications via Argo CD API)
				// run with this SA.
				serviceAccount: {
					create: true
					name:   "argo-workflow"
				}
				rbac: create: true
			}
			controller: {
				// Single controller — single-cluster scope.
				replicas: 1
				resources: {
					requests: {cpu: "100m", memory: "128Mi"}
					limits: {cpu: "500m", memory: "512Mi"}
				}
				// Track parameter substitution within workflow defaults.
				workflowDefaults: spec: {
					// Force every workflow to run as the workflow SA above —
					// avoids accidental "use the controller SA" mistakes.
					serviceAccountName: "argo-workflow"
					// 1h hard ttl from workflow start; build should never
					// take this long. Frees Pod resources promptly.
					activeDeadlineSeconds: 3600
					// Garbage-collect completed workflows after 24h to keep
					// the etcd footprint bounded.
					ttlStrategy: {
						secondsAfterCompletion: 86400
						secondsAfterSuccess:    86400
						secondsAfterFailure:    86400
					}
					// Rootless BuildKit needs ~4-6 GiB for Next.js builds —
					// scheduled on whichever node has headroom. No node
					// selector enforced here, but resources.limits on the
					// build step prevent it from eating a whole node.
				}
			}
			server: {
				// Argo Workflows UI/API. Authentication via the same Dex
				// stack as Argo CD; expose via Ingress under
				// workflows.example.internal (LAN only — no preview-side
				// users need UI access).
				enabled:  true
				replicas: 1
				resources: {
					requests: {cpu: "50m", memory: "64Mi"}
					limits: {cpu: "200m", memory: "128Mi"}
				}
				// Run server in HTTP — Traefik terminates TLS at the LAN
				// ingress, matching the argo-cd pattern.
				authModes: ["server"]
				extraArgs: ["--auth-mode=server", "--secure=false"]
			}
			// Single-cluster install — workflow controller watches and
			// schedules Workflows in any namespace (cluster-scoped). Per
			// step instructions below, build workflows themselves run in
			// argo-workflows ns.
			singleNamespace: false
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// Argo CD Image Updater — polls OCI registries for new digests of
	// images referenced by Applications carrying argocd-image-updater.argoproj.io/*
	// annotations. When a tracked image's digest changes, patches the
	// Application's helm parameters via the Argo CD API (write-back-method=argocd),
	// which triggers Argo CD to sync and roll the Deployment.
	//
	// Registry creds are pulled from Secret/ghcr-pull-secret in argocd ns
	// (synced by ESO from preview/ghcr-pat — classic PAT, read:packages).
	{
		name:      "argocd-image-updater"
		namespace: "argocd"
		chart: {
			name:       "argocd-image-updater"
			repository: "https://argoproj.github.io/argo-helm"
			// v1.x is the new CRD-driven release: one ImageUpdater CR
			// (in argocd ns) selects Applications via namePattern and
			// declares per-image config inline, replacing the v0.x
			// annotation-on-Application model. We ship the CRs through
			// the chart's `extraObjects` hook below so all bb-apps
			// image-updater wiring lives in one CUE file.
			version: "1.2.2"
		}
		values: {
			// Install the ImageUpdater CRD bundled with the chart. The
			// extraObjects block below relies on it (creates ImageUpdater
			// CRs under argocd-image-updater.argoproj.io/v1alpha1). Without
			// `crds.install: true` the chart deploys the controller but
			// not the CRD, and provider-helm fails the install with
			// "no matches for kind ImageUpdater".
			crds: install: true
			config: {
				logLevel: "debug"
				registries: [{
					name:        "GitHub Container Registry"
					api_url:     "https://ghcr.io"
					prefix:      "ghcr.io"
					ping:        true
					credentials: "pullsecret:argocd/ghcr-pull-secret-image-updater"
				}]
				// Argo CD API — image-updater writes Application overrides via
				// the in-cluster API. argocd-server runs in HTTP mode (see
				// argo-cd HelmRelease above), so plaintext + insecure here.
				argocd: {
					grpcWeb:       true
					serverAddress: "argo-cd-argocd-server.argocd.svc:80"
					insecure:      true
					plaintext:     true
				}
			}
			// Default poll interval 2m. Override here if you need faster.
			interval: "2m"
			resources: {
				requests: {cpu: "50m", memory: "64Mi"}
				limits: {cpu: "200m", memory: "256Mi"}
			}
			// One ImageUpdater CR per bb-app. Each selects its Argo
			// Application via namePattern (= the Application name set in
			// argocd.cue), names the image to track, and points helm
			// `name`/`tag` paths at the bjw-s app-template fields the
			// chart renders. Strategy=digest tracks the digest of the
			// configured tag — when ghcr.io's `:latest` digest changes,
			// image-updater patches the Application's helm parameters
			// (write-back-method=argocd) → Argo CD syncs → pod rolls.
			extraObjects: [
				for _app in _bbApps {
					apiVersion: "argocd-image-updater.argoproj.io/v1alpha1"
					kind:       "ImageUpdater"
					metadata: {
						name:      "bb-\(_app.slug)"
						namespace: "argocd"
					}
					spec: {
						commonUpdateSettings: {
							updateStrategy: "digest"
							pullSecret:     "pullsecret:argocd/ghcr-pull-secret-image-updater"
						}
						applicationRefs: [{
							namePattern: "bb-\(_app.slug)"
							images: [{
								alias:     "main"
								imageName: "\(_app.image):\(_app.tag)"
								manifestTargets: helm: {
									name: "controllers.main.containers.main.image.repository"
									tag:  "controllers.main.containers.main.image.tag"
								}
							}]
							writeBackConfig: method: "argocd"
						}]
					}
				},
			]
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// Cloudflare Tunnel Ingress Controller (STRRL). Watches Ingress
	// resources with class=cloudflare-tunnel and auto-creates the tunnel
	// + DNS records + per-Ingress routing.
	// Ingresses defined as raw manifests under
	// infrastructure/cloudflared/ingresses.yaml.
	{
		name:      "cloudflare-tunnel-ingress-controller"
		namespace: "cloudflared"
		chart: {
			name:       "cloudflare-tunnel-ingress-controller"
			repository: "https://helm.strrl.dev"
			version:    "0.0.23"
		}
		values: {
			replicaCount: 1
			cloudflare: secretRef: {
				name:          "cloudflare-external-secret"
				accountIDKey:  "account_id"
				tunnelNameKey: "tunnel_name"
				apiTokenKey:   "api_token"
			}
			ingressClass: {
				name:            "cloudflare-tunnel"
				controllerValue: "strrl.dev/cloudflare-tunnel-ingress-controller"
				isDefaultClass:  false
			}
			resources: {
				requests: {cpu: "100m", memory: "128Mi"}
				limits: {cpu: "200m", memory: "256Mi"}
			}
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// Homepage — internal service catalog / landing page. Auto-discovers
	// services from Ingresses with `gethomepage.dev/enabled=true` annotation.
	// Reachable at home.example.internal once Ingress is in place.
	{
		name:      "homepage"
		namespace: "homepage"
		chart: {
			name:       "homepage"
			repository: "https://jameswynn.github.io/helm-charts"
			version:    "2.1.0"
		}
		values: {
			image: {
				repository: "ghcr.io/gethomepage/homepage"
				tag:        "v1.12.3"
			}
			// Homepage v0.10+ does anti-CSRF host validation. Without this,
			// any Host header that doesn't match localhost gets rejected
			// with "Host validation failed". Comma-separated allowlist.
			// Chart uses bjw-s common syntax — env is a map, not a list.
			env: HOMEPAGE_ALLOWED_HOSTS: "home.example.internal,homepage.homepage.svc.cluster.local"
			// RBAC for cluster-scoped Ingress watch (auto-discovery) +
			// the kubernetes widget (node/pod metrics).
			enableRbac: true
			serviceAccount: create: true

			// Auto-discover services by scanning Ingresses cluster-wide
			// for gethomepage.dev/* annotations.
			config: {
				kubernetes: mode: "cluster"

				// Empty list — auto-discovery from Ingress annotations
				// fills this in at runtime. To pin static entries (e.g.
				// for things without an Ingress), add them here.
				services: []
				bookmarks: [
					{
						NetBox: [
							{"NetBox Cloud": [{
								abbr: "NB"
								href: "https://your-netbox-tenant.cloud.netboxapp.com/"
							}]},
							{"NetBox Console": [{
								abbr: "NL"
								href: "https://console.netboxlabs.com/"
							}]},
						]
					},
				]

				widgets: [
					{
						kubernetes: {
							cluster: {
								show:      true
								cpu:       true
								memory:    true
								showLabel: true
								label:     "home"
							}
							nodes: {
								show:      true
								cpu:       true
								memory:    true
								showLabel: true
							}
						}
					},
					{
						resources: {
							backend:  "kubernetes"
							expanded: true
							cpu:      true
							memory:   true
						}
					},
				]

				settings: {
					title: "Home Cluster"
					theme: "dark"
					color: "slate"
					layout: {
						"Smart Home": {
							style:   "row"
							columns: 4
						}
						Tools: {
							style:   "row"
							columns: 4
						}
						Dev: {
							style:   "row"
							columns: 4
						}
						Platform: {
							style:   "row"
							columns: 4
						}
					}
				}
			}

			resources: {
				requests: {cpu: "50m", memory: "128Mi"}
				limits: {cpu: "200m", memory: "256Mi"}
			}
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// cert-manager — issues + auto-renews TLS certs for Ingresses. Pairs
	// with the Infisical PKI issuer (installed separately as a kustomize
	// bundle in infrastructure/cert-manager/) to mint certs from a
	// hosted private CA, replacing the self-signed Traefik default cert
	// on `*.example.internal` services.
	{
		name:      "cert-manager"
		namespace: "cert-manager"
		chart: {
			name:       "cert-manager"
			repository: "https://charts.jetstack.io"
			version:    "v1.20.2"
		}
		values: {
			crds: enabled: true
			// ACME DNS01 propagation check must bypass the cluster's
			// CoreDNS (which forwards to UniFi DNS, which serves
			// example.com as authoritative and returns NXDOMAIN for
			// the _acme-challenge.* records that live only at
			// Cloudflare). Pin to public recursive resolvers and pass
			// `--dns01-recursive-nameservers-only` so cert-manager
			// never falls back to the cluster path.
			//
			// NOTE: requires UniFi to NOT intercept outbound port-53
			// from the cluster CIDR. If UniFi's DNS redirect/hijack is
			// on, even these explicit resolvers get NXDOMAIN — see
			// docs/cert-manager-unifi-dns.md (TODO) or feedback
			// memory for the fix.
			extraArgs: [
				"--dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53",
				"--dns01-recursive-nameservers-only",
			]
			// Single replica is enough for a homelab. Webhook + cainjector
			// + controller all run with default 1 replica each.
			resources: {
				requests: {cpu: "50m", memory: "128Mi"}
				limits: {cpu: "500m", memory: "256Mi"}
			}
			webhook: resources: {
				requests: {cpu: "20m", memory: "64Mi"}
				limits: {cpu: "200m", memory: "128Mi"}
			}
			cainjector: resources: {
				requests: {cpu: "20m", memory: "128Mi"}
				limits: {cpu: "200m", memory: "256Mi"}
			}
			startupapicheck: resources: {
				requests: {cpu: "10m", memory: "32Mi"}
				limits: {cpu: "100m", memory: "64Mi"}
			}
			// ClusterIssuers shipped with the chart so they apply +
			// reconcile automatically (the chart's CRDs are present by
			// the time extraObjects render). Previously these lived as
			// hand-applied manifests in infrastructure/cert-manager/ and
			// were forgotten on cluster recreate — every *.example.internal
			// cert then failed ("ClusterIssuer not found") and Traefik
			// served its self-signed default ("CA is not correct").
			//
			// openbao-example-internal: signs *.example.internal via OpenBao
			//   PKI intermediate (pki_int), auth = OpenBao k8s auth role
			//   cert-manager. Goes Ready once OpenBao is up.
			// letsencrypt-example-public: public certs for example.com via
			//   ACME DNS01 (Cloudflare token from ESO cloudflare-api-token).
			// jetstack's cert-manager chart treats each extraObjects entry
			// as a (templated) YAML STRING, so marshal the structured defs.
			extraObjects: [
				yaml.Marshal({
					apiVersion: "cert-manager.io/v1"
					kind:       "ClusterIssuer"
					metadata: name: "openbao-example-internal"
					spec: vault: {
						server: "http://openbao.openbao.svc:8200"
						path:   "pki_int/sign/example-internal"
						auth: kubernetes: {
							mountPath: "/v1/auth/kubernetes"
							role:      "cert-manager"
							serviceAccountRef: name: "cert-manager"
						}
					}
				}),
				yaml.Marshal({
					apiVersion: "cert-manager.io/v1"
					kind:       "ClusterIssuer"
					metadata: name: "letsencrypt-example-public"
					spec: acme: {
						server: "https://acme-v02.api.letsencrypt.org/directory"
						email:  "admin@example.com"
						privateKeySecretRef: name: "letsencrypt-example-public-account"
						solvers: [{
							selector: dnsZones: ["example.com"]
							dns01: cloudflare: apiTokenSecretRef: {
								name: "cloudflare-api-token"
								key:  "api_token"
							}
						}]
					}
				}),
			]
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// Kelos operator — owns kelos.dev/Task / AgentConfig / TaskSpawner /
	// Workspace CRDs. Argo Events sensors (feature-ideator, -implementer,
	// feature-review-*, code-explain) all spawn kelos.dev/Task resources;
	// without this operator the sensor triggers fail with
	// "tasks.kelos.dev is forbidden / no resource type". Chart published
	// as public OCI artifact at ghcr.io/kelos-dev/charts/kelos.
	{
		name:      "kelos"
		namespace: "kelos-system"
		chart: {
			name:       "kelos"
			repository: "oci://ghcr.io/kelos-dev/charts"
			version:    "0.36.0"
		}
		values: {
			crds: {
				install: true
				keep:    true
			}
			// Telemetry off — small homelab cluster.
			telemetry: enabled: false
			// Webhook server disabled — Argo Events EventSources already
			// handle inbound GitHub webhooks; kelos's optional webhook
			// server would duplicate that path.
			webhookServer: sources: github: enabled: false
			// Resource caps: controller is the operator that watches Tasks
			// + manages reconcile loops (light); spawner is one Deployment
			// per AgentConfig that owns its own claude-code worker pods
			// (lighter — just a router); ghproxy proxies GitHub API calls
			// (memory-bound when caching).
			controller: resources: {
				requests: {cpu: "50m", memory: "128Mi"}
				limits: {cpu: "500m", memory: "512Mi"}
			}
			// spawner.resources + ghproxy.resources are wired straight
			// into --spawner-resource-{requests,limits} /
			// --ghproxy-resource-{requests,limits} CLI args on the
			// controller. The chart interpolates the value verbatim,
			// so it MUST be a flat name=value,name=value string —
			// nested maps render as Go's `map[cpu:X memory:Y]` and
			// crashloop the controller with "expected name=value".
			spawner: resources: {
				requests: "cpu=20m,memory=64Mi"
				limits:   "cpu=200m,memory=128Mi"
			}
			ghproxy: resources: {
				requests: "cpu=20m,memory=64Mi"
				limits:   "cpu=200m,memory=256Mi"
			}
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// VPA (Vertical Pod Autoscaler) — observes pod CPU/mem usage and
	// produces VerticalPodAutoscaler CR recommendations. Run in
	// "Off" updateMode by default: recommend, never auto-restart pods.
	// Goldilocks reads the VPA CRs and renders a dashboard.
	//
	// Pure CNCF/kubernetes-sigs governance. No commercial dependency.
	{
		name:      "vpa"
		namespace: "vpa-system"
		chart: {
			name:       "vpa"
			repository: "https://charts.fairwinds.com/stable"
			version:    "4.12.2"
		}
		values: {
			recommender: {
				enabled: true
				resources: {
					requests: {cpu: "50m", memory: "256Mi"}
					limits: {cpu: "500m", memory: "1Gi"}
				}
				// Use metrics-server (already installed) instead of a
				// dedicated Prometheus.
				extraArgs: {"prometheus-address": ""}
			}
			// Updater + admission-controller now ON — paired with K8s 1.36's
			// InPlacePodVerticalScaling beta-default-on, VPA can resize
			// pods in-place when a XVerticalPodAutoscaler CR sets
			// updateMode: InPlaceOrRecreate. Without resizePolicy on the
			// target Pod spec, in-place resize still triggers a container
			// restart but skips the full Pod evict+reschedule loop.
			updater: {
				enabled: true
				extraArgs: {
					"feature-gates": "InPlaceOrRecreate=true"
					// VPA default `--min-replicas=2` refuses to evict (or
					// in-place resize) a pod when the owning Deployment has
					// fewer than 2 replicas, to avoid taking single-replica
					// services to 0 mid-eviction. Nearly every workload on
					// home runs `replicas: 1`, which is why recommendations
					// showed in Goldilocks but never applied. With
					// InPlaceOrRecreate the kubelet attempts in-place resize
					// first (no eviction needed); fallback evict+recreate
					// remains best-effort even on replicas=1.
					"min-replicas": "1"
				}
				resources: {
					requests: {cpu: "50m", memory: "128Mi"}
					limits: {cpu: "200m", memory: "512Mi"}
				}
			}
			admissionController: {
				enabled: true
				extraArgs: {
					"feature-gates": "InPlaceOrRecreate=true"
				}
				resources: {
					requests: {cpu: "50m", memory: "64Mi"}
					limits: {cpu: "200m", memory: "256Mi"}
				}
			}
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// Descheduler — sigs.k8s.io/descheduler. The default kube-scheduler
	// places pods at creation time and never moves them, even when the
	// node distribution becomes wildly skewed (controllers and chart
	// installs pile onto whichever node was healthy at that moment).
	// Descheduler runs as a long-lived Deployment that periodically
	// inspects node utilization, and evicts pods from over-utilized
	// nodes so the scheduler can place them on under-utilized ones.
	//
	// Discovered the need 2026-05-15 after observing talos-node-08
	// running 68 pods (4.7 GiB requested, 13 GiB in limits) on an
	// 8 GiB worker while three other workers sat at 20-25% — three
	// successive node drains had cascaded all the evicted workloads
	// onto j6y-myr.
	//
	// Default policies (from the chart) cover what we want:
	//   - LowNodeUtilization (under 20% req → underutilized,
	//     over 50% req → overutilized; evicts to rebalance)
	//   - RemoveDuplicates (don't pile multiple replicas of one
	//     Deployment on the same node)
	//   - RemovePodsHavingTooManyRestarts (cleans up wedged crashloops)
	//   - RemovePodsViolatingNodeAffinity / NodeTaints / AntiAffinity /
	//     TopologySpreadConstraint (enforcement re-runs)
	//
	// Mode: Deployment (continuous, 5-min interval) instead of the
	// chart's default CronJob — fewer pod-create cycles, faster
	// reaction to drift.
	{
		name:      "descheduler"
		namespace: "descheduler"
		chart: {
			name:       "descheduler"
			repository: "https://kubernetes-sigs.github.io/descheduler/"
			version:    "0.36.0"
		}
		values: {
			kind:                 "Deployment"
			deschedulingInterval: "5m"
			replicas:             1
			// Use the chart's default deschedulerPolicy block — it
			// enables the right plugin set for our case. Override
			// here if we ever want tighter thresholds.
			resources: {
				requests: {cpu: "50m", memory: "64Mi"}
				limits: {cpu: "200m", memory: "256Mi"}
			}
			leaderElection: {
				enabled: true
			}
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// Goldilocks — Fairwinds dashboard on top of VPA. Watches namespaces
	// labeled `goldilocks.fairwinds.com/enabled=true`, generates a VPA
	// CR per Deployment, exposes a web UI at /. Label namespaces
	// individually to opt them in.
	{
		name:      "goldilocks"
		namespace: "goldilocks"
		chart: {
			name:       "goldilocks"
			repository: "https://charts.fairwinds.com/stable"
			version:    "10.4.0"
		}
		values: {
			vpa: {
				enabled: false // VPA installed separately above
			}
			controller: {
				resources: {
					requests: {cpu: "50m", memory: "64Mi"}
					limits: {cpu: "200m", memory: "128Mi"}
				}
			}
			dashboard: {
				replicaCount: 1
				resources: {
					requests: {cpu: "50m", memory: "64Mi"}
					limits: {cpu: "200m", memory: "128Mi"}
				}
			}
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// OpenCost + bundled Prometheus removed 2026-05-16 — keeping the
	// namespace, ai-cost-aggregator CronJob references, and Cilium egress
	// rules pointing at opencost-prometheus-prometheus-pushgateway.opencost
	// are all dormant (curl pushes fail safely with `|| true`). Re-add by
	// reverting the removal commit when ready to bring per-workload $$
	// visibility back online.

	// Velero — cluster backup: k8s resources (CRs, Secrets, ConfigMaps) +
	// Longhorn PVC snapshots via CSI. Off-site target is Cloudflare R2.
	// CNPG postgres databases get a SEPARATE backup via barman built into
	// the cnpg operator; Velero alone can't snapshot a running postgres
	// consistently (would need fsfreeze + WAL flush coordination).
	{
		name:      "velero"
		namespace: "velero"
		chart: {
			name:       "velero"
			repository: "https://vmware-tanzu.github.io/helm-charts"
			version:    "12.0.3"
		}
		values: {
			// Chart 12.0.1's CRD-upgrade Job uses `velero install
			// --crds-only --apply`, but velero v1.16.x dropped the
			// `--apply` flag. Disable the hook — CRDs install fine via
			// the chart's own templates/crds bundle on initial install.
			upgradeCRDs: false
			// Velero server (controller + plugin loop) — the heavyweight,
			// runs uploads when a backup fires.
			resources: {
				requests: {cpu: "100m", memory: "256Mi"}
				limits: {cpu: "1", memory: "1Gi"}
			}
			// Node agent runs a Restic/Kopia daemon for filesystem-level
			// backup of any volume that doesn't support CSI snapshots.
			// Caps are aggressive — kopia's working set scales with
			// volume count, not pod count.
			deployNodeAgent: true
			nodeAgent: resources: {
				requests: {cpu: "50m", memory: "256Mi"}
				limits: {cpu: "1", memory: "1Gi"}
			}
			initContainers: [
				{
					name:  "velero-plugin-for-aws"
					image: "velero/velero-plugin-for-aws:v1.13.1"
					volumeMounts: [{name: "plugins", mountPath: "/target"}]
				},
			]
			// Credentials Secret rendered by ESO from OpenBao
			// (`secret/data/preview/r2-velero` → cloud profile file).
			credentials: {
				useSecret:      true
				existingSecret: "velero-r2-creds"
			}
			configuration: {
				// FSB-only cluster. There is no CSI VolumeSnapshotClass /
				// external-snapshotter installed (the snapshot.storage.k8s.io
				// CRDs are absent), so EnableCSI just made every backup
				// PartiallyFailed on "no matches for kind VolumeSnapshot".
				// All volume data is captured via File System Backup
				// (defaultVolumesToFsBackup below). NOTE: chart 12.0.1 defaults
				// configuration.features to "EnableCSI" — it must be set to the
				// empty string to disable, not merely omitted. Re-enable (+ a
				// volumeSnapshotLocation) only after installing the
				// external-snapshotter + a Longhorn VolumeSnapshotClass.
				features: ""
				// FSB-only cluster — no CSI VolumeSnapshotClass / external
				// snapshotter installed. With this key unset the chart renders
				// a default VolumeSnapshotLocation with an empty `provider`,
				// which fails validation (spec.provider: Required) and wedges
				// every `helm upgrade` (provider-helm Release → STATE=failed).
				// Empty list = render no VSL. Re-add an entry (with provider +
				// config) only after installing a CSI snapshotter + a Longhorn
				// VolumeSnapshotClass — pair with re-enabling features:"EnableCSI".
				volumeSnapshotLocation: []
				backupStorageLocation: [{
					name:     "default"
					provider: "aws"
					bucket:   "home-cluster-backup"
					default:  true
					// Fresh repo generation. The 2026-06-02 Velero rebuild
					// minted a new kopia repo password; every pre-existing
					// repo under the old (empty) prefix was left NotReady
					// ("found existing data in storage location") — openable
					// by neither the new password nor a re-init. Bumping the
					// prefix gives Velero a clean namespace so FSB repos
					// initialize fresh. Old objects are orphaned in the bucket
					// (unreadable anyway); purge later to reclaim R2 space.
					prefix: "home-v2"
					config: {
						region:           "auto"
						s3ForcePathStyle: "true"
						// R2 endpoint without bucket suffix.
						s3Url: "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com"
					}
				}]
				// Default to filesystem backup so any PVC backs up even if
				// its StorageClass lacks a CSI snapshot driver. This is the
				// only volume-data path on home (no CSI snapshotter). Override
				// per-Backup with `defaultVolumesToFsBackup: false` only once
				// CSI snapshots are actually available.
				defaultVolumesToFsBackup: true
			}
			// Daily schedules — keep ~30 days of backups (ttl 720h).
			schedules: {
				"openbao-hourly": {
					disabled: false
					// Hourly — openbao is the secret-store of record;
					// daily RPO of 24h was too loose for credentials
					// that get rotated/added between coffee breaks.
					// Kopia dedup keeps the R2 footprint flat since
					// most hours change nothing.
					schedule: "0 * * * *"
					template: {
						includedNamespaces: ["openbao"]
						ttl:             "720h0m0s"
						snapshotVolumes: true
					}
				}
				"cluster-resources-daily": {
					disabled: false
					schedule: "0 4 * * *"
					template: {
						// Skip ephemeral / regenerable bits.
						excludedNamespaces: [
							"argo-events",
							"kube-public",
							"kube-node-lease",
						]
						excludedResources: [
							"events",
							"events.events.k8s.io",
							"endpoints",
							"endpointslices",
							"replicasets.apps",
						]
						ttl: "720h0m0s"
						// Cluster-resource backup only — no PVCs.
						snapshotVolumes:         false
						includeClusterResources: true
					}
				}
			}
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// Dex — OIDC issuer fronting Google Workspace. Consumed by Argo CD,
	// OpenBao, and oauth2-proxy (which in turn gates Traefik dashboard,
	// OpenCost, Goldilocks).
	//
	// LAN-only at https://dex.example.com. Cert from letsencrypt-example-public
	// Reloader (stakater) — watches Deployments/StatefulSets/DaemonSets
	// for annotations like `reloader.stakater.com/auto: "true"` and rolls
	// them whenever any Secret or ConfigMap they reference changes.
	// Required because charts that consume Secrets via `secretKeyRef` env
	// vars (Dex, openbao OIDC bits, oauth2-proxy) cache the value in pod
	// memory at startup; ESO can rotate the Secret object underneath them
	// but the running pod keeps serving the old value until restart.
	//
	// First fired Dex stale-secret incident 2026-05-17 (Dex pod started
	// 14h before ESO refreshed dex-static-clients with a rotated
	// client_secret, causing argocd's token exchange to fail with
	// invalid_client). With this annotation present, the next rotation
	// will roll Dex automatically.
	{
		name:      "reloader"
		namespace: "reloader"
		chart: {
			name:       "reloader"
			repository: "https://stakater.github.io/stakater-charts"
			version:    "2.2.12"
		}
		values: {
			reloader: {
				watchGlobally: true
				// Be explicit — we only need Secret-driven reloads
				// (ESO syncs); ConfigMap reloads are also useful but
				// less critical. Enable both for symmetry.
				autoReloadAll:          false
				readOnlyRootFileSystem: true
				deployment: {
					replicas: 1
					resources: {
						requests: {cpu: "20m", memory: "64Mi"}
						limits: {cpu: "200m", memory: "256Mi"}
					}
				}
			}
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// ClusterIssuer (real Let's Encrypt via Cloudflare DNS01). UniFi serves
	// the LAN A record via external-dns-unifi. Public example.com zone
	// holds only ACME challenge TXTs.
	//
	// Secrets: dex-google (Google OAuth client + SA JSON for Groups API)
	// and dex-static-clients (per-consumer secrets) come from OpenBao via
	// ESO (see composites/home/externalsecrets.cue).
	{
		name:      "dex"
		namespace: "dex"
		chart: {
			name:       "dex"
			repository: "https://charts.dexidp.io"
			version:    "0.21.0" // ships dex v2.42.0
		}
		values: {
			replicaCount: 1
			image: tag: "v2.42.0"

			// Stakater Reloader annotation — restarts this Deployment
			// whenever any Secret or ConfigMap referenced via secretKeyRef
			// / configMapKeyRef changes (dex-google, dex-static-clients).
			// Without it, ESO can rotate the underlying Secret but Dex
			// keeps the original value in env-var memory until the next
			// manual restart, breaking OIDC token exchanges for any
			// consumer whose pod also restarted and picked up the new
			// secret.
			deploymentAnnotations: {
				"reloader.stakater.com/auto": "true"
			}

			// Satisfy PSS "restricted" baseline. Dex's official image already
			// runs as uid 1001; we just need to declare it so admission stops
			// warning on every rollout.
			podSecurityContext: {
				runAsNonRoot: true
				runAsUser:    1001
				runAsGroup:   1001
				fsGroup:      1001
				seccompProfile: type: "RuntimeDefault"
			}
			securityContext: {
				allowPrivilegeEscalation: false
				capabilities: drop: ["ALL"]
				runAsNonRoot:           true
				readOnlyRootFilesystem: true
			}
			// readOnlyRootFilesystem: true blocks Dex's /tmp config-rewrite
			// step (it writes /tmp/dex.config.yaml-* during env substitution).
			// Mount an emptyDir for writable /tmp without giving up the
			// rest of the rootfs.
			volumes: [{
				name: "tmp"
				emptyDir: {}
			}, {
				name: "google-sa"
				secret: {
					secretName: "dex-google"
					items: [{key: "service_account_json", path: "google.json"}]
				}
			}]
			volumeMounts: [{
				name:      "tmp"
				mountPath: "/tmp"
			}, {
				name:      "google-sa"
				mountPath: "/etc/dex/google"
				readOnly:  true
			}]

			// Dex auto-substitutes $ENV_VAR style placeholders in the
			// config when it reads the ConfigMap. We inject secrets as
			// env vars from the ESO-synced Secrets, and the config below
			// references them by name.
			envVars: [
				{name: "GOOGLE_CLIENT_ID", valueFrom: secretKeyRef: {name: "dex-google", key: "client_id"}},
				{name: "GOOGLE_CLIENT_SECRET", valueFrom: secretKeyRef: {name: "dex-google", key: "client_secret"}},
				{name: "GOOGLE_ADMIN_EMAIL", valueFrom: secretKeyRef: {name: "dex-google", key: "admin_email"}},
				{name: "ARGOCD_CLIENT_SECRET", valueFrom: secretKeyRef: {name: "dex-static-clients", key: "argocd"}},
				{name: "OPENBAO_CLIENT_SECRET", valueFrom: secretKeyRef: {name: "dex-static-clients", key: "openbao"}},
				{name: "OAUTH2_PROXY_CLIENT_SECRET", valueFrom: secretKeyRef: {name: "dex-static-clients", key: "oauth2proxy"}},
			]

			config: {
				issuer: "https://dex.example.com"
				storage: {
					type: "kubernetes"
					config: inCluster: true
				}
				oauth2: skipApprovalScreen: true
				web: http:                  "0.0.0.0:5556"
				connectors: [{
					type: "google"
					id:   "google"
					name: "Google"
					config: {
						clientID:     "${GOOGLE_CLIENT_ID}"
						clientSecret: "${GOOGLE_CLIENT_SECRET}"
						redirectURI:  "https://dex.example.com/callback"
						hostedDomains: ["example.com"]
						serviceAccountFilePath: "/etc/dex/google/google.json"
						adminEmail:             "${GOOGLE_ADMIN_EMAIL}"
					}
				}]
				staticClients: [
					{
						id:   "argocd"
						name: "Argo CD"
						redirectURIs: [
							"https://argocd.example.internal/auth/callback",
						]
						secretEnv: "ARGOCD_CLIENT_SECRET"
					},
					{
						id:   "openbao"
						name: "OpenBao"
						redirectURIs: [
							// /ui/vault/... is the path used when the UI's "Sign in
							// with OIDC" button is clicked (browser flow).
							"https://openbao.example.internal/ui/vault/auth/oidc/oidc/callback",
							// /v1/auth/... is the path OpenBao generates when the
							// OIDC auth_url endpoint is hit directly (e.g. user
							// pastes the auth URL into the browser, or bao login
							// runs the web flow against the API). Without this
							// alias, that flow returns "Unregistered redirect_uri".
							"https://openbao.example.internal/v1/auth/oidc/oidc/callback",
							// localhost callback for `bao login -method=oidc` CLI.
							"http://localhost:8250/oidc/callback",
						]
						secretEnv: "OPENBAO_CLIENT_SECRET"
					},
					{
						id:   "oauth2-proxy"
						name: "oauth2-proxy"
						redirectURIs: [
							"https://oauth.example.internal/oauth2/callback",
						]
						secretEnv: "OAUTH2_PROXY_CLIENT_SECRET"
					},
				]
			}

			service: {
				type: "ClusterIP"
				ports: http: {
					containerPort: 5556
					port:          5556
					protocol:      "TCP"
				}
			}

			resources: {
				requests: {cpu: "50m", memory: "128Mi"}
				limits: {cpu: "200m", memory: "256Mi"}
			}
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// oauth2-proxy — wraps OIDC around apps without native OIDC. Single
	// deployment, single Dex static client `oauth2-proxy`, cookie scoped
	// to `.example.internal` so one Google sign-in covers every protected
	// app. Traefik's ForwardAuth middleware calls oauth2-proxy
	// /oauth2/auth on every request; if no session, oauth2-proxy starts
	// the OIDC dance with Dex.
	//
	// Protected apps annotate their Ingress with
	// `traefik.ingress.kubernetes.io/router.middlewares: oauth-proxy-forward-auth-dex@kubernetescrd`.
	{
		name:      "oauth2-proxy"
		namespace: "oauth-proxy"
		chart: {
			name:       "oauth2-proxy"
			repository: "https://oauth2-proxy.github.io/manifests"
			version:    "7.7.30"
		}
		values: {
			replicaCount: 1
			image: tag: "v7.7.1"

			config: {
				// Provider = OIDC (Dex), discover at issuer URL.
				configFile: """
					provider = "oidc"
					oidc_issuer_url = "https://dex.example.com"
					provider_display_name = "Example Org"
					email_domains = ["example.com"]
					redirect_url = "https://oauth.example.internal/oauth2/callback"
					cookie_domains = [".example.internal"]
					whitelist_domains = [".example.internal"]
					skip_provider_button = true
					reverse_proxy = true
					pass_access_token = true
					pass_authorization_header = true
					set_authorization_header = true
					set_xauthrequest = true
					# upstream is the Traefik ForwardAuth caller; oauth2-proxy
					# just answers /oauth2/auth and /oauth2/callback.
					upstreams = ["static://200"]
					# Force HTTPS cookies (browser sees HTTPS via Traefik).
					cookie_secure = true
					http_address = "0.0.0.0:4180"
					"""
				existingSecret: "oauth2-proxy-dex-client"
			}

			// Routes the client-id/secret from the ESO-managed secret.
			extraArgs: {
				"oidc-issuer-url":      "https://dex.example.com"
				"redirect-url":         "https://oauth.example.internal/oauth2/callback"
				"email-domain":         "example.com"
				"cookie-domain":        ".example.internal"
				"whitelist-domain":     ".example.internal"
				"reverse-proxy":        "true"
				"set-xauthrequest":     "true"
				"skip-provider-button": "true"
			}

			service: {
				type:       "ClusterIP"
				portNumber: 80
			}

			resources: {
				requests: {cpu: "20m", memory: "32Mi"}
				limits: {cpu: "100m", memory: "64Mi"}
			}

			// The Traefik auth plumbing that fronts gated apps, shipped as
			// extraObjects so it reconciles with this release. Previously
			// these lived as hand-applied manifests in
			// infrastructure/oauth-proxy/ that bootstrap never applied — on
			// a cluster recreate they were missing, so every Traefik router
			// referencing oauth-proxy-auth-with-redirect was disabled and
			// every gated host 404'd.
			let _lbl = {
				"app.kubernetes.io/managed-by": "k8-infra"
				"app.kubernetes.io/part-of":    "platform"
			}

			// Gated namespaces → host(s) + tls secret + the Ingress name to
			// keep (matches what shipped before, avoids churn). Drives the
			// per-host /oauth2/* routing bridges.
			let _oauthBridges = [
				{namespace: "goldilocks", ingressName: "goldilocks-oauth2", hosts: [{host: "goldilocks.example.internal", tls: "goldilocks-tls"}]},
				{namespace: "traefik", ingressName: "traefik-dashboard-oauth2", hosts: [{host: "traefik.example.internal", tls: "traefik-dashboard-tls"}]},
				{namespace: "hermes", ingressName: "hermes-dashboard-oauth2", hosts: [
					{host: "hermes-admin-dashboard.example.internal", tls: "hermes-admin-dashboard-tls"},
					{host: "hermes-dev2-dashboard.example.internal", tls: "hermes-dev2-dashboard-tls"},
					{host: "hermes-redteam-dashboard.example.internal", tls: "hermes-redteam-dashboard-tls"},
				]},
			]
			extraObjects: [
				// ForwardAuth → oauth2-proxy /oauth2/auth (401 if no session)
				{
					apiVersion: "traefik.io/v1alpha1"
					kind:       "Middleware"
					metadata: {name: "forward-auth-dex", namespace: "oauth-proxy", labels: _lbl}
					spec: forwardAuth: {
						address: "http://oauth2-proxy.oauth-proxy.svc.cluster.local/oauth2/auth"
						authResponseHeaders: [
							"X-Auth-Request-Access-Token",
							"X-Auth-Request-User",
							"X-Auth-Request-Email",
							"X-Auth-Request-Groups",
							"Authorization",
						]
						trustForwardHeader: true
					}
				},
				// errors{401} → oauth-redirect-page (meta-refresh /oauth2/start)
				{
					apiVersion: "traefik.io/v1alpha1"
					kind:       "Middleware"
					metadata: {name: "signin-redirect", namespace: "oauth-proxy", labels: _lbl}
					spec: errors: {
						status: ["401"]
						service: {name: "oauth-redirect-page", port: 80}
						query: "/"
					}
				},
				// Chain: signin-redirect wraps forward-auth-dex (order matters)
				{
					apiVersion: "traefik.io/v1alpha1"
					kind:       "Middleware"
					metadata: {name: "auth-with-redirect", namespace: "oauth-proxy", labels: _lbl}
					spec: chain: middlewares: [
						{name: "signin-redirect", namespace: "oauth-proxy"},
						{name: "forward-auth-dex", namespace: "oauth-proxy"},
					]
				},
				// redirect-page: meta-refresh HTML served on 401
				{
					apiVersion: "v1"
					kind:       "ConfigMap"
					metadata: {name: "oauth-redirect-page", namespace: "oauth-proxy", labels: _lbl}
					// The errors middleware swaps this body in while the browser
					// is still AT the originally-requested URL, so capture it
					// (window.location.href) and hand it to oauth2-proxy as rd.
					// Without rd, oauth2-proxy has no destination and the
					// post-login callback (on oauth.example.internal) strands
					// the user there instead of returning them to the gated
					// host. whitelist_domains=.example.internal permits the
					// cross-host redirect. Meta-refresh kept as a no-JS fallback.
					data: "index.html": """
						<!DOCTYPE html>
						<html><head>
						<meta charset="utf-8">
						<title>Sign in</title>
						<script>
						(function(){window.location.replace('/oauth2/start?rd='+encodeURIComponent(window.location.href));})();
						</script>
						<meta http-equiv="refresh" content="0;url=/oauth2/start">
						</head><body>
						<p>Redirecting to sign-in… If you are not redirected automatically,
						<a href="/oauth2/start">click here</a>.</p>
						</body></html>
						"""
				},
				{
					apiVersion: "apps/v1"
					kind:       "Deployment"
					metadata: {name: "oauth-redirect-page", namespace: "oauth-proxy", labels: _lbl}
					spec: {
						replicas: 1
						selector: matchLabels: app: "oauth-redirect-page"
						template: {
							metadata: labels: app: "oauth-redirect-page"
							spec: {
								securityContext: {
									runAsNonRoot: true
									runAsUser:    65534
									runAsGroup:   65534
									fsGroup:      65534
									seccompProfile: type: "RuntimeDefault"
								}
								containers: [{
									name:  "httpd"
									image: "busybox:1.36"
									command: ["/bin/sh", "-c"]
									args: ["cd /www\nexec httpd -f -v -p 8080 -h /www\n"]
									ports: [{name: "http", containerPort: 8080}]
									securityContext: {
										allowPrivilegeEscalation: false
										readOnlyRootFilesystem:   true
										capabilities: drop: ["ALL"]
									}
									resources: {
										requests: {cpu: "5m", memory: "8Mi"}
										limits: {cpu: "50m", memory: "32Mi"}
									}
									volumeMounts: [{name: "www", mountPath: "/www", readOnly: true}]
								}]
								volumes: [{
									name: "www"
									configMap: {
										name: "oauth-redirect-page"
										items: [{key: "index.html", path: "index.html"}]
									}
								}]
							}
						}
					}
				},
				{
					apiVersion: "v1"
					kind:       "Service"
					metadata: {name: "oauth-redirect-page", namespace: "oauth-proxy", labels: _lbl}
					spec: {
						type: "ClusterIP"
						selector: app: "oauth-redirect-page"
						ports: [{name: "http", port: 80, targetPort: "http", protocol: "TCP"}]
					}
				},
				// Per-host /oauth2 bridges — ExternalName Service per gated ns
				// (K8s Ingress backend must be same-ns; ExternalName bridges
				// to the cross-ns oauth2-proxy Service).
				for _b in _oauthBridges {
					apiVersion: "v1"
					kind:       "Service"
					metadata: {name: "oauth2-proxy-bridge", namespace: _b.namespace, labels: _lbl}
					spec: {
						type:         "ExternalName"
						externalName: "oauth2-proxy.oauth-proxy.svc.cluster.local"
						ports: [{name: "http", port: 80, protocol: "TCP"}]
					}
				},
				// Per-host /oauth2 bridges — Ingress routing /oauth2 on each
				// gated host to its bridge Service.
				for _b in _oauthBridges {
					apiVersion: "networking.k8s.io/v1"
					kind:       "Ingress"
					metadata: {
						name:      _b.ingressName
						namespace: _b.namespace
						labels:    _lbl
						annotations: "external-dns.alpha.kubernetes.io/target": "192.168.1.235"
					}
					spec: {
						ingressClassName: "traefik"
						rules: [for _h in _b.hosts {
							host: _h.host
							http: paths: [{
								path:     "/oauth2"
								pathType: "Prefix"
								backend: service: {name: "oauth2-proxy-bridge", port: number: 80}
							}]
						}]
						tls: [for _h in _b.hosts {hosts: [_h.host], secretName: _h.tls}]
					}
				},
			]
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// CloudNativePG operator — installs the Postgres operator + its CRDs
	// (`postgresql.cnpg.io`) so we can declare `Cluster` resources from
	// other charts. Previously installed via `infrastructure/cloudnative-pg/`
	// at bootstrap time; moved here so its lifecycle is Crossplane-managed
	// alongside the rest of the platform. Bootstrap should be invoked
	// with `INSTALL_CNPG=0` so the script skips phase_cnpg.
	//
	// Must reconcile BEFORE any release that creates `Cluster` CRs
	// (coder-postgres uses cnpg/cluster, which would fail validation if
	// the CRDs aren't installed yet).
	{
		name:      "cnpg"
		namespace: "cnpg-system"
		chart: {
			name:       "cloudnative-pg"
			repository: "https://cloudnative-pg.github.io/charts"
			version:    "0.28.3"
		}
		values: {
			crds: create:      true
			image: repository: "ghcr.io/cloudnative-pg/cloudnative-pg"
			resources: {
				requests: {cpu: "50m", memory: "128Mi"}
				limits: {cpu: "500m", memory: "256Mi"}
			}
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

]
