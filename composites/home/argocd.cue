package home

let C = cluster

// ──────────────────────────────────────────────────────────────────────
// Preview exposure model — internal LAN-only, subdomain-per-service.
//
// Each preview namespace gets a base host like:
//   salessage-pr-179.example.internal
// …and the chart MUST expose individual services as subdomains under it:
//   app.salessage-pr-179.example.internal        — main app
//   mailpit.salessage-pr-179.example.internal    — mailpit UI
//   supabase.salessage-pr-179.example.internal   — Supabase Kong
//   studio.salessage-pr-179.example.internal     — Supabase Studio
//   salessage-pr-179.example.internal            — index page
//
// Hosts live under `.example.internal`, which has NO public DNS at all
// — it exists only in UniFi's local DNS. Benefits over `.example.com`:
//   - No Cloudflare DNS records, no ACME DNS-01 over public DNS, no
//     UniFi-intercepts-its-own-zone NXDOMAIN gotcha.
//   - Names don't leak in PR descriptions / logs / status pages.
//   - TLS comes from the internal CA (openbao-example-internal
//     ClusterIssuer) — devs trust the CA once, all preview certs
//     are valid forever.
//
// All Ingresses use ingressClassName: traefik (LAN-only via MetalLB
// IP 192.168.2.240). External-dns-unifi auto-creates A records under
// .example.internal and removes them when Ingresses are deleted
// (--policy=sync).
//
// _previewHostnameTemplate is the BASE host the ApplicationSet passes
// to the chart as `hostBase`. The chart derives subdomains from it.
// ──────────────────────────────────────────────────────────────────────
_previewHostnameTemplate: "{{.slug}}-pr-{{.number}}.example.internal"

// ──────────────────────────────────────────────────────────────────────
// Repos served by the preview platform.
//
// Add an entry here to bring a new repo online. The matrix ApplicationSet
// below iterates this list × open PRs labelled `preview`, producing one
// Argo CD Application per (repo, PR) pair.
//
// Fields:
//   slug         — short name used in Application name, namespace, and URL.
//                  Must be DNS-safe (lowercase alphanumeric + hyphen) and
//                  globally unique across repos.
//   owner        — GitHub org/user (always "example-org" today).
//   name         — GitHub repo name.
//   dependsOnAI  — when true, Applications are subscribed to the
//                  on-ai-outage Discord trigger. See helmreleases.cue.
// ──────────────────────────────────────────────────────────────────────
_repos: [
	{
		slug:  "salessage"
		owner: "example-org"
		name:  "SalesSage"
		// false = no on-ai-outage Discord notifications. Was true; turned
		// off because the AI-outage trigger fires on any Degraded health
		// status (incl. transient app-config issues like a missing env var),
		// which is too noisy during preview bring-up. Re-enable once the
		// app is steady and Discord noise is signal-only.
		dependsOnAI: false
	},
]

// Argo CD AppProject — scoped project restricting what preview Applications can do.
argoAppProjects: [
	{
		name:      "previews"
		namespace: "argocd"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			description: "PR preview environments — restricted scope"
			destinations: [{
				namespace: "preview-*"
				server:    "https://kubernetes.default.svc"
			}]
			sourceRepos: [
				// Placeholder chart; swap to in-repo chart paths when each
				// repo adopts deploy/preview/Chart.yaml.
				"https://charts.softonic.io",
				"https://traefik.github.io/charts",
				"https://openbao.github.io/openbao-helm",
				"https://charts.pascaliske.dev",
				// Allow git sources for all example-org repos.
				"https://github.com/example-org/*",
			]
			// Namespaces are the only cluster-scoped resource preview apps may
			// touch — ArgoCD's `CreateNamespace=true` syncOption needs this
			// to create `preview-{slug}-{number}` on first sync. Cluster
			// roles, CRDs, etc. remain forbidden by the empty default.
			clusterResourceWhitelist: [
				{group: "", kind: "Namespace"},
			]
			namespaceResourceBlacklist: [
				{group: "", kind: "ResourceQuota"},
				{group: "networking.k8s.io", kind: "NetworkPolicy"},
				// Namespace-scoped Role + RoleBinding ARE allowed (preview
				// chart subcharts like Supabase need them for in-namespace
				// SA permissions, and the jwt-init Job needs to create
				// Secrets in its own ns). Cluster-scoped ClusterRole +
				// ClusterRoleBinding remain blocked via clusterResourceWhitelist
				// above (only Namespace is whitelisted cluster-side).
			]
		}
	},

	// AppProject for long-lived single-image apps (bb-docs etc.) that wrap
	// a private GHCR container in the bjw-s app-template chart.
	{
		name:      "bb-apps"
		namespace: "argocd"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			description: "Example Org long-lived apps — single-container deploys via app-template"
			destinations: [{
				namespace: "bb-*"
				server:    "https://kubernetes.default.svc"
			}]
			sourceRepos: [
				"https://bjw-s-labs.github.io/helm-charts",
			]
			// Namespace is required so syncOptions: CreateNamespace=true works.
			// Argo CD treats the Namespace as a cluster-scoped resource gated by
			// this whitelist even when the chart itself doesn't render one.
			clusterResourceWhitelist: [
				{group: "", kind: "Namespace"},
			]
			// Wildcards instead of an explicit kind list. Argo CD's resource
			// tree walker filters child resources (ReplicaSet, Pod) against
			// this whitelist before adding them to the tree; an explicit list
			// that omits Pod/ReplicaSet leaves the tree shallow → empty
			// .status.summary.images → argocd-image-updater logs "image not
			// live, skipping". Wildcards keep the project scoped to
			// destinations bb-* (above) without hand-listing every resource
			// kind a Pod-owning controller can spawn.
			namespaceResourceWhitelist: [
				{group: "", kind: "*"},
				{group: "apps", kind: "*"},
				{group: "networking.k8s.io", kind: "*"},
				{group: "autoscaling", kind: "*"},
				{group: "policy", kind: "*"},
			]
		}
	},

	// AppProject for Example Org platform apps — charts shipped from
	// our own OCI helm registry (ghcr.io/example-org/charts/*). Used for
	// the Jarvy telemetry forwarder today; reusable for any future
	// example-org helm-chart-shipped service.
	{
		name:      "bb-platform"
		namespace: "argocd"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			description: "Example Org platform charts shipped from ghcr.io/example-org/charts and vendored charts in github.com/example-org/k8-infra"
			destinations: [
				{
					namespace: "jarvy-telemetry"
					server:    "https://kubernetes.default.svc"
				},
				// Hermes Agent — vendored chart in infrastructure/hermes-agent/chart/
				{
					namespace: "hermes"
					server:    "https://kubernetes.default.svc"
				},
				// Honcho — raw manifests in infrastructure/honcho/
				{
					namespace: "honcho"
					server:    "https://kubernetes.default.svc"
				},
				// Velero schedules — raw manifests in infrastructure/velero/
				{
					namespace: "velero"
					server:    "https://kubernetes.default.svc"
				},
			]
			// OCI helm registry for cross-repo charts + this repo's git URL
			// for vendored charts (Argo CD reads them directly from the
			// configured path on each reconcile).
			sourceRepos: [
				"ghcr.io/example-org/charts",
				"ghcr.io/example-org/charts/*",
				"https://github.com/example-org/k8-infra.git",
				"https://github.com/example-org/k8-infra",
			]
			clusterResourceWhitelist: [
				{group: "", kind: "Namespace"},
				// Vendored charts that ship CRDs (e.g. hermes-agent ships
				// hermestenants.hermes.ai) need this. The CRD is dormant
				// unless the chart's operator is enabled.
				{group: "apiextensions.k8s.io", kind: "CustomResourceDefinition"},
			]
			namespaceResourceWhitelist: [
				{group: "", kind: "*"},
				{group: "apps", kind: "*"},
				{group: "networking.k8s.io", kind: "*"},
				{group: "autoscaling", kind: "*"},
				{group: "policy", kind: "*"},
				{group: "external-secrets.io", kind: "*"},
				{group: "monitoring.coreos.com", kind: "*"},
				// Traefik Middlewares / IngressRoutes etc. (used by
				// hermes-agent for the `/` → `/health` redirect).
				{group: "traefik.io", kind: "*"},
			]
		}
	},
]

