package preview

let C = cluster

// Argo Events EventBus — NATS-backed event transport layer.
argoEventBuses: [
	{
		name:      "default"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			nats: native: {
				replicas: 1
				auth:     "token"
			}
		}
	},
]

// Argo Events EventSources — receive GitHub webhooks and container registry events.
//
// Both endpoints are exposed via cloudflared at https://events.example.com
// and are intended to receive events for all example-org repos. We use a
// generic `webhook:` EventSource (not the `github:` type) so Argo Events
// does NOT auto-provision per-repo webhooks via the GitHub API — a single
// org-level webhook is configured manually at
//   https://github.com/organizations/example-org/settings/hooks
// pointing at https://events.example.com/github/pr.
//
// Security: the generic webhook does NOT validate GitHub's X-Hub-Signature-256
// HMAC signature. Accepted risk rationale:
//   - Endpoint is reachable ONLY via Cloudflare tunnel (not public internet)
//   - An attacker would need to compromise the tunnel to send forged events
//   - All downstream actions are scoped (Sensors filter by repo, action, body)
//
// To add HMAC validation later: deploy an openresty/nginx validating proxy
// as a Deployment in argo-events that checks X-Hub-Signature-256 against
// the secret in `github-webhook-secret`, then update the Cloudflare tunnel
// Ingress to route through the proxy instead of directly to the EventSource.
// The Argo Events generic webhook `authSecret` field does NOT work for this
// (it checks Authorization header, not X-Hub-Signature-256). The `github`
// EventSource type validates HMAC but only supports repo-level hooks.
argoEventSources: [
	// GitHub org webhook receiver for PR / issue_comment / status events.
	{
		name:      "github-webhook"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			service: ports: [{port: 12000, targetPort: 12000}]
			webhook: "pr-events": {
				endpoint: "/github/pr"
				port:     "12000"
				method:   "POST"
			}
		}
	},
	// Container registry push event receiver.
	// GHCR does not natively support webhooks; CI POSTs here after docker push.
	{
		name:      "container-registry"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			service: ports: [{port: 13000, targetPort: 13000}]
			webhook: "image-push": {
				endpoint: "/registry/push"
				port:     "13000"
				method:   "POST"
			}
		}
	},
]

