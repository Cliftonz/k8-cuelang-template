package preview

let C = cluster

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
		slug:        "salessage"
		owner:       "example-org"
		name:        "SalesSage"
		dependsOnAI: true
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
			clusterResourceWhitelist: []
			namespaceResourceBlacklist: [
				{group: "", kind: "ResourceQuota"},
				{group: "networking.k8s.io", kind: "NetworkPolicy"},
				{group: "rbac.authorization.k8s.io", kind: "*"},
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
argoApplicationSets: [
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
								owner: "{{.owner}}"
								repo:  "{{.name}}"
								tokenRef: {
									secretName: "github-token"
									key:        "token"
								}
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
						"notifications.argoproj.io/subscribe.on-ai-outage.discord":      ""
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
						name:  "Preview URL"
						value: "https://{{.slug}}-{{.number}}.preview.example.com"
					}]
					source: {
						repoURL:        "https://github.com/{{.owner}}/{{.name}}.git"
						targetRevision: "{{.head_sha}}"
						path:           "chart"
						helm: valuesObject: {
							image: {
								repository: "ghcr.io/{{.owner}}/{{.name | toLower}}"
								// tag intentionally unset — chart's salessage.imageTag
								// helper falls through to `pr-<prNumber>` (the floating
								// tag preview-build.yaml re-points on every successful
								// build). See composites/home/argocd.cue for the full
								// rationale; same race-condition class applies here.
								commitSha: "{{.head_sha}}"
							}
							prNumber: "{{.number}}"
							ingress: {
								enabled:   true
								className: "cloudflare-tunnel"
								hosts: [{
									host: "{{.slug}}-{{.number}}.preview.example.com"
									paths: [{path: "/", pathType: "Prefix"}]
								}]
							}
							fullnameOverride: "{{.slug}}-{{.number}}"
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
]
