package preview

let C = cluster

helmReleases: [
	// MetalLB — LAN load-balancer for bare-metal/Talos. Allocates real
	// IPs from a pool reserved on the LAN (see infrastructure/metallb/pool.yaml)
	// to Services of type=LoadBalancer. Required for Traefik to be
	// reachable from LAN clients without NodePort / hostNetwork hacks.
	//
	// Reserve the IP pool out of UniFi DHCP first (default 192.168.3.240-250).
	{
		name:      "metallb"
		namespace: "metallb-system"
		chart: {
			name:       "metallb"
			repository: "https://metallb.github.io/metallb"
			version:    "0.15.3"
		}
		values: {
			controller: {
				resources: {
					requests: {cpu: "50m", memory: "64Mi"}
					limits: {cpu: "200m", memory: "128Mi"}
				}
			}
			speaker: {
				// Speaker DaemonSet binds host network to send ARP/NDP for
				// announced IPs. Must run on every node in the L2 segment.
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

	// Argo Events — Event bridge for webhook-driven CI/CD orchestration.
	// Receives GitHub webhooks and container registry events, correlates them,
	// and triggers downstream actions (Argo CD sync, agent spawning).
	{
		name:      "argo-events"
		namespace: "argo-events"
		chart: {
			name:       "argo-events"
			repository: "https://argoproj.github.io/argo-helm"
			version:    "2.4.8"
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

	// External Secrets Operator — distributes registry pull secrets and app
	// secrets into dynamically-created preview namespaces. Paired with a
	// ClusterSecretStore pointing to OpenBao.
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

	// Argo CD — GitOps engine managing preview Application lifecycle.
	// ApplicationSet controller generates one Application per open PR.
	// Notifications controller posts deployment status to GitHub.
	{
		name:      "argo-cd"
		namespace: "argocd"
		chart: {
			name:       "argo-cd"
			repository: "https://argoproj.github.io/argo-helm"
			version:    "7.7.16"
		}
		values: {
			crds: install: true
			server: {
				replicas: 1
				resources: {
					requests: {cpu: "100m", memory: "128Mi"}
					limits: {cpu: "500m", memory: "256Mi"}
				}
				// Expose argo-cd-argocd-server via the Omni workload service
				// proxy. Port 50080 is bound on every Talos node by the
				// omni-kube-service-exposer and forwarded to this Service.
				// Accessed from the Omni web UI left-nav ("Argo CD").
				service: annotations: {
					"omni-kube-service-exposer.sidero.dev/port":   "50080"
					"omni-kube-service-exposer.sidero.dev/label":  "Argo CD"
					"omni-kube-service-exposer.sidero.dev/prefix": "argocd"
				}
			}
			controller: {
				replicas: 1
				resources: {
					requests: {cpu: "250m", memory: "256Mi"}
					limits: {cpu: "1", memory: "512Mi"}
				}
			}
			applicationSet: {
				replicas: 1
				resources: {
					requests: {cpu: "100m", memory: "128Mi"}
					limits: {cpu: "500m", memory: "256Mi"}
				}
			}
			notifications: {
				enabled: true
				resources: {
					requests: {cpu: "50m", memory: "64Mi"}
					limits: {cpu: "200m", memory: "128Mi"}
				}

				// Notification services — GitHub for PR comments, Discord for
				// AI outage alerts. Placeholder values ($name) are resolved
				// against the argocd-notifications-secret, which ESO syncs
				// from OpenBao. See externalsecrets.cue.
				//
				// NOTE: The strings below use space-based YAML indentation
				// (not tabs) inside the multiline block. CUE strips leading
				// whitespace equal to the closing delimiter's indent, so the
				// YAML emitted to the ConfigMap is syntactically valid.
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
					// AI outage trigger — fires only for Applications that
					// carry preview.example.com/depends-on-ai=true and whose
					// health has degraded. Every preview Application subscribes
					// via an annotation set in argocd.cue, but this condition
					// gates who actually posts to Discord.
					"trigger.on-ai-outage": """
- description: Preview with AI dependency degraded
  send: [discord-ai-outage]
  when: app.status.health.status == 'Degraded' and app.metadata.annotations['preview.example.com/depends-on-ai'] == 'true'
"""
				}

				// Templates post a comment on the PR via the GitHub REST API,
				// or a message to Discord via its webhook.
				// Per-Application fields (repo, slug, PR number) come from
				// labels the ApplicationSet sets on each Application.
				templates: {
					"template.github-deployment-status": #"""
webhook:
  github:
    method: POST
    path: /repos/{{.app.spec.source.repoURL | call "trimPrefix" "https://github.com/" | call "trimSuffix" ".git"}}/issues/{{.app.metadata.labels.pr-number}}/comments
    body: |
      {"body": "Preview deployed: https://{{.app.metadata.labels.appslug}}-pr-{{.app.metadata.labels.pr-number}}.preview.example.com"}
"""#
					"template.github-pr-comment-degraded": #"""
webhook:
  github:
    method: POST
    path: /repos/{{.app.spec.source.repoURL | call "trimPrefix" "https://github.com/" | call "trimSuffix" ".git"}}/issues/{{.app.metadata.labels.pr-number}}/comments
    body: |
      {"body": "Preview health degraded for {{.app.metadata.labels.appslug}}-pr-{{.app.metadata.labels.pr-number}}.preview.example.com"}
"""#
					"template.discord-ai-outage": #"""
webhook:
  discord:
    method: POST
    body: |
      {"content": ":rotating_light: **AI outage detected** — `{{.app.metadata.name}}` is Degraded.\nApp: {{.app.metadata.labels.appslug}}  PR: #{{.app.metadata.labels.pr-number}}\nPreview: https://{{.app.metadata.labels.appslug}}-pr-{{.app.metadata.labels.pr-number}}.preview.example.com\nHealth: `{{.app.status.health.message}}`"}
"""#
				}
			}
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// Traefik Ingress Controller — routes traffic to preview namespaces
	// via wildcard host matching (pr-{n}.preview.example.com).
	// Traffic reaches Traefik via the cloudflared tunnel, which terminates
	// Cloudflare edge traffic and forwards to the Traefik service.
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
			// Main Service is LoadBalancer so MetalLB allocates a real LAN
			// IP. cloudflared still routes through it via Service IP for
			// the public *.preview.example.com path; LAN clients now hit
			// it directly via UniFi DNS + the LB IP for *.lan.example.com.
			// No Omni annotations here — the Omni proxy would forward to
			// port 80 and return 404 for any Host header that isn't a
			// configured IngressRoute.
			service: type: "LoadBalancer"

			// Enable the Traefik dashboard. `insecure: true` serves it on
			// the dedicated `traefik` entrypoint (port 8080) with no auth —
			// fine here because the only way to reach that port is via Omni,
			// which is itself authenticated. The dashboard is NOT exposed on
			// web/websecure, so cloudflared never routes to it.
			api: {
				dashboard: true
				insecure:  true
			}
			ingressRoute: dashboard: enabled: true
			ports: traefik: expose: default: true

			// Dedicated Service for the dashboard port. The main Traefik
			// Service mixes web/websecure/traefik ports, and the Omni proxy
			// forwards to a Service's first port — so we need an extra
			// Service that only selects the traefik entrypoint (8080).
			extraObjects: [{
				apiVersion: "v1"
				kind:       "Service"
				metadata: {
					name:      "traefik-dashboard"
					namespace: "traefik"
					annotations: {
						"omni-kube-service-exposer.sidero.dev/port":   "50083"
						"omni-kube-service-exposer.sidero.dev/label":  "Traefik"
						"omni-kube-service-exposer.sidero.dev/prefix": "traefik"
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
			}]
			ingressClass: {
				enabled:        true
				isDefaultClass: true
			}
			providers: kubernetesIngress: {
				allowExternalNameServices: false
				allowEmptyServices:        true
			}
			resources: {
				requests: {cpu: "100m", memory: "128Mi"}
				limits: {cpu: "500m", memory: "256Mi"}
			}
			// Trust Cloudflare's proxy headers so real client IPs are logged.
			ports: web: forwardedHeaders: trustedIPs: [
				"173.245.48.0/20",
				"103.21.244.0/22",
				"103.22.200.0/22",
				"103.31.4.0/22",
				"141.101.64.0/18",
				"108.162.192.0/18",
				"190.93.240.0/20",
				"188.114.96.0/20",
				"197.234.240.0/22",
				"198.41.128.0/17",
				"162.158.0.0/15",
				"104.16.0.0/13",
				"104.24.0.0/14",
				"172.64.0.0/13",
				"131.0.72.0/22",
			]
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// OpenBao — open-source fork of HashiCorp Vault, API-compatible.
	// Runs in standalone mode with file storage on a 10Gi PVC. Bootstrapped
	// by the openbao-bootstrap Job, which performs init, unseal, enables the
	// kubernetes auth method, and creates the ESO policy + role.
	//
	// The unseal keys and root token are stored in the `openbao-keys` Secret
	// in the openbao namespace. That Secret should be backed up out-of-band
	// (e.g., pulled into a separate sealed secret or offline vault) — losing
	// it means losing access to all secrets.
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
				// Readiness probe must accept sealed state (200,429,472,473,501,503)
				// otherwise the pod never becomes ready before bootstrap unseals it.
				readinessProbe: {
					enabled: true
					path:    "/v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204"
				}
			}
			ui: {
				enabled:         true
				serviceType:     "ClusterIP"
				externalPort:    8200
				// Expose the openbao-ui Service via the Omni workload service
				// proxy. Port 50081 is bound on every Talos node and forwarded
				// to the UI endpoint (8200/TCP). Root token login from the
				// Omni UI left-nav ("OpenBao").
				annotations: {
					"omni-kube-service-exposer.sidero.dev/port":   "50081"
					"omni-kube-service-exposer.sidero.dev/label":  "OpenBao"
					"omni-kube-service-exposer.sidero.dev/prefix": "openbao"
				}
			}
			injector: enabled: false
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// Cloudflare Tunnel Ingress Controller (STRRL).
	// Watches Ingress resources with class=cloudflare-tunnel and auto-creates
	// the Cloudflare tunnel + DNS records + per-Ingress routing. One connector
	// Deployment is managed by the controller itself; no dashboard clicks.
	//
	// Ingresses are defined as raw manifests under
	// infrastructure/cloudflared/ingresses.yaml — two at the edge
	// (*.preview.example.com + events.example.com, both → Traefik) and
	// one in argo-events for Traefik to route events.example.com paths to
	// the EventSource Services.
	{
		name:      "cloudflare-tunnel-ingress-controller"
		namespace: "cloudflared"
		chart: {
			name:       "cloudflare-tunnel-ingress-controller"
			repository: "https://helm.strrl.dev"
			version:    "0.0.15"
		}
		values: {
			replicaCount: 1
			cloudflare: {
				// Pulls account_id, tunnel_name, api_token from the Secret
				// created by ESO at cloudflared/cloudflare-external-secret.
				secretRef: {
					name:          "cloudflare-external-secret"
					accountIDKey:  "account_id"
					tunnelNameKey: "tunnel_name"
					apiTokenKey:   "api_token"
				}
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

]