// Argo Events Sensors — correlate events and trigger downstream actions.
//
// All sensors accept events from any example-org/* repo. The repo name is
// extracted from the webhook payload and passed through to the sync Job as
// REPO_SLUG, which is used to target the matching Argo CD Application
// ({slug}-pr-{number}).
argoSensors: [
	// /help → static reply listing available slash commands.
	{
		name:      "slash-help"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			dependencies: [{
				name:            "help-comment"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["created"]},
					{path: "body.comment.body", type: "string", comparator: "=~", value: ["^/help(\\s|$)"]},
					{path: "body.repository.full_name", type: "string", comparator: "=~", value: ["^example-org/"]},
				]
			}]
			triggers: [{
				template: {
					name: "post-help"
					k8s: {
						operation: "create"
						source: resource: {
							apiVersion: "batch/v1"
							kind:       "Job"
							metadata: {
								generateName: "slash-help-"
								namespace:    "argo-events"
							}
							spec: {
								template: spec: {
									restartPolicy: "Never"
									containers: [{
										name:  "reply"
										image: "ghcr.io/cli/cli:2.62.0"
										command: ["/bin/sh", "-c", "PLACEHOLDER"]
										env: [{
											name: "GH_TOKEN"
											valueFrom: secretKeyRef: {
												name: "github-pat-events"
												key:  "GITHUB_TOKEN"
											}
										}]
										resources: {
											requests: {cpu: "10m", memory: "32Mi"}
											limits: {cpu: "100m", memory: "64Mi"}
										}
									}]
								}
								backoffLimit:            1
								ttlSecondsAfterFinished: 300
							}
						}
						parameters: [{
							src: {
								dependencyName: "help-comment"
								dataTemplate: #"""
									set -eu
									REPO='{{ .Input.body.repository.full_name }}'
									COMMENT_PATH='{{ .Input.body.comment.path }}'
									COMMENT_ID='{{ .Input.body.comment.id }}'

									HELP_BODY='## Available slash commands

									| Command | Where | What it does |
									|---|---|---|
									| `/review` | PR comment | Full AI review of the PR diff. Posts a summary. |
									| `/fix-ci` | PR comment _(auto-posted by CI on failure)_ | Reproduces failures, fixes code, pushes to PR branch. Max 3 attempts. |
									| `/explain <question>` | PR line comment | Explains the code at the commented line. Threaded reply. |
									| `/help` | Any comment | Shows this help message. |

									Commands work on any `example-org/*` repository.'

									if [ -n "$COMMENT_PATH" ] && [ "$COMMENT_PATH" != "null" ]; then
									  PR_NUM='{{ .Input.body.pull_request.number }}'
									  gh api -X POST "repos/${REPO}/pulls/${PR_NUM}/comments/${COMMENT_ID}/replies" \
									    -f body="$HELP_BODY"
									else
									  ISSUE_NUM='{{ .Input.body.issue.number }}'
									  gh api -X POST "repos/${REPO}/issues/${ISSUE_NUM}/comments" \
									    -f body="$HELP_BODY"
									fi
									"""#
							}
							dest: "spec.template.spec.containers.0.command.2"
						}]
					}
				}
			}]
		}
	},
	// palette-init → post initial palette comment on PR open.
	{
		name:      "palette-init"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			dependencies: [{
				name:            "pr-opened"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["opened"]},
					{path: "body.pull_request.number", type: "number", comparator: ">", value: ["0"]},
					{path: "body.repository.full_name", type: "string", comparator: "=~", value: ["^example-org/"]},
				]
			}]
			triggers: [{
				template: {
					name: "post-initial-palette"
					k8s: {
						operation: "create"
						source: resource: {
							apiVersion: "batch/v1"
							kind:       "Job"
							metadata: {
								generateName: "palette-init-"
								namespace:    "argo-events"
							}
							spec: {
								template: spec: {
									restartPolicy: "Never"
									containers: [{
										name:  "post"
										image: "ghcr.io/cli/cli:2.62.0"
										command: ["/bin/sh", "-c", "PLACEHOLDER"]
										env: [{
											name: "GH_TOKEN"
											valueFrom: secretKeyRef: {
												name: "github-pat-events"
												key:  "GITHUB_TOKEN"
											}
										}]
										resources: {
											requests: {cpu: "10m", memory: "32Mi"}
											limits: {cpu: "100m", memory: "64Mi"}
										}
									}]
								}
								backoffLimit:            1
								ttlSecondsAfterFinished: 300
							}
						}
						parameters: [{
							src: {
								dependencyName: "pr-opened"
								dataTemplate: #"""
									set -eu
									REPO='{{ .Input.body.repository.full_name }}'
									PR='{{ .Input.body.pull_request.number }}'

									BODY='<!-- kelos-palette -->
									## Kelos AI Agent

									| Agent | Status | Details | Updated |
									|---|---|---|---|
									| Review | — | _not requested_ | — |
									| CI Fix | — | _waiting for CI_ | — |
									| Explains | 0 | — | — |

									### Commands
									| Command | Where | Description |
									|---|---|---|
									| `/review` | PR comment | Request a full AI review |
									| `/fix-ci` | PR comment | Auto-fix CI failures (auto-triggered) |
									| `/explain <question>` | Line comment | Explain code at a specific line |
									| `/help` | Any comment | Show available commands |

									_Palette initialized. Updates appear as agents run._'

									gh api -X POST "repos/${REPO}/issues/${PR}/comments" \
									  -f body="$BODY"
									"""#
							}
							dest: "spec.template.spec.containers.0.command.2"
						}]
					}
				}
			}]
		}
	},

	// ──────────────────────────────────────────────────────────────
	// Feature Pipeline Sensors (6 total)
	// Issue-to-merge automation: ideate → implement → review → fix loop.
	// Scripts live in ci/scripts/feature-*.sh — Jobs git-clone the
	// k8-infra repo and run them, so script updates don't require
	// re-rendering the Sensor manifests.
	// ──────────────────────────────────────────────────────────────

	// 1. feature-branch-create: fires on `feature` label added to issue.
	//    Creates Job that slugs the title + creates branch + comments.
	{
		name:      "feature-branch-create"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			dependencies: [{
				name:            "feature-labeled"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["labeled"]},
					{path: "body.label.name", type: "string", value: [labels.aiFeature]},
					{path: "body.issue.number", type: "number", comparator: ">", value: ["0"]},
					{path: "body.repository.full_name", type: "string", comparator: "=~", value: ["^example-org/"]},
				]
			}]
			triggers: [{
				template: {
					name: "create-feature-branch"
					k8s: {
						operation: "create"
						source: resource: {
							apiVersion: "batch/v1"
							kind:       "Job"
							metadata: {
								generateName: "feature-branch-create-"
								namespace:    "argo-events"
							}
							spec: {
								template: spec: {
									restartPolicy: "Never"
									containers: [{
										name:  "create"
										image: "ghcr.io/cli/cli:2.62.0"
										command: ["/bin/sh", "-c", "PLACEHOLDER"]
										env: [
											{name: "REPO", value: "PLACEHOLDER_REPO"},
											{name: "ISSUE_NUMBER", value: "PLACEHOLDER_ISSUE"},
											{name: "ISSUE_TITLE", value: "PLACEHOLDER_TITLE"},
											{name: "BRANCH_CREATED_LABEL", value: labels.branchCreated},
											{name: "AI_IMPLEMENT_LABEL", value: labels.aiImplement},
											{name: "GH_TOKEN", valueFrom: secretKeyRef: {
												name: "github-pat-events"
												key:  "GITHUB_TOKEN"
											}},
										]
										resources: {
											requests: {cpu: "10m", memory: "32Mi"}
											limits: {cpu: "100m", memory: "128Mi"}
										}
									}]
								}
								backoffLimit:            1
								ttlSecondsAfterFinished: 300
							}
						}
						parameters: [
							{
								src: {
									dependencyName: "feature-labeled"
									dataKey:        "body.repository.full_name"
								}
								dest: "spec.template.spec.containers.0.env.0.value"
							},
							{
								src: {
									dependencyName: "feature-labeled"
									dataKey:        "body.issue.number"
								}
								dest: "spec.template.spec.containers.0.env.1.value"
							},
							{
								src: {
									dependencyName: "feature-labeled"
									dataKey:        "body.issue.title"
								}
								dest: "spec.template.spec.containers.0.env.2.value"
							},
							{
								src: {
									dependencyName: "feature-labeled"
									dataTemplate: """
										set -eu
										apk add --no-cache git bash >/dev/null 2>&1 || true
										git clone --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/example-org/k8-infra.git" /tmp/infra
										exec bash /tmp/infra/ci/scripts/feature-branch-create.sh
										"""
								}
								dest: "spec.template.spec.containers.0.command.2"
							},
						]
					}
				}
			}]
		}
	},

	// 2. feature-ideator: fires on issue_comment on feature-labeled issue.
	//    Spawns a Kelos Task (ideator agent).
	//    Rate-limited to 1/min per issue via Sensor rateLimit.
	{
		name:      "feature-ideator"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			dependencies: [{
				name:            "feature-comment"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["created"]},
					{path: "body.issue.pull_request", type: "string", comparator: "=", value: [""]},
					// Must be on a feature-labeled issue, NOT already implementing,
					// NOT awaiting-human.
					{path: "body.issue.labels.#.name", type: "string", comparator: "=~", value: [labels.aiFeature]},
					{path: "body.issue.labels.#.name", type: "string", comparator: "!~", value: [labels.aiImplement]},
					{path: "body.issue.labels.#.name", type: "string", comparator: "!~", value: [labels.awaitingHuman]},
					// Not authored by the bot (prevent self-triggering loop).
					{path: "body.comment.user.login", type: "string", comparator: "!~", value: ["example-org-bot"]},
					{path: "body.repository.full_name", type: "string", comparator: "=~", value: ["^example-org/"]},
				]
			}]
			triggers: [{
				// 1/min per-issue ideation rate limit.
				rateLimit: {
					unit:            "Minute"
					requestsPerUnit: 1
				}
				template: {
					name: "spawn-ideator"
					k8s: {
						operation: "create"
						source: resource: {
							apiVersion: "kelos.dev/v1alpha1"
							kind:       "Task"
							metadata: {
								generateName: "feature-ideator-"
								namespace:    "kelos-system"
								labels: {
									"app.kubernetes.io/managed-by": "argo-events"
									"kelos.dev/role":               "feature-ideator"
								}
							}
							spec: {
								type: "claude-code"
								credentials: {
									type: "oauth"
									secretRef: name: "claude-code-oauth"
								}
								agentConfigRef: name:     "feature-ideator"
								ttlSecondsAfterFinished: 3600
								podOverrides: env: [{
									name: "GITHUB_TOKEN"
									valueFrom: secretKeyRef: {
										name: "github-pat"
										key:  "GITHUB_TOKEN"
									}
								}]
								prompt: "(filled by parameters)"
							}
						}
						parameters: [{
							src: {
								dependencyName: "feature-comment"
								dataTemplate: """
									A new comment was posted on issue #{{ .Input.body.issue.number }} ({{ .Input.body.issue.title }}) in {{ .Input.body.repository.full_name }}.

									Repo:        {{ .Input.body.repository.full_name }}
									Issue:       #{{ .Input.body.issue.number }}
									Commenter:   {{ .Input.body.comment.user.login }}

									Read the FULL issue thread via `gh api repos/{{ .Input.body.repository.full_name }}/issues/{{ .Input.body.issue.number }}/comments --paginate` and the issue body via `gh issue view {{ .Input.body.issue.number }} --repo {{ .Input.body.repository.full_name }}`.

									Follow your AgentConfig. Post ONE comment (question / proposed scope / ready-for-impl). If blocked on human, post `<!-- needs-human-input -->` and apply `awaiting-human` label.

									Stop after posting.
									"""
							}
							dest: "spec.prompt"
						}]
					}
				}
			}]
		}
	},

	// 3. feature-implementer: fires on `implement` label added.
	//    Spawns a Kelos Task on the repo's Workspace.
	{
		name:      "feature-implementer"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			dependencies: [{
				name:            "implement-labeled"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["labeled"]},
					{path: "body.label.name", type: "string", value: [labels.aiImplement]},
					{path: "body.issue.number", type: "number", comparator: ">", value: ["0"]},
					// issue has branch-created label (from branch-create Sensor)
					{path: "body.issue.labels.#.name", type: "string", comparator: "=~", value: [labels.branchCreated]},
					{path: "body.repository.full_name", type: "string", comparator: "=~", value: ["^example-org/"]},
				]
			}]
			triggers: [{
				template: {
					name: "spawn-implementer"
					k8s: {
						operation: "create"
						source: resource: {
							apiVersion: "kelos.dev/v1alpha1"
							kind:       "Task"
							metadata: {
								generateName: "feature-implementer-"
								namespace:    "kelos-system"
								labels: {
									"app.kubernetes.io/managed-by": "argo-events"
									"kelos.dev/role":               "feature-implementer"
								}
							}
							spec: {
								type: "claude-code"
								credentials: {
									type: "oauth"
									secretRef: name: "claude-code-oauth"
								}
								agentConfigRef: name: "feature-implementer"
								// workspaceRef resolved by repo name via parameters
								workspaceRef: name:     "PLACEHOLDER"
								ttlSecondsAfterFinished: 7200
								podOverrides: env: [{
									name: "GITHUB_TOKEN"
									valueFrom: secretKeyRef: {
										name: "github-pat"
										key:  "GITHUB_TOKEN"
									}
								}]
								prompt: "(filled by parameters)"
							}
						}
						parameters: [
							{
								src: {
									dependencyName: "implement-labeled"
									// Resolve `example-org/SalesSage` → `salessage` (lowercase)
									// Use jq to lowercase the repo name portion.
									dataTemplate: "{{ .Input.body.repository.name | lower }}"
								}
								dest: "spec.workspaceRef.name"
							},
							{
								src: {
									dependencyName: "implement-labeled"
									dataTemplate: """
										Issue #{{ .Input.body.issue.number }} ({{ .Input.body.issue.title }}) in {{ .Input.body.repository.full_name }} was labeled `implement`.

										Read the full issue thread. Find the branch name from the `<!-- branch-announce -->` comment. Checkout that branch (NOT a new one). Implement the feature. Run full CI locally. Push. Open draft PR. Mark ready. Apply `pending-review` label.

										Stop when done.
										"""
								}
								dest: "spec.prompt"
							},
						]
					}
				}
			}]
		}
	},

	// 4. feature-review-tier1: fires on PR ready-for-review (with pending-review label)
	//    OR push to a branch with an open PR (re-review after fixer pushes).
	//    Spawns security + architect Tasks in parallel.
	{
		name:      "feature-review-tier1"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			dependencies: [{
				name:            "pr-ready"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					// Either PR ready-for-review event OR push to PR branch.
					// Filter is OR-ish: ANY filter match triggers.
					{path: "body.action", type: "string", value: ["ready_for_review", "labeled", "synchronize"]},
					{path: "body.pull_request.number", type: "number", comparator: ">", value: ["0"]},
					{path: "body.pull_request.labels.#.name", type: "string", comparator: "=~", value: [labels.pendingReview]},
					{path: "body.repository.full_name", type: "string", comparator: "=~", value: ["^example-org/"]},
				]
			}]
			triggers: [
				// Tier 1 reviewer 1: security
				{
					template: {
						name: "spawn-review-security"
						k8s: {
							operation: "create"
							source: resource: {
								apiVersion: "kelos.dev/v1alpha1"
								kind:       "Task"
								metadata: {
									generateName: "feature-review-security-"
									namespace:    "kelos-system"
									labels: {
										"app.kubernetes.io/managed-by": "argo-events"
										"kelos.dev/role":               "feature-review-security"
									}
								}
								spec: {
									type: "claude-code"
									credentials: {
										type: "oauth"
										secretRef: name: "claude-code-oauth"
									}
									agentConfigRef: name: "feature-review-security"
									ttlSecondsAfterFinished: 3600
									podOverrides: env: [{
										name: "GITHUB_TOKEN"
										valueFrom: secretKeyRef: {
											name: "github-pat"
											key:  "GITHUB_TOKEN"
										}
									}]
									prompt: "(filled by parameters)"
								}
							}
							parameters: [{
								src: {
									dependencyName: "pr-ready"
									dataTemplate: """
										Review PR #{{ .Input.body.pull_request.number }} on {{ .Input.body.repository.full_name }} at commit {{ .Input.body.pull_request.head.sha }}.

										Follow your AgentConfig. Post ONE formal PR review via the GitHub Reviews API with marker `<!-- review-security: {verdict} -->`. Use commit_id="{{ .Input.body.pull_request.head.sha }}". Stop after posting.
										"""
								}
								dest: "spec.prompt"
							}]
						}
					}
				},
				// Tier 1 reviewer 2: architect
				{
					template: {
						name: "spawn-review-architect"
						k8s: {
							operation: "create"
							source: resource: {
								apiVersion: "kelos.dev/v1alpha1"
								kind:       "Task"
								metadata: {
									generateName: "feature-review-architect-"
									namespace:    "kelos-system"
									labels: {
										"app.kubernetes.io/managed-by": "argo-events"
										"kelos.dev/role":               "feature-review-architect"
									}
								}
								spec: {
									type: "claude-code"
									credentials: {
										type: "oauth"
										secretRef: name: "claude-code-oauth"
									}
									agentConfigRef: name: "feature-review-architect"
									ttlSecondsAfterFinished: 3600
									podOverrides: env: [{
										name: "GITHUB_TOKEN"
										valueFrom: secretKeyRef: {
											name: "github-pat"
											key:  "GITHUB_TOKEN"
										}
									}]
									prompt: "(filled by parameters)"
								}
							}
							parameters: [{
								src: {
									dependencyName: "pr-ready"
									dataTemplate: """
										Review PR #{{ .Input.body.pull_request.number }} on {{ .Input.body.repository.full_name }} at commit {{ .Input.body.pull_request.head.sha }}.

										Follow your AgentConfig. Post ONE formal PR review via the GitHub Reviews API with marker `<!-- review-architect: {verdict} -->`. Use commit_id="{{ .Input.body.pull_request.head.sha }}". Stop after posting.
										"""
								}
								dest: "spec.prompt"
							}]
						}
					}
				},
			]
		}
	},

	// 5. feature-review-orchestrator: fires on pull_request_review submitted
	//    or push to a PR branch. Runs feature-orchestrator.sh which counts
	//    verdicts and decides next action.
	{
		name:      "feature-review-orchestrator"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			dependencies: [{
				name:            "review-or-push"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["submitted", "synchronize"]},
					{path: "body.pull_request.number", type: "number", comparator: ">", value: ["0"]},
					{path: "body.repository.full_name", type: "string", comparator: "=~", value: ["^example-org/"]},
				]
			}]
			triggers: [{
				template: {
					name: "run-orchestrator"
					k8s: {
						operation: "create"
						source: resource: {
							apiVersion: "batch/v1"
							kind:       "Job"
							metadata: {
								generateName: "feature-orchestrator-"
								namespace:    "kelos-system"
							}
							spec: {
								template: spec: {
									restartPolicy:      "Never"
									serviceAccountName: "feature-orchestrator"
									containers: [{
										name:  "orchestrator"
										image: "alpine/k8s:1.31.1@sha256:dfe8c7a06c41d0b6e8757da99531f8f302e9a2687fa0155af4c4087df585c9c8"
										command: ["/bin/sh", "-c", "PLACEHOLDER"]
										env: [
											{name: "REPO", value: "PLACEHOLDER_REPO"},
											{name: "PR_NUMBER", value: "PLACEHOLDER_PR"},
											{name: "READY_TO_MERGE_LABEL", value: labels.readyToMerge},
											{name: "REVIEW_FAILED_LABEL", value: labels.reviewFailed},
											{name: "AWAITING_HUMAN_LABEL", value: labels.awaitingHuman},
											{name: "GH_TOKEN", valueFrom: secretKeyRef: {
												name: "github-pat"
												key:  "GITHUB_TOKEN"
											}},
										]
										resources: {
											requests: {cpu: "50m", memory: "128Mi"}
											limits: {cpu: "500m", memory: "512Mi"}
										}
									}]
								}
								backoffLimit:            1
								ttlSecondsAfterFinished: 600
							}
						}
						parameters: [
							{
								src: {
									dependencyName: "review-or-push"
									dataKey:        "body.repository.full_name"
								}
								dest: "spec.template.spec.containers.0.env.0.value"
							},
							{
								src: {
									dependencyName: "review-or-push"
									// number from pull_request.number (review event) or
									// number from the PR associated with a push event.
									// For push events use the first PR found in the payload.
									dataTemplate: "{{ if .Input.body.pull_request }}{{ .Input.body.pull_request.number }}{{ else }}0{{ end }}"
								}
								dest: "spec.template.spec.containers.0.env.1.value"
							},
							{
								src: {
									dependencyName: "review-or-push"
									dataTemplate: """
										set -eu
										apk add --no-cache git bash jq >/dev/null 2>&1 || true
										# gh CLI install (alpine doesn't have it by default)
										if ! command -v gh >/dev/null 2>&1; then
										  wget -qO- https://github.com/cli/cli/releases/download/v2.62.0/gh_2.62.0_linux_amd64.tar.gz | tar -xz -C /tmp
										  mv /tmp/gh_2.62.0_linux_amd64/bin/gh /usr/local/bin/gh
										fi
										git clone --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/example-org/k8-infra.git" /tmp/infra
										exec bash /tmp/infra/ci/scripts/feature-orchestrator.sh
										"""
								}
								dest: "spec.template.spec.containers.0.command.2"
							},
						]
					}
				}
			}]
		}
	},

	// 6. feature-human-resume: fires on `awaiting-human` label REMOVED.
	//    Posts a comment noting the human unblocked the pipeline so agents
	//    know to re-engage on the next natural trigger (comment, push, etc.).
	{
		name:      "feature-human-resume"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			dependencies: [{
				name:            "human-unblocked"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["unlabeled"]},
					{path: "body.label.name", type: "string", value: [labels.awaitingHuman]},
					{path: "body.repository.full_name", type: "string", comparator: "=~", value: ["^example-org/"]},
				]
			}]
			triggers: [{
				template: {
					name: "post-resume-note"
					k8s: {
						operation: "create"
						source: resource: {
							apiVersion: "batch/v1"
							kind:       "Job"
							metadata: {
								generateName: "feature-resume-"
								namespace:    "argo-events"
							}
							spec: {
								template: spec: {
									restartPolicy: "Never"
									containers: [{
										name:  "resume"
										image: "ghcr.io/cli/cli:2.62.0"
										command: ["/bin/sh", "-c", "PLACEHOLDER"]
										env: [{
											name: "GH_TOKEN"
											valueFrom: secretKeyRef: {
												name: "github-pat-events"
												key:  "GITHUB_TOKEN"
											}
										}]
										resources: {
											requests: {cpu: "10m", memory: "32Mi"}
											limits: {cpu: "100m", memory: "64Mi"}
										}
									}]
								}
								backoffLimit:            1
								ttlSecondsAfterFinished: 300
							}
						}
						parameters: [{
							src: {
								dependencyName: "human-unblocked"
								dataTemplate: #"""
									set -eu
									REPO='{{ .Input.body.repository.full_name }}'
									NUM='{{ if .Input.body.pull_request }}{{ .Input.body.pull_request.number }}{{ else }}{{ .Input.body.issue.number }}{{ end }}'
									gh api -X POST "repos/${REPO}/issues/${NUM}/comments" -f body=":unlock: Human unblocked this. Next agent action fires on the next natural trigger (new comment, push, label, etc.)."
									"""#
							}
							dest: "spec.template.spec.containers.0.command.2"
						}]
					}
				}
			}]
		}
	},

	// /explain on a PR review comment → Kelos Task that posts a
	// threaded reply.
	//
	// Triggered when a collaborator posts a PR review comment starting
	// with `/explain` on any example-org repo. The Sensor stamps a Task
	// directly (no TaskSpawner + no Workspace — the agent uses gh api
	// to read files and post the reply). Idempotent on comment.id.
	//
	// Prerequisite: the example-org org webhook must have the
	// "Pull request review comments" event enabled. Check via
	//   gh api orgs/example-org/hooks --jq '.[].events'
	{
		name:      "code-explain"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			dependencies: [{
				name:            "review-comment"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["created"]},
					// pull_request_review_comment events carry comment.path;
					// issue_comment events do not. This discriminator picks
					// off exactly PR review comments.
					{path: "body.comment.path", type: "string", comparator: "!=", value: [""]},
					{path: "body.comment.body", type: "string", comparator: "=~", value: ["^/explain(\\s|$)"]},
					{path: "body.repository.full_name", type: "string", comparator: "=~", value: ["^example-org/"]},
				]
			}]
			triggers: [{
				// Cap at 3 explains per minute org-wide. Excess events
				// are dropped (not queued). Re-trigger by posting /explain again.
				rateLimit: {
					unit:            "Minute"
					requestsPerUnit: 3
				}
				template: {
					name: "create-explain-task"
					k8s: {
						operation: "create"
						source: resource: {
							apiVersion: "kelos.dev/v1alpha1"
							kind:       "Task"
							metadata: {
								// `parameters` below appends the comment.id to
								// this name for idempotency on webhook redelivery.
								name:      "code-explain-"
								namespace: "kelos-system"
								labels: {
									"app.kubernetes.io/managed-by": "argo-events"
									"kelos.dev/role":               "code-explain"
								}
							}
							spec: {
								type: "claude-code"
								credentials: {
									type: "oauth"
									secretRef: name: "claude-code-oauth"
								}
								agentConfigRef: name:     "code-explainer"
								ttlSecondsAfterFinished: 3600
								podOverrides: env: [{
									name: "GITHUB_TOKEN"
									valueFrom: secretKeyRef: {
										name: "github-pat"
										key:  "GITHUB_TOKEN"
									}
								}]
								prompt: "(filled by parameters)"
							}
						}
						// Rewrite fields on the template from the webhook payload.
						parameters: [
							{
								src: {
									dependencyName: "review-comment"
									dataKey:        "body.comment.id"
								}
								dest:      "metadata.name"
								operation: "append"
							},
							{
								src: {
									dependencyName: "review-comment"
									dataTemplate: """
										A maintainer used `/explain` on line {{ .Input.body.comment.line }} of `{{ .Input.body.comment.path }}` in PR #{{ .Input.body.pull_request.number }} ({{ .Input.body.repository.full_name }}).

										Repo:            {{ .Input.body.repository.full_name }}
										PR number:       {{ .Input.body.pull_request.number }}
										PR title:        {{ .Input.body.pull_request.title }}
										Head SHA:        {{ .Input.body.pull_request.head.sha }}
										File:            {{ .Input.body.comment.path }}
										Line:            {{ .Input.body.comment.line }}
										Comment ID:      {{ .Input.body.comment.id }}
										Comment author:  {{ .Input.body.comment.user.login }}
										Reply endpoint:  /repos/{{ .Input.body.repository.full_name }}/pulls/{{ .Input.body.pull_request.number }}/comments/{{ .Input.body.comment.id }}/replies

										The maintainer's question (from the comment body):
										{{ .Input.body.comment.body }}

										Diff hunk around the line (shows a few lines of context):
										```
										{{ .Input.body.comment.diff_hunk }}
										```

										Follow your AgentConfig instructions. Post a threaded reply at the Reply endpoint above. Stop after posting.
										"""
								}
								dest: "spec.prompt"
							},
						]
					}
				}
			}]
		}
	},
	// CI Complete + Image Ready → Sync Preview.
	// Requires BOTH CI success AND image push before triggering Argo CD sync.
	// This eliminates the image race condition.
	{
		name:      "preview-deploy"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			dependencies: [
				{
					name:            "ci-success"
					eventSourceName: "github-webhook"
					eventName:       "pr-events"
					filters: data: [
						{path: "body.state", type: "string", value: ["success"]},
						{path: "body.context", type: "string", value: ["ci/preview-build"]},
						// Require the event originate from a example-org repo.
						{path: "body.repository.full_name", type: "string", comparator: "=~", value: ["^example-org/"]},
					]
				},
				{
					name:            "image-ready"
					eventSourceName: "container-registry"
					eventName:       "image-push"
					filters: data: [
						{path: "body.repository", type: "string", comparator: "=~", value: ["^example-org/"]},
					]
				},
			]
			triggers: [{
				template: {
					conditions: "ci-success && image-ready"
					name:       "sync-preview"
					k8s: {
						operation: "create"
						source: resource: {
							apiVersion: "batch/v1"
							kind:       "Job"
							metadata: {
								generateName: "sync-preview-"
								namespace:    "argo-events"
							}
							spec: {
								template: spec: {
									serviceAccountName: "argo-events-sa"
									containers: [{
										name:  "sync"
										image: "quay.io/argoproj/argocd:v2.13.2"
										command: ["/bin/sh", "-c", #"""
											REPO_FULL=$(echo '${{.Input.body}}' | jq -r '.repository.full_name // .repository // empty')
											REPO_SLUG=$(echo "$REPO_FULL" | awk -F/ '{print $2}')
											PR_NUMBER=$(echo '${{.Input.body}}' | jq -r '.number // .pull_request.number // .pr_number // empty')
											if [ -n "$REPO_SLUG" ] && [ -n "$PR_NUMBER" ]; then
											  APP_NAME="${REPO_SLUG}-pr-${PR_NUMBER}"
											  argocd login $ARGOCD_SERVER --auth-token $ARGOCD_TOKEN --grpc-web
											  if argocd app get "$APP_NAME" >/dev/null 2>&1; then
											    argocd app sync "$APP_NAME" --force --async
											  else
											    echo "Application $APP_NAME not found — ApplicationSet may not have created it yet"
											  fi
											else
											  echo "Could not derive REPO_SLUG/PR_NUMBER from payload"
											fi
											"""#]
										env: [
											{name: "ARGOCD_SERVER", value: "argocd-server.argocd.svc.cluster.local"},
											{name: "ARGOCD_TOKEN", valueFrom: secretKeyRef: {name: "argocd-ci-token", key: "token"}},
										]
									}]
									restartPolicy: "Never"
								}
								backoffLimit: 2
							}
						}
					}
				}
			}]
		}
	},
]