// ApplicationSet — matrix(list of repos × pullRequest per repo).
// One Application per (repo, open PR with label=preview).
//
// Naming:
//   Application  →  {slug}-pr-{number}
//   Namespace    →  preview-{slug}-pr-{number}
//   URL          →  {slug}-pr-{number}.preview.example.com
//
// All preview hosts sit under the existing *.preview.example.com wildcard
// on the Cloudflare tunnel — no per-app DNS changes needed when you add
// a repo to _repos.
// Long-lived single-container apps. One Argo Application per entry,
// wrapping the bjw-s app-template chart so we don't have to maintain
// a chart per app. Argo CD reconciles continuously (selfHeal + prune).
//
// Add an entry to ship a new app:
//   slug         — DNS-safe short name. Drives Application name, namespace
//                  (bb-{slug}), Ingress host (bb-{slug}.example.internal),
//                  and Homepage tile.
//   image        — full GHCR repository (no tag).
//   tag          — image tag. Bump in this file to roll the app.
//   port         — container port the app listens on.
//   homepageName — display name on home.example.internal dashboard.
//   icon         — dashboard-icons filename (e.g. bookstack.png).
//   description  — Homepage tile description.
_bbApps: [
	{
		slug:         "docs"
		image:        "ghcr.io/example-org/knowledge-base"
		tag:          "latest"
		port:         8080
		homepageName: "BB Docs"
		icon:         "bookstack.png"
		description:  "Example Org knowledge base"
	},
]

argoApplicationSets: [
	// One ApplicationSet per bb-app. Single-element list generator + all
	// values resolved at CUE time — no fasttemplate substitution needed.
	// ApplicationSet exists only because the repo has no XArgoApplication
	// XRD; using this XRD avoids adding one. Argo CD reconciles the
	// generated Application continuously.
	for _app in _bbApps {
		let _ns = "bb-\(_app.slug)"
		let _host = "\(_ns).example.internal"

		name:      _ns
		namespace: "argocd"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			generators: [{list: elements: [{}]}]
			// Don't revert image-updater's helm parameter overrides on every
			// reconcile. Image-updater patches spec.source.helm.parameters
			// when a tracked image's digest changes (write-back-method=argocd);
			// without this ignore, the ApplicationSet controller would race
			// with image-updater and overwrite the digest pin every cycle.
			ignoreApplicationDifferences: [{
				jsonPointers: ["/spec/source/helm/parameters"]
			}]
			template: {
				metadata: {
					name: _ns
					labels: {
						"app.kubernetes.io/part-of": "bb-apps"
						appslug:                     _app.slug
					}
					annotations: {
						// ServerSideDiff was needed under Argo CD v2.13 to
						// work around an OpenAPI schema gap on
						// Deployment.status.terminatingReplicas. v3.x ships
						// a current schema and the issue is gone, but the
						// hint stays cheap and keeps diffs apiserver-side.
						"argocd.argoproj.io/compare-options": "ServerSideDiff=true"
					}
					finalizers: ["resources-finalizer.argoproj.io"]
				}
				spec: {
					project: "bb-apps"
					source: {
						repoURL:        "https://bjw-s-labs.github.io/helm-charts"
						chart:          "app-template"
						targetRevision: "3.7.3"
						helm: valuesObject: {
							controllers: main: containers: main: {
								image: {
									repository: _app.image
									tag:        _app.tag
								}
								// Container exposes _app.port; chart wires it
								// to the Service via service.main.ports.http.
								// Probes off until we know the app's healthcheck.
								probes: {
									liveness: enabled:  false
									readiness: enabled: false
									startup: enabled:   false
								}
							}
							service: main: {
								controller: "main"
								ports: http: port: _app.port
							}
							ingress: main: {
								enabled:   true
								className: "traefik"
								annotations: {
									"cert-manager.io/cluster-issuer":          "openbao-example-internal"
									"external-dns.alpha.kubernetes.io/target": "192.168.1.235"
									"gethomepage.dev/enabled":                 "true"
									"gethomepage.dev/name":                    _app.homepageName
									"gethomepage.dev/group":                   "Platform"
									"gethomepage.dev/icon":                    _app.icon
									"gethomepage.dev/description":             _app.description
									"gethomepage.dev/href":                    "https://\(_host)"
									"gethomepage.dev/siteMonitor":             "https://\(_host)"
								}
								hosts: [{
									host: _host
									paths: [{
										path:     "/"
										pathType: "Prefix"
										service: {
											identifier: "main"
											port:       "http"
										}
									}]
								}]
								tls: [{
									secretName: "\(_ns)-tls"
									hosts: [_host]
								}]
							}
							defaultPodOptions: imagePullSecrets: [{
								name: "ghcr-pull-secret"
							}]
						}
					}
					destination: {
						// In Argo CD v3, only the `name: in-cluster` form
						// causes the controller to associate the destination
						// with its cluster cache and walk child resources
						// (ReplicaSet, Pod) into the resource tree. The
						// `server: https://kubernetes.default.svc` form leaves
						// the tree shallow → empty .status.summary.images →
						// argocd-image-updater logs "image not live, skipping".
						name:      "in-cluster"
						namespace: _ns
					}
					syncPolicy: {
						managedNamespaceMetadata: labels: {
							"app.kubernetes.io/part-of": "bb-apps"
							appslug:                     _app.slug
							"infra.k8/tier":             "dev"
							"infra.k8/cluster":          "home"
						}
						automated: {
							prune:    true
							selfHeal: true
						}
						syncOptions: [
							"CreateNamespace=true",
							"ServerSideApply=true",
						]
						retry: {
							limit: 5
							backoff: {
								duration:    "30s"
								factor:      2
								maxDuration: "5m"
							}
						}
					}
				}
			}
		}
	},
	{
		name:      "preview-envs"
		namespace: "argocd"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			goTemplate: true
			generators: [{
				matrix: {
					generators: [
						{list: elements: [
							for repo in _repos {
								slug:        repo.slug
								owner:       repo.owner
								name:        repo.name
								dependsOnAI: "\(repo.dependsOnAI)"
							},
						]},
						{pullRequest: {
							github: {
								owner:         "{{.owner}}"
								repo:          "{{.name}}"
								appSecretName: "github-app-creds-argocd"
								labels: ["preview"]
							}
							requeueAfterSeconds: 30
						}},
					]
				}
			}]
			template: {
				metadata: {
					// Name is stable on (slug, PR number). Branch renames or
					// force-pushes must not recreate the Application — that
					// would prune and recreate the namespace (data loss).
					name: "{{.slug}}-{{.number}}"
					labels: {
						preview:     "true"
						"pr-number": "{{.number}}"
						appslug:     "{{.slug}}"
					}
					annotations: {
						"notifications.argoproj.io/subscribe.on-deployed.github":        ""
						"notifications.argoproj.io/subscribe.on-health-degraded.github": ""
						// Subscribe every preview to on-ai-outage; the trigger
						// itself checks depends-on-ai before firing, so only
						// AI-dependent repos actually post to Discord.
						"notifications.argoproj.io/subscribe.on-ai-outage.discord": ""
						// Consumed by on-ai-outage trigger condition.
						"preview.example.com/depends-on-ai": "{{.dependsOnAI}}"
					}
					// Foreground finalizer ensures resources inside the namespace
					// are deleted before the namespace itself is pruned, avoiding
					// orphaned PVCs / finalizer races.
					finalizers: ["resources-finalizer.argoproj.io"]
				}
				spec: {
					project: "previews"
					// Info fields render as clickable links in the Argo CD UI.
					info: [{
						name:  "PR URL"
						value: "https://github.com/{{.owner}}/{{.name}}/pull/{{.number}}"
					}, {
						name:  "Preview index (LAN)"
						value: "https://\(_previewHostnameTemplate)"
					}, {
						name:  "App (LAN)"
						value: "https://app.\(_previewHostnameTemplate)"
					}, {
						name:  "Mailpit (LAN)"
						value: "https://mailpit.\(_previewHostnameTemplate)"
					}, {
						name:  "Supabase (LAN)"
						value: "https://supabase.\(_previewHostnameTemplate)"
					}]
					source: {
						repoURL:        "https://github.com/{{.owner}}/{{.name}}.git"
						targetRevision: "{{.head_sha}}"
						path:           "chart"
						helm: valuesObject: {
							image: {
								// .slug is already lowercase (matches the GHCR image name
								// pushed by preview-build.yaml). Don't use `.name | toLower`
								// — ArgoCD's go-template doesn't have Sprig wired up here.
								repository: "ghcr.io/{{.owner}}/{{.slug}}"
								// tag is intentionally NOT set — the chart's
								// salessage.imageTag helper falls through to
								// `pr-<prNumber>`, the floating tag preview-build.yaml
								// re-points on every successful build. Per-commit
								// `sha-<headSha>` tags broke previews whenever the GHA
								// Preview Build got cancelled by a follow-up push within
								// ~1m (common when fixing a typo): chart referenced an
								// image that was never built. Floating pr-N stays at the
								// last good image; cancelled builds are a no-op.
								//
								// commitSha drives the pod-template annotation
								// `salessage.example-org/commit-sha` so rolling restarts
								// still fire on every commit despite the tag string
								// staying stable. Cancelled builds → annotation bumps →
								// rolling restart pulls the same pre-existing pr-N image
								// (kubelet finds it cached, no ImagePullBackOff). App
								// stays Running through the failure, Argo stays Healthy.
								commitSha: "{{.head_sha}}"
							}
							// Read by salessage.imageTag helper to construct `pr-<N>`.
							prNumber: "{{.number}}"
							// Multi-subdomain LAN-only exposure. The chart owns the
							// per-service Ingress definitions and derives subdomains
							// from `hostBase`:
							//   app.<hostBase>      — main app
							//   mailpit.<hostBase>  — mailpit UI
							//   supabase.<hostBase> — Supabase Kong
							//   studio.<hostBase>   — Supabase Studio (if enabled)
							//   <hostBase>          — index page linking to all of the above
							//
							// Charts MUST use ingressClassName=traefik so external-dns-unifi
							// creates A records pointing at traefik's LoadBalancer IP
							// (192.168.2.240) — LAN-only. external-dns-unifi runs with
							// --policy=sync so DNS records are auto-removed on Ingress
							// deletion (i.e. when the PR closes and the App prunes).
							hostBase: _previewHostnameTemplate
							ingress: {
								enabled:   true
								className: "traefik"
							}
							fullnameOverride: "{{.slug}}-{{.number}}"

							// Supabase subchart values that need the resolved preview
							// hostname computed at deploy time. The subchart doesn't
							// re-template values it receives, so Helm-side
							// `{{ .Values.hostBase }}` stays literal — we inject the
							// resolved values here.
							//
							// PATH NOTE: the subchart iterates `.Values.environment.auth`
							// (see chart/charts/supabase/templates/auth/deployment.yaml),
							// NOT `.Values.auth.environment`. The inverted-path mistake
							// silently no-ops — Helm renders the value but the auth
							// deployment template never reads it.
							//
							// PREFIX NOTE: GoTrue reads config via Viper-style env lookup,
							// which checks both `GOTRUE_FOO` and bare `FOO` for the same
							// key. The subchart's values.yaml defines BOTH for some keys
							// (API_EXTERNAL_URL unprefixed at line 551, GOTRUE_SITE_URL
							// prefixed at line 554), and GoTrue's URL-construction path
							// uses the **unprefixed** API_EXTERNAL_URL when building
							// verify links in emails. Overriding only the GOTRUE_-prefixed
							// form leaves the prefixed env right but the bare env at the
							// http://supabase.local default → invite emails ship verify
							// links to the wrong host. Override BOTH to be safe.
							//
							//   *_SITE_URL          → app URL: where verify links land
							//                         after the user clicks them. Also the
							//                         default redirect_to when the app
							//                         doesn't pass one.
							//   *_API_EXTERNAL_URL  → app URL: where verify links
							//                         themselves point. The app proxies
							//                         /auth/v1/* through to Kong→GoTrue,
							//                         so emailed links stay on a single
							//                         human-recognisable host.
							//
							// GOTRUE_SMTP_HOST is NOT overridden here — the chart's
							// values.yaml already points it at the per-namespace
							// `mailpit-smtp` Service alias, which works across all
							// preview envs without per-PR substitution.
							supabase: {
								environment: {
									auth: {
										SITE_URL:                "https://app.\(_previewHostnameTemplate)"
										GOTRUE_SITE_URL:         "https://app.\(_previewHostnameTemplate)"
										API_EXTERNAL_URL:        "https://app.\(_previewHostnameTemplate)"
										GOTRUE_API_EXTERNAL_URL: "https://app.\(_previewHostnameTemplate)"
									}
								}
							}
						}
					}
					destination: {
						server:    "https://kubernetes.default.svc"
						namespace: "preview-{{.slug}}-{{.number}}"
					}
					syncPolicy: {
						// Labels applied to the auto-created namespace.
						// ClusterExternalSecrets match on `preview: "true"` to
						// fan shared secrets + GHCR pull credentials into the ns.
						managedNamespaceMetadata: labels: {
							preview:            "true"
							"pr-number":        "{{.number}}"
							appslug:            "{{.slug}}"
							"infra.k8/tier":    "dev"
							"infra.k8/cluster": "preview"
						}
						automated: {
							prune:    true
							selfHeal: true
						}
						syncOptions: [
							"CreateNamespace=true",
							"PruneLast=true",
							"ServerSideApply=true",
						]
						retry: {
							limit: 5
							backoff: {
								duration:    "30s"
								factor:      2
								maxDuration: "5m"
							}
						}
					}
				}
			}
		}
	},

	// Jarvy telemetry forwarder — chart from example-org's OCI helm
	// registry. Single Application (single-element list generator,
	// no PR fan-out). Bump targetRevision below to upgrade the
	// chart; Argo CD reconciles continuously (selfHeal + prune).
	//
	// Public OTLP endpoint at https://jarvyotel.example.com is
	// served by a separate Ingress (cloudflare-tunnel class) in
	// ingresses.cue — Gateway API support is disabled on the chart
	// since the home cluster has no GatewayClass installed and
	// STRRL is the established CF tunnel pattern.
	{
		name:      "jarvy-telemetry"
		namespace: "argocd"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			generators: [{list: elements: [{}]}]
			template: {
				metadata: {
					name: "jarvy-telemetry"
					labels: {
						"app.kubernetes.io/part-of": "bb-platform"
					}
					finalizers: ["resources-finalizer.argoproj.io"]
				}
				spec: {
					project: "bb-platform"
					source: {
						// Argo CD 2.5+ treats this as an OCI helm
						// registry when `chart` is set.
						repoURL:        "ghcr.io/example-org/charts"
						chart:          "jarvy-telemetry-forwarder"
						targetRevision: "0.6.0"
						helm: valuesObject: {
							// Disable chart's Gateway API resources; we expose
							// via the Cloudflare Tunnel Ingress controller
							// (Ingress lives in composites/home/ingresses.cue).
							gatewayApi: enabled: false
							// Cert-manager TLS is unnecessary — CF terminates
							// public TLS at the tunnel edge and cluster-internal
							// traffic from cloudflared → Service is HTTP.
							tls: certManager: enabled: false

							// Secrets: chart's `existing` strategy — the two
							// referenced Secrets (`grafana-otlp-token`,
							// `pii-salt`) are created by ExternalSecrets
							// authored in composites/home/externalsecrets.cue.
							// The grafana token is assembled from separate
							// instance_id + apikey fields via ESO templating;
							// Grafana Cloud OTLP needs `Basic base64(instance_id:apikey)`
							// and the chart's bearertokenauth extension just
							// prepends `Basic ` to whatever it's given.
							secrets: strategy: "existing"

							// NetworkPolicy: chart's built-in NP allows
							// ingress from the named namespace. Point at
							// cloudflared (STRRL controller ns) so the
							// tunnel pod can reach the Service.
							networkPolicy: {
								enabled:             true
								ingressNamespace:    "cloudflared"
								monitoringNamespace: "monitoring"
							}

							// Home cluster has no Prometheus operator
							// (no monitoring.coreos.com CRDs). Disable
							// the chart's ServiceMonitor + PrometheusRule
							// resources — re-enable when we install a
							// monitoring stack.
							serviceMonitor: enabled: false
							prometheusRule: enabled: false

							// Memory bump: absorb a ~5-min Grafana Cloud
							// backend stall without dropping. Keep 2
							// replicas — cluster has 4 workers, so HA
							// across nodes is real (single-pod crash,
							// node drain, rolling Talos patch). Chart's
							// `maxSurge: 1, maxUnavailable: 0` plus PDB
							// `maxUnavailable: 1` keeps upgrades and
							// drains zero-drop. memoryLimiter.limitMib
							// stays ≤ ~65% of container limit (chart
							// guidance) so graceful backpressure trips
							// before the cgroup OOMKills the pod.
							collector: {
								resources: {
									requests: {
										cpu:    "100m"
										memory: "512Mi"
									}
									limits: memory: "1536Mi"
								}
								pipeline: memoryLimiter: {
									limitMib:      1000
									spikeLimitMib: 250
								}
							}
						}
					}
					destination: {
						name:      "in-cluster"
						namespace: "jarvy-telemetry"
					}
					syncPolicy: {
						managedNamespaceMetadata: labels: {
							"app.kubernetes.io/part-of": "bb-platform"
							"infra.k8/tier":             "dev"
							"infra.k8/cluster":          "home"
						}
						automated: {
							prune:    true
							selfHeal: true
						}
						syncOptions: [
							"CreateNamespace=true",
							"ServerSideApply=true",
						]
						retry: {
							limit: 5
							backoff: {
								duration:    "30s"
								factor:      2
								maxDuration: "5m"
							}
						}
					}
				}
			}
		}
	},

	// Hermes Agent — Admin's profile. The dashboard can't be shared across
	// profiles (Hermes requires the dashboard and gateway to share a PID
	// namespace per the upstream docs), so each user gets their own pod
	// with its own dashboard URL. Homepage groups them as one section.
	//
	// Release name stays "hermes" (no -admin suffix) — this is the original
	// deploy and renaming would destroy + recreate the PVC, losing
	// HERMES_HOME state. Profile flavor lives in URL hostnames +
	// Homepage labels (see composites/home/ingresses.cue).
	{
		name:      "hermes"
		namespace: "argocd"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			generators: [{list: elements: [{}]}]
			template: {
				metadata: {
					name: "hermes"
					labels: {
						"app.kubernetes.io/part-of":       "bb-platform"
						"hermes.example.internal/profile": "admin"
					}
					finalizers: ["resources-finalizer.argoproj.io"]
				}
				spec: {
					project: "bb-platform"
					source: {
						// Vendored chart in this repo. ArgoCD reads it
						// directly from the path on every reconcile — no
						// OCI push step. Refresh the chart by re-cloning
						// into infrastructure/hermes-agent/chart/ and
						// committing; ArgoCD picks up the new version on
						// next sync.
						repoURL:        "https://github.com/example-org/k8-infra.git"
						targetRevision: "main"
						path:           "infrastructure/hermes-agent/chart"
						helm: valuesObject: {
							// Auto-restart on Secret/ConfigMap content change.
							// Pairs with the hermes-secrets ExternalSecret using
							// dataFrom — drop a new key into OpenBao, ESO syncs
							// the Secret within refreshInterval (1m), Reloader
							// detects the hash change, rolls the Deployment,
							// the new env var lands in the pod.
							deploymentAnnotations: {
								"reloader.stakater.com/auto": "true"
							}

							// Bypass the image's s6-overlay entrypoint. s6
							// preinit wants a writable /run owned by its
							// runtime uid, but the pod runs runAsUser=1000 +
							// readOnlyRootFilesystem, so /run (root-owned, RO)
							// makes s6 fatal with exit 100 — the gateway
							// container never boots. Call the hermes binary
							// directly (same as the dashboard sidecar below,
							// which has worked since launch). args stay the
							// chart default [gateway, run].
							command: ["/opt/hermes/.venv/bin/hermes"]

							// Chart default tag `0.8.0` is not published to
							// Docker Hub. The repo only publishes a `main`
							// floating tag + sha-pinned builds. Track `main`
							// for now; pin to a sha for reproducibility once
							// the upstream is stable.
							image: {
								repository: "nousresearch/hermes-agent"
								tag:        "v2026.5.29.2"
								pullPolicy: "IfNotPresent"
							}

							// Hermes state must persist. Chart enforces
							// replicaCount=1 + strategy=Recreate when this
							// is on; do not change either.
							persistence: {
								enabled:      true
								size:         "10Gi"
								storageClass: "longhorn"
								mountPath:    "/opt/data"
							}

							resources: {
								requests: {cpu: "250m", memory: "1Gi"}
								limits: {cpu: "2", memory: "4Gi"}
							}

							// Provider config. Defaults to Vercel AI Gateway
							// fronting Anthropic. The chart writes this
							// into HERMES_HOME/config.yaml at bootstrap.
							config: values: {
								model: {
									default:  "anthropic/claude-opus-4.6"
									provider: "auto"
									// Vercel AI Gateway endpoint.
									base_url: "https://ai-gateway.vercel.sh/v1"
								}
								agent: {
									max_turns:             90
									gateway_timeout:       1800
									restart_drain_timeout: 60
									tool_use_enforcement:  "auto"
								}
								// Memory provider — self-hosted Honcho at
								// honcho.honcho.svc.cluster.local:8000. The
								// honcho-ai Python SDK is installed at pod
								// start by the install-honcho-plugin
								// initContainer (extraInitContainers below).
								memory: {
									memory_enabled: true
									provider:       "honcho"
								}
								// MCP servers — Hermes' Model Context Protocol clients.
								// Each entry registers an upstream MCP server the agent
								// can call. Tokens are referenced via ${VAR} placeholders
								// that Hermes expands from process env at config load.
								// Process env is populated by ESO → hermes-secrets →
								// envFrom; so to add/rotate a token:
								//
								//   bao kv patch secret/users/admin/hermes VAPI_TOKEN=<value>
								//
								// ESO syncs within 1m, Reloader restarts the pod, the
								// new token is picked up by ${VAPI_TOKEN} at startup.
								mcp_servers: "vapi-mcp": {
									url: "https://mcp.vapi.ai/mcp"
									headers: Authorization: "Bearer ${VAPI_TOKEN}"
								}
							}

							// Tell Hermes to find the honcho-ai package at the
							// emptyDir mount (populated by install-honcho-plugin
							// initContainer below).
							extraEnv: [
								{name: "PYTHONPATH", value: "/honcho-pkg"},
							]

							// Mount the honcho-ai package emptyDir into the
							// main gateway container.
							extraVolumeMounts: [
								{name: "honcho-pkg", mountPath: "/honcho-pkg"},
							]

							// One-shot initContainer: pip-installs honcho-ai
							// into a shared emptyDir, then seeds honcho.json
							// on the PVC with enabled=true if absent.
							extraInitContainers: [
								{
									name:            "install-honcho-plugin"
									image:           "python:3.13-slim"
									imagePullPolicy: "IfNotPresent"
									command: ["sh", "-c"]
									args: ["""
										set -e
										echo '> Installing honcho-ai into /honcho-pkg...'
										pip install --no-cache-dir --target /honcho-pkg honcho-ai 2>&1 | tail -3
										if [ ! -f /opt/data/honcho.json ]; then
										  echo '> Seeding honcho.json (enabled=true, aiPeer=admin)...'
										  cat > /opt/data/honcho.json <<JSON
										{"hosts":{"hermes":{"enabled":true,"workspace":"hermes","aiPeer":"admin","recallMode":"hybrid","writeFrequency":"async"}}}
										JSON
										else
										  echo '> honcho.json already exists; leaving as-is.'
										fi
										""",
									]
									volumeMounts: [
										{name: "honcho-pkg", mountPath: "/honcho-pkg"},
										{name: "data", mountPath: "/opt/data"},
									]
									resources: {
										requests: {cpu: "100m", memory: "128Mi"}
										limits: {cpu: "500m", memory: "256Mi"}
									}
									securityContext: {
										allowPrivilegeEscalation: false
										runAsNonRoot:             true
										runAsUser:                10000
										capabilities: drop: ["ALL"]
										seccompProfile: type: "RuntimeDefault"
									}
								},
							]

							// Secrets via the pre-created hermes-secrets
							// Secret in this namespace (synced by ESO from
							// secret/home/hermes in OpenBao).
							secrets: existingSecret: "hermes-secrets"

							// API server enabled so Hermes can be reached
							// over HTTP (port 8642). Service + Ingress
							// take it from there.
							apiServer: {
								enabled:   true
								host:      "0.0.0.0"
								port:      8642
								modelName: "hermes-agent"
							}

							service: {
								enabled: true
								type:    "ClusterIP"
								// Explicit because we run two listeners
								// (apiServer in main container, dashboard
								// in sidecar). Chart's auto-port logic only
								// covers main-container listeners.
								ports: [
									{
										name:          "api-server"
										port:          8642
										targetPort:    8642
										containerPort: 8642
										protocol:      "TCP"
									},
									{
										name:          "dashboard"
										port:          9119
										targetPort:    9119
										containerPort: 9119
										protocol:      "TCP"
									},
								]
							}

							// Web dashboard sidecar — runs `hermes dashboard
							// --tui` on port 9119 in the same pod, sharing
							// HERMES_HOME (/opt/data PVC) + ConfigMap with
							// the gateway. Exposed at
							// hermes-dashboard.example.internal behind
							// oauth2-proxy → Dex Google login (Ingress in
							// ingresses.cue). --insecure binds 0.0.0.0
							// because we restrict access at the LAN+OAuth
							// layer instead.
							extraContainers: [
								{
									name:            "dashboard"
									image:           "nousresearch/hermes-agent:v2026.5.29.2"
									imagePullPolicy: "IfNotPresent"
									workingDir:      "/opt/hermes"
									command: ["/opt/hermes/.venv/bin/hermes"]
									args: [
										"dashboard",
										"--host", "0.0.0.0",
										"--port", "9119",
										"--insecure",
										"--no-open",
										"--skip-build",
										"--tui",
									]
									envFrom: [{
										secretRef: name: "hermes-secrets"
									}]
									env: [
										{name: "HERMES_HOME", value: "/opt/data"},
										{name: "HOME", value: "/opt/data"},
										{name: "HERMES_DASHBOARD_TUI", value: "1"},
										// honcho-ai SDK lives in /honcho-pkg
										// (mounted from emptyDir, populated by
										// the install-honcho-plugin initContainer).
										{name: "PYTHONPATH", value: "/honcho-pkg"},
									]
									ports: [{
										name:          "dashboard"
										containerPort: 9119
										protocol:      "TCP"
									}]
									// Bumped from 128Mi/512Mi after OOMKills
									// (exit 137) when the user typed in the
									// TUI tab. The dashboard process spawns
									// `hermes --tui` as a subprocess on first
									// keypress; that subprocess alone needs
									// ~300Mi for Python + Hermes imports, so
									// the parent + child easily blow 512Mi.
									resources: {
										requests: {cpu: "100m", memory: "512Mi"}
										limits: {cpu: "1", memory: "2Gi"}
									}
									securityContext: {
										allowPrivilegeEscalation: false
										readOnlyRootFilesystem:   true
										capabilities: drop: ["ALL"]
										seccompProfile: type: "RuntimeDefault"
									}
									volumeMounts: [
										{name: "data", mountPath: "/opt/data"},
										{name: "tmp", mountPath: "/tmp"},
										// esbuild writes /opt/hermes/ui-tui/dist/entry.js
										// at dashboard startup. The chart enforces a
										// readOnlyRootFilesystem on every container,
										// so the build fails and the Chat tab shows
										// "Chat unavailable: 1". Mount a tmpfs over
										// the dist dir so esbuild can write.
										{name: "tui-dist", mountPath: "/opt/hermes/ui-tui/dist"},
										// Honcho-ai python package (shared with
										// the main gateway container via emptyDir).
										{name: "honcho-pkg", mountPath: "/honcho-pkg"},
									]
								},
							]

							// Ingress is in composites/home/ingresses.cue
							// (LAN-only via Traefik internal with OpenBao
							// PKI cert). Disable the chart's built-in.
							ingress: enabled: false

							// VirtualService is for Istio meshes; we don't
							// run one.
							virtualService: enabled: false

							// Single-namespace deployment; no operator/CRD
							// dance needed.
							operator: enabled: false

							// Bootstrap rewrites config.yaml on every helm
							// upgrade so chart values stay authoritative.
							bootstrap: {
								enabled:   true
								overwrite: true
							}

							// EmptyDirs: tui-dist for the dashboard's esbuild
							// output; honcho-pkg for the pip-installed honcho-ai
							// SDK shared between init + main + dashboard
							// containers.
							extraVolumes: [
								{
									name: "tui-dist"
									emptyDir: {
										sizeLimit: "64Mi"
									}
								},
								{
									name: "honcho-pkg"
									emptyDir: {
										sizeLimit: "200Mi"
									}
								},
							]

							// Traefik Middleware redirecting `/` to `/health`.
							// Hermes returns 404 at `/` (no root route), so
							// the homepage tile + casual clicks land on a 200
							// instead. Per-profile name so Admin + Alex don't
							// collide in the shared `hermes` namespace.
							extraObjects: [
								{
									apiVersion: "traefik.io/v1alpha1"
									kind:       "Middleware"
									metadata: {
										name:      "redirect-root-to-health-admin"
										namespace: "hermes"
									}
									spec: redirectRegex: {
										permanent:   false
										regex:       "^(https?://[^/]+)/?$"
										replacement: "${1}/health"
									}
								},
							]
						}
					}
					destination: {
						name:      "in-cluster"
						namespace: "hermes"
					}
					syncPolicy: {
						managedNamespaceMetadata: labels: {
							"app.kubernetes.io/part-of": "bb-platform"
							"infra.k8/tier":             "production"
							"infra.k8/cluster":          "home"
						}
						automated: {
							prune:    true
							selfHeal: true
						}
						syncOptions: [
							"CreateNamespace=true",
							"ServerSideApply=true",
						]
						retry: {
							limit: 5
							backoff: {
								duration:    "30s"
								factor:      2
								maxDuration: "5m"
							}
						}
					}
				}
			}
		}
	},

	// Hermes Agent — Alex's profile. Sibling of Admin's deploy above; runs
	// its own pod (gateway + dashboard sidecar) in the same `hermes`
	// namespace with its own PVC, Service, and Ingresses. Shares the
	// LLM provider (Vercel AI Gateway) and the in-cluster Honcho memory
	// server. Per-user API_SERVER_KEY + AI_GATEWAY_API_KEY synced from
	// secret/home/hermes-dev2 in OpenBao.
	{
		name:      "hermes-dev2"
		namespace: "argocd"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			generators: [{list: elements: [{}]}]
			template: {
				metadata: {
					name: "hermes-dev2"
					labels: {
						"app.kubernetes.io/part-of":       "bb-platform"
						"hermes.example.internal/profile": "dev2"
					}
					finalizers: ["resources-finalizer.argoproj.io"]
				}
				spec: {
					project: "bb-platform"
					source: {
						repoURL:        "https://github.com/example-org/k8-infra.git"
						targetRevision: "main"
						path:           "infrastructure/hermes-agent/chart"
						helm: valuesObject: {
							// Auto-restart on Secret/ConfigMap change (paired
							// with the hermes-dev2-secrets ExternalSecret).
							deploymentAnnotations: {
								"reloader.stakater.com/auto": "true"
							}
							// Bypass s6-overlay (exit-100 under readonly /run; dev2
							// was missing this and crashlooped 300+ times). Mirrors
							// admin's profile. See feedback-hermes-s6-readonly-run.
							command: ["/opt/hermes/.venv/bin/hermes"]
							image: {
								repository: "nousresearch/hermes-agent"
								tag:        "v2026.5.29.2"
								pullPolicy: "IfNotPresent"
							}
							persistence: {
								enabled:      true
								size:         "10Gi"
								storageClass: "longhorn"
								mountPath:    "/opt/data"
							}
							resources: {
								requests: {cpu: "250m", memory: "1Gi"}
								limits: {cpu: "2", memory: "4Gi"}
							}
							config: values: {
								model: {
									default:  "anthropic/claude-opus-4.6"
									provider: "auto"
									base_url: "https://ai-gateway.vercel.sh/v1"
								}
								agent: {
									max_turns:             90
									gateway_timeout:       1800
									restart_drain_timeout: 60
									tool_use_enforcement:  "auto"
								}
								memory: {
									memory_enabled: true
									provider:       "honcho"
								}
							}
							secrets: existingSecret: "hermes-dev2-secrets"

							// honcho-ai SDK install + honcho.json seed
							// (mirrors Admin's profile, aiPeer=dev2).
							extraEnv: [
								{name: "PYTHONPATH", value: "/honcho-pkg"},
							]
							extraVolumeMounts: [
								{name: "honcho-pkg", mountPath: "/honcho-pkg"},
							]
							extraInitContainers: [
								{
									name:            "install-honcho-plugin"
									image:           "python:3.13-slim"
									imagePullPolicy: "IfNotPresent"
									command: ["sh", "-c"]
									args: ["""
										set -e
										echo '> Installing honcho-ai into /honcho-pkg...'
										pip install --no-cache-dir --target /honcho-pkg honcho-ai 2>&1 | tail -3
										if [ ! -f /opt/data/honcho.json ]; then
										  echo '> Seeding honcho.json (enabled=true, aiPeer=dev2)...'
										  cat > /opt/data/honcho.json <<JSON
										{"hosts":{"hermes":{"enabled":true,"workspace":"hermes","aiPeer":"dev2","recallMode":"hybrid","writeFrequency":"async"}}}
										JSON
										else
										  echo '> honcho.json already exists; leaving as-is.'
										fi
										""",
									]
									volumeMounts: [
										{name: "honcho-pkg", mountPath: "/honcho-pkg"},
										{name: "data", mountPath: "/opt/data"},
									]
									resources: {
										requests: {cpu: "100m", memory: "128Mi"}
										limits: {cpu: "500m", memory: "256Mi"}
									}
									securityContext: {
										allowPrivilegeEscalation: false
										runAsNonRoot:             true
										runAsUser:                10000
										capabilities: drop: ["ALL"]
										seccompProfile: type: "RuntimeDefault"
									}
								},
							]
							apiServer: {
								enabled:   true
								host:      "0.0.0.0"
								port:      8642
								modelName: "hermes-agent"
							}
							service: {
								enabled: true
								type:    "ClusterIP"
								ports: [
									{
										name:          "api-server"
										port:          8642
										targetPort:    8642
										containerPort: 8642
										protocol:      "TCP"
									},
									{
										name:          "dashboard"
										port:          9119
										targetPort:    9119
										containerPort: 9119
										protocol:      "TCP"
									},
								]
							}
							extraContainers: [
								{
									name:            "dashboard"
									image:           "nousresearch/hermes-agent:v2026.5.29.2"
									imagePullPolicy: "IfNotPresent"
									workingDir:      "/opt/hermes"
									command: ["/opt/hermes/.venv/bin/hermes"]
									args: [
										"dashboard",
										"--host", "0.0.0.0",
										"--port", "9119",
										"--insecure",
										"--no-open",
										"--skip-build",
										"--tui",
									]
									envFrom: [{
										secretRef: name: "hermes-dev2-secrets"
									}]
									env: [
										{name: "HERMES_HOME", value: "/opt/data"},
										{name: "HOME", value: "/opt/data"},
										{name: "HERMES_DASHBOARD_TUI", value: "1"},
										{name: "PYTHONPATH", value: "/honcho-pkg"},
									]
									ports: [{
										name:          "dashboard"
										containerPort: 9119
										protocol:      "TCP"
									}]
									resources: {
										requests: {cpu: "100m", memory: "512Mi"}
										limits: {cpu: "1", memory: "2Gi"}
									}
									securityContext: {
										allowPrivilegeEscalation: false
										readOnlyRootFilesystem:   true
										capabilities: drop: ["ALL"]
										seccompProfile: type: "RuntimeDefault"
									}
									volumeMounts: [
										{name: "data", mountPath: "/opt/data"},
										{name: "tmp", mountPath: "/tmp"},
										{name: "tui-dist", mountPath: "/opt/hermes/ui-tui/dist"},
										{name: "honcho-pkg", mountPath: "/honcho-pkg"},
									]
								},
							]
							ingress: enabled:        false
							virtualService: enabled: false
							operator: enabled:       false
							bootstrap: {
								enabled:   true
								overwrite: true
							}
							extraVolumes: [
								{
									name: "tui-dist"
									emptyDir: {
										sizeLimit: "64Mi"
									}
								},
								{
									name: "honcho-pkg"
									emptyDir: {
										sizeLimit: "200Mi"
									}
								},
							]
							extraObjects: [
								{
									apiVersion: "traefik.io/v1alpha1"
									kind:       "Middleware"
									metadata: {
										name:      "redirect-root-to-health-dev2"
										namespace: "hermes"
									}
									spec: redirectRegex: {
										permanent:   false
										regex:       "^(https?://[^/]+)/?$"
										replacement: "${1}/health"
									}
								},
							]
						}
					}
					destination: {
						name:      "in-cluster"
						namespace: "hermes"
					}
					syncPolicy: {
						managedNamespaceMetadata: labels: {
							"app.kubernetes.io/part-of": "bb-platform"
							"infra.k8/tier":             "production"
							"infra.k8/cluster":          "home"
						}
						automated: {
							prune:    true
							selfHeal: true
						}
						syncOptions: [
							"CreateNamespace=true",
							"ServerSideApply=true",
						]
						retry: {
							limit: 5
							backoff: {
								duration:    "30s"
								factor:      2
								maxDuration: "5m"
							}
						}
					}
				}
			}
		}
	},

	// Hermes Agent — red-team profile. Autonomous pentest assistant
	// (kali-pentest skill, server mode = SSH to a Kali box on the LAN).
	// DEX-ONLY: no Bearer API Ingress — the sole external entrypoint is the
	// Dex-gated dashboard (hermes-redteam-dashboard.example.internal, see
	// ingresses.cue + the oauth2-proxy bridge in helmreleases.cue); the 8642
	// API stays ClusterIP-internal. Model = OpenAI Codex via ChatGPT OAuth
	// (one-time `hermes auth add codex-oauth` device login via kubectl exec;
	// creds persist in auth.json on the PVC). Honcho memory reuses the shared
	// instance in its own workspace (redteam-engagements) so pentest/target
	// data stays isolated.
	{
		name:      "hermes-redteam"
		namespace: "argocd"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			generators: [{list: elements: [{}]}]
			template: {
				metadata: {
					name: "hermes-redteam"
					labels: {
						"app.kubernetes.io/part-of":       "bb-platform"
						"hermes.example.internal/profile": "redteam"
					}
					finalizers: ["resources-finalizer.argoproj.io"]
				}
				spec: {
					project: "bb-platform"
					source: {
						repoURL:        "https://github.com/example-org/k8-infra.git"
						targetRevision: "main"
						path:           "infrastructure/hermes-agent/chart"
						helm: valuesObject: {
							deploymentAnnotations: {
								"reloader.stakater.com/auto": "true"
							}
							// Bypass s6-overlay (exit-100 under readonly /run;
							// see feedback-hermes-s6-readonly-run).
							command: ["/opt/hermes/.venv/bin/hermes"]
							image: {
								repository: "nousresearch/hermes-agent"
								tag:        "v2026.5.29.2"
								pullPolicy: "IfNotPresent"
							}
							persistence: {
								// 10Gi — all hermes profiles standardized at 10Gi
								// (actual usage ~1.2Gi). Longhorn schedulable headroom is
								// tight, so do not bump without checking node capacity.
								enabled:      true
								size:         "10Gi"
								storageClass: "longhorn"
								mountPath:    "/opt/data"
							}
							resources: {
								requests: {cpu: "250m", memory: "1Gi"}
								limits: {cpu: "2", memory: "4Gi"}
							}
							// overwrite:false so the one-time interactive
							// `hermes model` (OpenAI Codex) + `hermes auth add
							// codex-oauth` device login persist across restarts.
							bootstrap: {
								enabled:   true
								overwrite: false
							}
							config: values: {
								model: {
									default:  "openai/gpt-5-codex"
									provider: "auto"
								}
								agent: {
									max_turns:             120
									gateway_timeout:       1800
									restart_drain_timeout: 60
									tool_use_enforcement:  "auto"
								}
								memory: {
									memory_enabled: true
									provider:       "honcho"
								}
							}
							soul: text: """
								You are the Example Org INTERNAL RED TEAM — an autonomous
								offensive-security operator. Your mandate: find, prove, and help
								FIX security and compliance weaknesses across infrastructure and
								SaaS products that Example Org owns or is explicitly authorized
								to test. You break things to harden them; every finding ends in
								actionable defensive advice.

								MISSION
								- Hunt for real, exploitable weaknesses across our own systems,
								  cloud, and SaaS products. Prove impact with the least-damaging
								  proof necessary — enough to be undeniable, never more.
								- For EVERY finding, deliver remediation: the fix, the root
								  cause, and how to verify it is closed. Be willing and able to
								  advise concretely on how to fix what you find.
								- Frame findings against the controls that matter to us:
								  SOC 2, ISO 27001, ISO 42001 (AI management), and OWASP
								  (Top 10, API Top 10, ASVS). Tie each finding to the control it
								  violates and the evidence an auditor would want.

								SCOPE — non-negotiable
								- Operate ONLY against assets Example Org owns or has written
								  authorization to test. Confirm scope + authorization before any
								  active scanning or exploitation.
								- Be extremely careful with ANYTHING outside our control. Never
								  touch third-party systems, shared/upstream infrastructure, or
								  assets you cannot confirm are in scope — not even to look. If a
								  path leads off-scope, STOP and report it instead of following it.
								- Least-impact by default: passive recon and read-only checks
								  first; active testing only with scope confirmed; avoid
								  destructive actions and avoid exfiltrating data beyond the
								  minimum needed to prove a finding.

								TRADECRAFT / OPSEC
								- Emulate a real external adversary. ALWAYS route active testing
								  through the configured obfuscated, anonymized egress (VPN /
								  proxy / Tor path) so detection is exercised honestly and the
								  red-team infrastructure and identity are not exposed or traced.
								  Never test our externally-facing products from an attributable
								  or whitelisted path a real attacker would not have.
								- This obscures you from the BLUE TEAM to test detection — it is
								  never about evading accountability. Keep your OWN complete,
								  timestamped record of every action (targets, tools, payloads,
								  results) for the engagement report and audit trail.

								TOOLING
								- Use the kali-pentest skill in SERVER MODE — SSH to the
								  authorized Kali host (the operator supplies the target as
								  `<user>@<host>`; key at `~/.ssh/kali_key`) — for nmap, the
								  Burp/web stack, metasploit, hydra/hashcat, aircrack-ng, plus the
								  installed forensics / OSINT / web-pentest skills.
								- If you lack a tool, credential, network path, or obfuscated
								  egress an authorized task needs: set it up yourself when you can
								  do so safely, otherwise REQUEST that it be connected/provisioned
								  and state exactly what you need and why. Do NOT run active tests
								  over a non-obfuscated path — get the safe egress in place first.

								REPORTING
								- Each finding: title, severity, affected asset, reproduction,
								  proof, business + compliance impact (cite the SOC 2 / ISO 27001 /
								  ISO 42001 / OWASP control), and a concrete remediation +
								  verification step. Log engagements to your task-memory + the
								  honcho redteam-engagements workspace.
								"""
							secrets: existingSecret: "hermes-redteam-secrets"

							extraEnv: [
								{name: "PYTHONPATH", value: "/honcho-pkg"},
							]
							extraVolumeMounts: [
								{name: "honcho-pkg", mountPath: "/honcho-pkg"},
							]
							extraInitContainers: [
								{
									name:            "install-honcho-plugin"
									image:           "python:3.13-slim"
									imagePullPolicy: "IfNotPresent"
									command: ["sh", "-c"]
									args: ["""
										set -e
										echo '> Installing honcho-ai into /honcho-pkg...'
										pip install --no-cache-dir --target /honcho-pkg honcho-ai 2>&1 | tail -3
										if [ ! -f /opt/data/honcho.json ]; then
										  echo '> Seeding honcho.json (workspace=redteam-engagements, aiPeer=redteam)...'
										  cat > /opt/data/honcho.json <<JSON
										{"hosts":{"hermes":{"enabled":true,"workspace":"redteam-engagements","aiPeer":"redteam","recallMode":"hybrid","writeFrequency":"async"}}}
										JSON
										else
										  echo '> honcho.json already exists; leaving as-is.'
										fi
										""",
									]
									volumeMounts: [
										{name: "honcho-pkg", mountPath: "/honcho-pkg"},
										{name: "data", mountPath: "/opt/data"},
									]
									resources: {
										requests: {cpu: "100m", memory: "128Mi"}
										limits: {cpu: "500m", memory: "256Mi"}
									}
									securityContext: {
										allowPrivilegeEscalation: false
										runAsNonRoot:             true
										runAsUser:                10000
										capabilities: drop: ["ALL"]
										seccompProfile: type: "RuntimeDefault"
									}
								},
								{
									// Install the agent's security skills into
									// /opt/data/skills (= HERMES_HOME/skills, the path hermes loads):
									// Hermes optional-skills/security (web-pentest,
									// oss-forensics, sherlock, 1password), the kali-pentest
									// server-mode skill (nmap / metasploit / hydra / hashcat /
									// aircrack-ng), and a curated slice of the Anthropic
									// cybersecurity set (offensive / recon / OWASP / compliance;
									// forensics / DFIR / blue-team filtered out). Idempotent —
									// markers + dir checks on the PVC, so restarts skip.
									name:            "install-security-skills"
									image:           "alpine/git:2.45.2"
									imagePullPolicy: "IfNotPresent"
									command: ["sh", "-c"]
									args: ["""
										set -e
										SKILLS=/opt/data/skills
										mkdir -p "$SKILLS"
										# Curated filter: keep only offensive / recon / OWASP / compliance
										# skills from the Anthropic set; drop forensics / DFIR / blue-team.
										INC='injection|xss|csrf|ssrf|xxe|sqli|-rce|lfi|rfi|ssti|idor|deserializ|penetration-test|pentest|red-team|purple-team|reconnaissance|osint|enumerat|subdomain|exploit|privilege-escal|lateral-move|command-and-control|phishing|social-engineer|password-|kerberoast|bloodhound|active-directory|pass-the-|man-in-the-middle|wireless|wifi|bluetooth|api-security|web-application|graphql|jwt-|oauth|burp|metasploit|nmap|payload|evasion|bypass|brute|fuzz|cracking|spoofing|poisoning|hijack|smuggling|takeover|misconfig|vulnerability-scan|vulnerability-assess|cloud-penetration|container-escape|^scanning-|iso-27001|iso27001|soc-2|soc2|pci-dss|gdpr|hipaa|nist-|cis-bench|owasp'
										DROP='malware|forensic|incident-response|triage|yara|virustotal|-ioc|disk-image|memory-dump|sandbox|reverse-eng|threat-hunt|detecting-|detection|investigat|hunting-|analyzing-|-siem|-edr|soc-analyst|recovering-|eradicat|containing-|correlat|cti-report|mitre-navigator|kill-chain|incident-'
										# 1. Hermes official optional security skills (sparse
										#    checkout — avoids cloning the whole agent repo).
										if [ ! -d "$SKILLS/web-pentest" ]; then
										  echo '> hermes optional-skills/security...'
										  git clone --depth=1 --filter=blob:none --sparse https://github.com/NousResearch/hermes-agent.git /tmp/h
										  ( cd /tmp/h && git sparse-checkout set optional-skills/security )
										  cp -r /tmp/h/optional-skills/security/* "$SKILLS"/ 2>/dev/null || true
										  rm -rf /tmp/h
										fi
										# 2. kali-pentest (server-mode Kali tools).
										if [ ! -d "$SKILLS/kali-pentest" ]; then
										  echo '> kali-pentest...'
										  git clone --depth=1 https://github.com/x-glacier/kali-pentest.git /tmp/kp
										  cp -r /tmp/kp/kali-pentest "$SKILLS/kali-pentest"
										  rm -rf /tmp/kp
										fi
										# 3. Anthropic set — curated via INC/DROP (offensive /
										#    recon / OWASP / compliance; no forensics/DFIR/blue).
										if [ ! -f "$SKILLS/.anthropic-sec.installed" ]; then
										  echo '> Anthropic-Cybersecurity-Skills (curated)...'
										  git clone --depth=1 https://github.com/mukul975/Anthropic-Cybersecurity-Skills.git /tmp/acs
										  for d in $(ls /tmp/acs/skills | grep -iE "$INC" | grep -ivE "$DROP"); do
										    cp -r "/tmp/acs/skills/$d" "$SKILLS/$d" 2>/dev/null || true
										  done
										  touch "$SKILLS/.anthropic-sec.installed"
										  rm -rf /tmp/acs
										fi
										# 4. super-hermes prism skills + prisms (analytical
										#    prompt-writing). Installs into skills/ AND prisms/.
										if [ ! -d "$SKILLS/prism-scan" ]; then
										  echo '> super-hermes prisms...'
										  git clone --depth=1 https://github.com/Cranot/super-hermes.git /tmp/sh
										  cp -r /tmp/sh/skills/* "$SKILLS"/ 2>/dev/null || true
										  mkdir -p /opt/data/prisms
										  cp -r /tmp/sh/prisms/* /opt/data/prisms/ 2>/dev/null || true
										  rm -rf /tmp/sh
										fi
										# 5. Custom task-memory skill — delivered via the
										#    hermes-redteam-custom-skills ConfigMap (mounted at
										#    /custom-skills) so it needs no repo creds.
										if [ ! -d "$SKILLS/task-memory" ] && [ -d /custom-skills ]; then
										  echo '> custom task-memory skill...'
										  mkdir -p "$SKILLS/task-memory"
										  cp /custom-skills/* "$SKILLS/task-memory/" 2>/dev/null || true
										fi
										# ---- Builtin skills: keep only security / support categories ----
										# The image ships ~85 builtin skills under /opt/hermes/skills/<category>
										# (creative, gaming, media, productivity, ...). Pre-seed ONLY the
										# security / support categories into the load path, then drop the
										# .no-bundled-skills marker so the gateway seeder does not add the rest.
										for c in autonomous-ai-agents devops dogfood domain github mcp red-teaming research software-development yuanbao; do
										  [ -d "/opt/hermes/skills/$c" ] && [ ! -d "$SKILLS/$c" ] && cp -r "/opt/hermes/skills/$c" "$SKILLS/$c" 2>/dev/null || true
										done
										touch /opt/data/.no-bundled-skills
										# Belt-and-suspenders: drop non-security categories a prior seed added.
										for c in apple creative data-science diagramming email gaming gifs inference-sh media mlops note-taking productivity smart-home social-media; do
										  rm -rf "$SKILLS/$c"
										done
										# Clean up the legacy wrong-path clone (~/.hermes/skills is never loaded
										# by hermes when HERMES_HOME is set, so old installs left dead weight).
										rm -rf /opt/data/home/.hermes/skills 2>/dev/null || true
										echo "> skills installed: $(ls "$SKILLS" | wc -l)"
										""",
									]
									volumeMounts: [
										{name: "data", mountPath: "/opt/data"},
										{name: "custom-skills", mountPath: "/custom-skills", readOnly: true},
									]
									securityContext: {
										allowPrivilegeEscalation: false
										runAsNonRoot:             true
										runAsUser:                1000
										capabilities: drop: ["ALL"]
										seccompProfile: type: "RuntimeDefault"
									}
								},
								{
									// Write the Kali SSH key (from OpenBao via ESO) to
									// ~/.ssh/kali_key 0600, owned by uid 1000 so ssh
									// accepts it. Seed KALI_SSH_KEY in OpenBao at
									// secret/users/redteam/hermes.
									name:            "install-kali-ssh-key"
									image:           "busybox:1.36"
									imagePullPolicy: "IfNotPresent"
									command: ["sh", "-c"]
									args: ["""
										set -e
										mkdir -p /opt/data/home/.ssh
										if [ -n "${KALI_SSH_KEY:-}" ]; then
										  printf '%s' "$KALI_SSH_KEY" > /opt/data/home/.ssh/kali_key
										  chmod 600 /opt/data/home/.ssh/kali_key
										  echo '> wrote ~/.ssh/kali_key'
										else
										  echo '> KALI_SSH_KEY unset — seed it in OpenBao secret/users/redteam/hermes'
										fi
										""",
									]
									env: [{
										name: "KALI_SSH_KEY"
										valueFrom: secretKeyRef: {
											name:     "hermes-redteam-secrets"
											key:      "KALI_SSH_KEY"
											optional: true
										}
									}]
									volumeMounts: [{name: "data", mountPath: "/opt/data"}]
									securityContext: {
										allowPrivilegeEscalation: false
										runAsNonRoot:             true
										runAsUser:                1000
										capabilities: drop: ["ALL"]
										seccompProfile: type: "RuntimeDefault"
									}
								},
							]
							// API server is ClusterIP-internal only (no Ingress) —
							// the Dex-gated dashboard is the only external door.
							apiServer: {
								enabled:   true
								host:      "0.0.0.0"
								port:      8642
								modelName: "hermes-agent"
							}
							service: {
								enabled: true
								type:    "ClusterIP"
								ports: [
									{name: "api-server", port: 8642, targetPort: 8642, containerPort: 8642, protocol: "TCP"},
									{name: "dashboard", port: 9119, targetPort: 9119, containerPort: 9119, protocol: "TCP"},
								]
							}
							extraVolumes: [
								{name: "tui-dist", emptyDir: sizeLimit: "64Mi"},
								{name: "honcho-pkg", emptyDir: sizeLimit: "200Mi"},
								{name: "custom-skills", configMap: name: "hermes-redteam-custom-skills"},
							]
							// Custom task-memory skill (a lightweight local JSON
							// task index — fast recall of "what did I do here before"
							// without replaying history). Shipped as a ConfigMap so it
							// needs no repo creds; the install-security-skills init
							// copies /custom-skills/* into /opt/data/skills/task-memory.
							extraObjects: [
								{
									apiVersion: "v1"
									kind:       "ConfigMap"
									metadata: {
										name:      "hermes-redteam-custom-skills"
										namespace: "hermes"
									}
									data: {
										"SKILL.md": """
											# task-memory

											Lightweight local task memory. Maintains a small JSON index of past
											tasks keyed by `task_type` at `~/.hermes/task-memory.json`, so you can
											recall "what did I do with this before?" without replaying full
											session history. Sub-second, no external deps. Complements honcho
											(rich cross-session memory); this is a fast local index of concrete
											prior tasks + outcomes for repetitive engagement work.

											## Use

											- After finishing a discrete task, log it:
											  `python3 ~/.hermes/skills/task-memory/task_index.py <task_type> "<one-line summary + outcome>"`
											- Before similar work, recall prior tasks:
											  `python3 ~/.hermes/skills/task-memory/retrieve.py <task_type> [n]`
											  (n defaults to 3; task_type "*" = latest across all types)

											`task_type` examples: recon, nmap, web-pentest, exploit, report, or a
											target host. Keep summaries one line, factual, with the outcome.
											"""
										"task_index.py": """
											#!/usr/bin/env python3
											import json, os, sys, time
											INDEX = os.path.expanduser("~/.hermes/task-memory.json")
											def load():
											    try:
											        d = json.load(open(INDEX))
											        return d if isinstance(d, list) else []
											    except Exception:
											        return []
											if len(sys.argv) < 3:
											    sys.exit("usage: task_index.py <task_type> <summary...>")
											recs = load()
											recs.append({"iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
											             "task_type": sys.argv[1].strip().lower(),
											             "summary": " ".join(sys.argv[2:]).strip()})
											recs = recs[-2000:]
											os.makedirs(os.path.dirname(INDEX), exist_ok=True)
											json.dump(recs, open(INDEX, "w"), ensure_ascii=False)
											print("logged %s (%d records)" % (sys.argv[1].strip().lower(), len(recs)))
											"""
										"retrieve.py": """
											#!/usr/bin/env python3
											import json, os, sys
											INDEX = os.path.expanduser("~/.hermes/task-memory.json")
											try:
											    recs = json.load(open(INDEX))
											except Exception:
											    recs = []
											tt = sys.argv[1].strip().lower() if len(sys.argv) > 1 else "*"
											try:
											    n = int(sys.argv[2]) if len(sys.argv) > 2 else 3
											except Exception:
											    n = 3
											if tt != "*":
											    recs = [r for r in recs if r.get("task_type") == tt]
											recs = recs[-n:][::-1]
											if not recs:
											    print("(no prior tasks for %s)" % tt)
											for r in recs:
											    print("%s  [%s]  %s" % (r.get("iso", "?"), r.get("task_type", "?"), r.get("summary", "")))
											"""
									}
								},
							]
							extraContainers: [
								{
									name:            "dashboard"
									image:           "nousresearch/hermes-agent:v2026.5.29.2"
									imagePullPolicy: "IfNotPresent"
									workingDir:      "/opt/hermes"
									command: ["/opt/hermes/.venv/bin/hermes"]
									args: ["dashboard", "--host", "0.0.0.0", "--port", "9119", "--insecure", "--no-open", "--skip-build", "--tui"]
									envFrom: [{secretRef: name: "hermes-redteam-secrets"}]
									env: [
										{name: "HERMES_HOME", value: "/opt/data"},
										{name: "HOME", value: "/opt/data"},
										{name: "HERMES_DASHBOARD_TUI", value: "1"},
										{name: "PYTHONPATH", value: "/honcho-pkg"},
									]
									ports: [{name: "dashboard", containerPort: 9119, protocol: "TCP"}]
									resources: {
										requests: {cpu: "100m", memory: "512Mi"}
										limits: {cpu: "1", memory: "2Gi"}
									}
									securityContext: {
										allowPrivilegeEscalation: false
										readOnlyRootFilesystem:   true
										capabilities: drop: ["ALL"]
										seccompProfile: type: "RuntimeDefault"
									}
									volumeMounts: [
										{name: "data", mountPath: "/opt/data"},
										{name: "tmp", mountPath: "/tmp"},
										{name: "tui-dist", mountPath: "/opt/hermes/ui-tui/dist"},
										{name: "honcho-pkg", mountPath: "/honcho-pkg"},
									]
								},
							]
							ingress: enabled:        false
							virtualService: enabled: false
							operator: enabled:       false
						}
					}
					destination: {
						name:      "in-cluster"
						namespace: "hermes"
					}
					syncPolicy: {
						managedNamespaceMetadata: labels: {
							"app.kubernetes.io/part-of": "bb-platform"
							"infra.k8/tier":             "production"
							"infra.k8/cluster":          "home"
						}
						automated: {
							prune:    true
							selfHeal: true
						}
						syncOptions: [
							"CreateNamespace=true",
							"ServerSideApply=true",
						]
						retry: {
							limit: 5
							backoff: {
								duration:    "30s"
								factor:      2
								maxDuration: "5m"
							}
						}
					}
				}
			}
		}
	},

	// Honcho — self-hosted dialectic memory for stateful agents
	// (plastic-labs/honcho). Single pod bundling API + deriver worker +
	// pgvector Postgres + Redis cache. Manifests live as raw YAML in
	// infrastructure/honcho/ — ArgoCD reads directly from the path
	// (no helm).
	{
		name:      "honcho"
		namespace: "argocd"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			generators: [{list: elements: [{}]}]
			template: {
				metadata: {
					name: "honcho"
					labels: {
						"app.kubernetes.io/part-of": "bb-platform"
					}
					finalizers: ["resources-finalizer.argoproj.io"]
				}
				spec: {
					project: "bb-platform"
					source: {
						repoURL:        "https://github.com/example-org/k8-infra.git"
						targetRevision: "main"
						path:           "infrastructure/honcho"
						directory: {
							recurse: false
						}
					}
					destination: {
						name:      "in-cluster"
						namespace: "honcho"
					}
					syncPolicy: {
						managedNamespaceMetadata: labels: {
							"app.kubernetes.io/part-of": "bb-platform"
							"infra.k8/tier":             "production"
							"infra.k8/cluster":          "home"
						}
						automated: {
							prune:    true
							selfHeal: true
						}
						syncOptions: [
							"CreateNamespace=true",
							"ServerSideApply=true",
						]
						retry: {
							limit: 5
							backoff: {
								duration:    "30s"
								factor:      2
								maxDuration: "5m"
							}
						}
					}
				}
			}
		}
	},
]
