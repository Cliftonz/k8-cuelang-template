package home

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
			template: serviceAccountName: "argo-events-sa"
			dependencies: [{
				name:            "help-comment"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["created"]},
					{path: "body.comment.body", type: "string", value: ["^/help(\\s|$)"]},
					{path: "body.repository.full_name", type: "string", value: ["^example-org/"]},
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
									serviceAccountName: "argo-events-sa"
									restartPolicy:      "Never"
									containers: [{
										name:  "reply"
										image: "maniator/gh:v2.62.0"
										command: ["/bin/sh", "-c", "PLACEHOLDER"]
										env: [{
											name: "GH_TOKEN"
											valueFrom: secretKeyRef: {
												name: "github-app-token"
												key:  "token"
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
									COMMENT_ID='{{ printf "%.0f" .Input.body.comment.id }}'

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
			template: serviceAccountName: "argo-events-sa"
			dependencies: [{
				name:            "pr-opened"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["opened"]},
					{path: "body.pull_request.number", type: "number", comparator: ">", value: ["0"]},
					{path: "body.repository.full_name", type: "string", value: ["^example-org/"]},
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
									serviceAccountName: "argo-events-sa"
									restartPolicy:      "Never"
									containers: [{
										name:  "post"
										image: "maniator/gh:v2.62.0"
										command: ["/bin/sh", "-c", "PLACEHOLDER"]
										env: [{
											name: "GH_TOKEN"
											valueFrom: secretKeyRef: {
												name: "github-app-token"
												key:  "token"
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
			template: serviceAccountName: "argo-events-sa"
			dependencies: [{
				name:            "feature-labeled"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["labeled"]},
					{path: "body.label.name", type: "string", value: [labels.aiFeature]},
					{path: "body.issue.number", type: "number", comparator: ">", value: ["0"]},
					{path: "body.repository.full_name", type: "string", value: ["^example-org/"]},
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
								// Deterministic name per (repo, issue) so retries from
								// sensor on transient failures (quota lockup, parallel
								// deliveries) collapse to the SAME Job — K8s returns
								// AlreadyExists, sensor moves on. Without this, the
								// script's gh-api idempotency check raced and posted
								// the branch-announce comment twice.
								name:      "PLACEHOLDER_NAME"
								namespace: "argo-events"
							}
							spec: {
								template: spec: {
									serviceAccountName: "argo-events-sa"
									restartPolicy:      "Never"
									containers: [{
										name:  "create"
										image: "maniator/gh:v2.62.0"
										command: ["/bin/sh", "-c", "PLACEHOLDER"]
										env: [
											{name: "REPO", value: "PLACEHOLDER_REPO"},
											{name: "ISSUE_NUMBER", value: "PLACEHOLDER_ISSUE"},
											{name: "ISSUE_TITLE", value: "PLACEHOLDER_TITLE"},
											{name: "BRANCH_CREATED_LABEL", value: labels.branchCreated},
											{name: "AI_IMPLEMENT_LABEL", value: labels.aiImplement},
											{name: "GH_TOKEN", valueFrom: secretKeyRef: {
												name: "github-app-token"
												key:  "token"
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
									dataTemplate:   "feature-branch-create-issue-{{ .Input.body.issue.number }}"
								}
								dest: "metadata.name"
							},
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
			template: serviceAccountName: "argo-events-sa"
			dependencies: [{
				name:            "feature-comment"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["created"]},
					{path: "body.issue.labels.#.name", type: "string", value: [labels.aiFeature]},
					{path: "body.repository.full_name", type: "string", value: ["^example-org/"]},
					// Bot-loop break: skip any comment whose body starts with
					// a known bot marker. The ideator MUST prefix its replies
					// with `<!-- ai-agent -->`. Legacy markers from earlier
					// agents (branch-announce, needs-human-input) and the
					// human-resume sensor's `:unlock:` line are also excluded
					// so they don't retrigger ideation.
					{
						path: "body.comment.body"
						type: "string"
						value: ["^(<!--\\s*(ai-agent|ai-finding|ai-lead-dev-summary|needs-human-input|branch-announce|ai-bot)|:unlock:)"]
						comparator: "!="
					},
					// Pause-on-human-input: if `awaiting-human` is on the
					// issue, stay quiet until the human removes it. The
					// feature-human-resume sensor handles the unlabel event.
					{
						path: "body.issue.labels.#.name"
						type: "string"
						value: ["^awaiting-human$"]
						comparator: "!="
					},
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
								// Deterministic per (issue, comment) so sensor
								// retries on transient failures (NATS redelivery,
								// quota, RBAC blip) collapse to the SAME Task —
								// k8s returns AlreadyExists. Without this the
								// ideator was posting duplicate scoping comments
								// when the sensor retried.
								name:      "PLACEHOLDER_NAME"
								namespace: "kelos-system"
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
								agentConfigRef: name: "feature-ideator"
								ttlSecondsAfterFinished: 3600
								podOverrides: env: [{
									name: "GH_TOKEN"
									valueFrom: secretKeyRef: {
										name: "github-app-token"
										key:  "token"
									}
								}]
								prompt: "(filled by parameters)"
							}
						}
						parameters: [
							{
								src: {
									dependencyName: "feature-comment"
									// %.0f formats the comment.id as a decimal integer.
								// GitHub comment IDs have crossed 2^32 (~4.4B) and
								// argo-events parses JSON numbers as float64. Without
								// %.0f, the default render is scientific notation
								// (e.g. "4.433828475e+09") which contains '+' and is
								// rejected as a k8s resource name with
								//   "Invalid value ... must consist of lower case
								//    alphanumeric characters, '-' or '.'"
								dataTemplate: "feature-ideator-{{ .Input.body.issue.number }}-c{{ printf \"%.0f\" .Input.body.comment.id }}"
								}
								dest: "metadata.name"
							},
							{
								src: {
									dependencyName: "feature-comment"
									dataTemplate: """
									A new comment was posted on issue #{{ .Input.body.issue.number }} ({{ .Input.body.issue.title }}) in {{ .Input.body.repository.full_name }}.

									Repo:        {{ .Input.body.repository.full_name }}
									Issue:       #{{ .Input.body.issue.number }}
									Commenter:   {{ .Input.body.comment.user.login }}

									Read the FULL issue thread via `gh api repos/{{ .Input.body.repository.full_name }}/issues/{{ .Input.body.issue.number }}/comments --paginate` and the issue body via `gh issue view {{ .Input.body.issue.number }} --repo {{ .Input.body.repository.full_name }}`.

									CRITICAL — bot loop prevention:
									EVERY comment you post MUST begin with the literal first line:
									    <!-- ai-agent -->
									followed by a blank line, then your content. The webhook sensor
									filters out comments starting with that marker so your replies
									don't retrigger you. Comments without it WILL recurse.

									Follow your AgentConfig. Post ONE comment (question / proposed scope / ready-for-impl). If blocked on human, the body should be:
									    <!-- ai-agent -->
									    <!-- needs-human-input -->

									    @<author> — <your question>
									Then apply the `awaiting-human` label via `gh issue edit`.

									Stop after posting.
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

	// 3. feature-implementer: fires on `implement` label added.
	//    Spawns a Kelos Task on the repo's Workspace.
	{
		name:      "feature-implementer"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			template: serviceAccountName: "argo-events-sa"
			dependencies: [{
				name:            "implement-labeled"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["labeled"]},
					{path: "body.label.name", type: "string", value: [labels.aiImplement]},
					{path: "body.issue.number", type: "number", comparator: ">", value: ["0"]},
					// issue has branch-created label (from branch-create Sensor)
					{path: "body.issue.labels.#.name", type: "string", value: [labels.branchCreated]},
					{path: "body.repository.full_name", type: "string", value: ["^example-org/"]},
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
								// Deterministic per (repo, issue) — one
								// implementer Task per issue. Sensor retries
								// collapse to AlreadyExists; no duplicate
								// PR-write Tasks.
								name:      "PLACEHOLDER_NAME"
								namespace: "kelos-system"
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
								workspaceRef: name: "PLACEHOLDER"
								ttlSecondsAfterFinished: 7200
								podOverrides: env: [{
									name: "GH_TOKEN"
									valueFrom: secretKeyRef: {
										name: "github-app-token"
										key:  "token"
									}
								}]
								prompt: "(filled by parameters)"
							}
						}
						parameters: [
							{
								src: {
									dependencyName: "implement-labeled"
									dataTemplate:   "feature-implementer-{{ .Input.body.repository.name | lower }}-{{ .Input.body.issue.number }}"
								}
								dest: "metadata.name"
							},
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

	// 4. feature-review-panel: fires once when `pending-review` label is
	//    added to a PR. Spawns SIX panel-spawner Jobs in parallel — one
	//    per role (security, architect, qa, devops, designer, devrel).
	//
	//    Each Job:
	//      1. POSTs a fresh GitHub Check Run with name=ai-review-<role>,
	//         status=in_progress, captures CHECK_RUN_ID
	//      2. kubectl apply a Kelos Task with all env (REPO, PR_NUMBER,
	//         HEAD_SHA, BRANCH, CHECK_RUN_NAME, CHECK_RUN_ID) baked in
	//
	//    This eliminates LLM ambiguity: agents ALWAYS PATCH an existing
	//    check run by ID, never CREATE one. Earlier design had agents
	//    self-create check runs in their prompt; ~50% of the time the
	//    LLM would invent a different name (e.g., "Security Review"
	//    instead of "ai-review-security") which broke the
	//    spawn-lead-dev sensor's name filter.
	//
	//    Each agent is an ANALYST: writes findings to its check run's
	//    output.text and never posts PR/issue comments. Lead-dev reads
	//    the 6 check runs to aggregate.
	//
	//    Filter: action=labeled AND label.name=pending-review only —
	//    single canonical signal, no dup-fire from ready_for_review or
	//    other label adds.
	{
		name:      "feature-review-panel"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			template: serviceAccountName: "argo-events-sa"
			dependencies: [{
				name:            "pr-pending-review"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["labeled"]},
					{path: "body.label.name", type: "string", value: ["^\(labels.pendingReview)$"]},
					{path: "body.pull_request.number", type: "number", comparator: ">", value: ["0"]},
					{path: "body.repository.full_name", type: "string", value: ["^example-org/"]},
				]
			}]
			triggers: [for _r in [
				{role: "security", emoji: "shield"},
				{role: "architect", emoji: "triangular_ruler"},
				{role: "qa", emoji: "test_tube"},
				{role: "devops", emoji: "gear"},
				{role: "designer", emoji: "art"},
				{role: "devrel", emoji: "book"},
			] {
				template: {
					name: "spawn-review-\(_r.role)"
					k8s: {
						operation: "create"
						source: resource: {
							apiVersion: "batch/v1"
							kind:       "Job"
							metadata: {
								generateName: "panel-spawner-\(_r.role)-"
								namespace:    "kelos-system"
							}
							spec: {
								backoffLimit: 0
								template: spec: {
									restartPolicy:      "Never"
									serviceAccountName: "feature-orchestrator"
									containers: [{
										name:  "spawner"
										image: "alpine/k8s:1.31.1@sha256:dfe8c7a06c41d0b6e8757da99531f8f302e9a2687fa0155af4c4087df585c9c8"
										command: ["/bin/sh", "-c", "PLACEHOLDER"]
										env: [
											{name: "ROLE", value: _r.role},
											{name: "REPO", value: "PLACEHOLDER"},
											{name: "PR_NUMBER", value: "PLACEHOLDER"},
											{name: "HEAD_SHA", value: "PLACEHOLDER"},
											{name: "BRANCH", value: "PLACEHOLDER"},
											{name: "GH_TOKEN", valueFrom: secretKeyRef: {
												name: "github-app-token"
												key:  "token"
											}},
										]
										resources: {
											requests: {cpu: "20m", memory: "64Mi"}
											limits: {cpu: "200m", memory: "256Mi"}
										}
									}]
								}
								ttlSecondsAfterFinished: 600
							}
						}
						parameters: [
							{src: {dependencyName: "pr-pending-review", dataKey: "body.repository.full_name"}, dest: "spec.template.spec.containers.0.env.1.value"},
							{src: {dependencyName: "pr-pending-review", dataTemplate: "{{ .Input.body.pull_request.number }}"}, dest: "spec.template.spec.containers.0.env.2.value"},
							{src: {dependencyName: "pr-pending-review", dataKey: "body.pull_request.head.sha"}, dest: "spec.template.spec.containers.0.env.3.value"},
							{src: {dependencyName: "pr-pending-review", dataKey: "body.pull_request.head.ref"}, dest: "spec.template.spec.containers.0.env.4.value"},
							{src: {dependencyName: "pr-pending-review", dataTemplate: #"""
								set -eu

								# Feature flag: ConfigMap/feature-flags in kelos-system,
								# key data.review-pipeline-enabled. Default-deny: anything
								# other than the literal string "true" halts the spawn.
								# Toggling lives in clusters/home/configmap-feature-flags.yaml
								# (GitOps), or for a quick override use
								# `ci/scripts/feature-review-killswitch.sh on|off`.
								ENABLED=$(kubectl get configmap feature-flags -n kelos-system \
								  -o jsonpath='{.data.review-pipeline-enabled}' 2>/dev/null || true)
								if [ "$ENABLED" != "true" ]; then
								  echo "feature-flags.review-pipeline-enabled=$ENABLED (need 'true'); exit 0 (no spawn)"
								  exit 0
								fi

								apk add --no-cache jq >/dev/null
								if ! command -v gh >/dev/null 2>&1; then
								  wget -qO- https://github.com/cli/cli/releases/download/v2.62.0/gh_2.62.0_linux_amd64.tar.gz | tar -xz -C /tmp
								  mv /tmp/gh_2.62.0_linux_amd64/bin/gh /usr/local/bin/gh
								fi
								export GH_TOKEN

								CHECK_RUN_NAME="ai-review-${ROLE}"
								echo "creating check run $CHECK_RUN_NAME on $REPO@$HEAD_SHA ..."
								CHECK_RUN_ID=$(gh api -X POST "repos/$REPO/check-runs" \
								  -f name="$CHECK_RUN_NAME" \
								  -f head_sha="$HEAD_SHA" \
								  -f status="in_progress" \
								  -F "output[title]=${ROLE} review queued" \
								  -F "output[summary]=Spawning Kelos Task; output appears here when complete." \
								  --jq '.id')
								echo "check_run_id=$CHECK_RUN_ID"

								WORKSPACE=$(echo "$REPO" | awk -F/ '{print tolower($2)}')

								cat <<YAML | kubectl create -f -
								apiVersion: kelos.dev/v1alpha1
								kind: Task
								metadata:
								  generateName: feature-review-${ROLE}-
								  namespace: kelos-system
								  labels:
								    app.kubernetes.io/managed-by: argo-events
								    kelos.dev/role: feature-review-${ROLE}
								spec:
								  type: claude-code
								  credentials:
								    type: oauth
								    secretRef: {name: claude-code-oauth}
								  agentConfigRef: {name: feature-review-${ROLE}}
								  workspaceRef: {name: $WORKSPACE}
								  ttlSecondsAfterFinished: 3600
								  podOverrides:
								    env:
								      - name: GH_TOKEN
								        valueFrom:
								          secretKeyRef: {name: github-app-token, key: token}
								      - {name: REPO,            value: "$REPO"}
								      - {name: PR_NUMBER,       value: "$PR_NUMBER"}
								      - {name: HEAD_SHA,        value: "$HEAD_SHA"}
								      - {name: BRANCH,          value: "$BRANCH"}
								      - {name: CHECK_RUN_NAME,  value: "$CHECK_RUN_NAME"}
								      - {name: CHECK_RUN_ID,    value: "$CHECK_RUN_ID"}
								  prompt: |
								    Run the ${ROLE} review on PR #$PR_NUMBER ($REPO) at commit $HEAD_SHA.

								    A check run already exists for you (id=$CHECK_RUN_ID, name=$CHECK_RUN_NAME).
								    Do NOT create a new check run. PATCH this one as your AgentConfig
								    PROTOCOL describes. Env vars are set: REPO, PR_NUMBER, HEAD_SHA,
								    BRANCH, CHECK_RUN_NAME, CHECK_RUN_ID, GH_TOKEN (already set; gh CLI uses it directly).

								    Stop when the check run conclusion is set. No PR/issue comments.
								YAML
								echo "spawned feature-review-${ROLE} Task for PR #$PR_NUMBER"
								"""#
							}, dest: "spec.template.spec.containers.0.command.2"
							},
						]
					}
				}
			}]
		}
	},

	// 5. feature-spawn-lead-dev: fires on every `check_run.completed`
	//    GitHub event for a check run named `ai-review-*`. The trigger
	//    Job queries GitHub for all check runs on that head SHA, counts
	//    how many distinct panel roles (security/architect/qa/devops/
	//    designer/devrel) are completed. When all 6 are done AND no
	//    lead-dev is already running for the SHA, the Job spawns a
	//    lead-dev Kelos Task. Idempotency via per-SHA ConfigMap lock
	//    using `kubectl create` (atomic — second creator gets
	//    AlreadyExists and exits).
	//
	//    REQUIRES: the `Open Warren - Example Org` GitHub App must
	//    subscribe to `check_run` events (App settings → Subscribe to
	//    events → ✓ Check run). Without this subscription the
	//    check_run.completed webhook never reaches the EventSource and
	//    lead-dev never spawns.
	{
		name:      "feature-spawn-lead-dev"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			template: serviceAccountName: "argo-events-sa"
			dependencies: [{
				name:            "panel-check-completed"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["completed"]},
					{path: "body.check_run.name", type: "string", value: ["^ai-review-(security|architect|qa|devops|designer|devrel)$"]},
					{path: "body.repository.full_name", type: "string", value: ["^example-org/"]},
				]
			}]
			triggers: [{
				template: {
					name: "maybe-spawn-lead-dev"
					k8s: {
						operation: "create"
						source: resource: {
							apiVersion: "batch/v1"
							kind:       "Job"
							metadata: {
								generateName: "spawn-lead-dev-"
								namespace:    "kelos-system"
							}
							spec: {
								backoffLimit: 0
								template: spec: {
									restartPolicy:      "Never"
									serviceAccountName: "feature-orchestrator"
									containers: [{
										name:  "spawner"
										image: "alpine/k8s:1.31.1@sha256:dfe8c7a06c41d0b6e8757da99531f8f302e9a2687fa0155af4c4087df585c9c8"
										command: ["/bin/sh", "-c", "PLACEHOLDER"]
										env: [
											{name: "REPO", value: "PLACEHOLDER"},
											{name: "HEAD_SHA", value: "PLACEHOLDER"},
											{name: "GH_TOKEN", valueFrom: secretKeyRef: {
												name: "github-app-token"
												key:  "token"
											}},
										]
										resources: {
											requests: {cpu: "20m", memory: "64Mi"}
											limits: {cpu: "200m", memory: "256Mi"}
										}
									}]
								}
								ttlSecondsAfterFinished: 600
							}
						}
						parameters: [
							{src: {dependencyName: "panel-check-completed", dataKey: "body.repository.full_name"}
								dest: "spec.template.spec.containers.0.env.0.value"
							},
							{src: {dependencyName: "panel-check-completed", dataKey: "body.check_run.head_sha"}
								dest: "spec.template.spec.containers.0.env.1.value"
							},
							{src: {dependencyName: "panel-check-completed", dataTemplate: """
								set -eu

								# Feature flag (see panel-spawner for details).
								ENABLED=$(kubectl get configmap feature-flags -n kelos-system \\
								  -o jsonpath='{.data.review-pipeline-enabled}' 2>/dev/null || true)
								if [ "$ENABLED" != "true" ]; then
								  echo "feature-flags.review-pipeline-enabled=$ENABLED (need 'true'); exit 0 (no lead-dev spawn)"
								  exit 0
								fi

								apk add --no-cache jq >/dev/null
								if ! command -v gh >/dev/null 2>&1; then
								  wget -qO- https://github.com/cli/cli/releases/download/v2.62.0/gh_2.62.0_linux_amd64.tar.gz | tar -xz -C /tmp
								  mv /tmp/gh_2.62.0_linux_amd64/bin/gh /usr/local/bin/gh
								fi
								export GH_TOKEN

								# Count distinct ai-review-* check runs that are completed for this SHA.
								COMPLETED=$(gh api "repos/$REPO/commits/$HEAD_SHA/check-runs" --paginate \\
								  --jq '.check_runs[] | select(.status=="completed") | select(.name | test("^ai-review-(security|architect|qa|devops|designer|devrel)$")) | .name' \\
								  | sort -u)
								COUNT=$(echo "$COMPLETED" | grep -c .)
								echo "panel completed: $COUNT/6 ($(echo "$COMPLETED" | tr '\n' ' '))"

								if [ "$COUNT" -lt 6 ]; then
								  echo "waiting for full panel; exit"
								  exit 0
								fi

								# Idempotency: ConfigMap-based atomic lock keyed on SHA prefix (12 chars).
								# kubectl create is atomic at etcd; second creator gets AlreadyExists
								# and exits. Lock is short-lived (deleted by lead-dev when summary is posted)
								# so etcd footprint is one CM per active review cycle.
								LOCK_CM="lead-dev-lock-${HEAD_SHA:0:12}"
								if ! kubectl create configmap "$LOCK_CM" -n kelos-system \\
								  --from-literal=sha="$HEAD_SHA" 2>/dev/null
								then
								  echo "lock $LOCK_CM already present — another spawner won the race; exit"
								  exit 0
								fi
								echo "lock $LOCK_CM acquired"

								# Resolve PR number + branch from the head SHA.
								PR_INFO=$(gh api "repos/$REPO/commits/$HEAD_SHA/pulls" --jq '.[0]')
								PR_NUMBER=$(echo "$PR_INFO" | jq -r '.number')
								BRANCH=$(echo "$PR_INFO" | jq -r '.head.ref')
								if [ -z "$PR_NUMBER" ] || [ "$PR_NUMBER" = "null" ]; then
								  echo "no PR found for SHA $HEAD_SHA — abort"
								  kubectl delete configmap "$LOCK_CM" -n kelos-system
								  exit 1
								fi

								# Spawn lead-dev Kelos Task.
								WORKSPACE=$(echo "$REPO" | awk -F/ '{print tolower($2)}')
								cat <<YAML | kubectl create -f -
								apiVersion: kelos.dev/v1alpha1
								kind: Task
								metadata:
								  generateName: feature-lead-dev-pr$PR_NUMBER-
								  namespace: kelos-system
								  labels:
								    app.kubernetes.io/managed-by: argo-events
								    kelos.dev/role: feature-review-lead-dev
								spec:
								  type: claude-code
								  credentials:
								    type: oauth
								    secretRef: {name: claude-code-oauth}
								  agentConfigRef: {name: feature-review-lead-dev}
								  workspaceRef: {name: $WORKSPACE}
								  ttlSecondsAfterFinished: 7200
								  podOverrides:
								    env:
								      - name: GH_TOKEN
								        valueFrom:
								          secretKeyRef: {name: github-app-token, key: token}
								      - {name: REPO,           value: "$REPO"}
								      - {name: PR_NUMBER,      value: "$PR_NUMBER"}
								      - {name: HEAD_SHA,       value: "$HEAD_SHA"}
								      - {name: BRANCH,         value: "$BRANCH"}
								      - {name: CHECK_RUN_NAME, value: "ai-lead-dev"}
								      - {name: LOCK_CM,        value: "$LOCK_CM"}
								  prompt: |
								    Lead-dev pass on PR #$PR_NUMBER ($REPO) at commit $HEAD_SHA.

								    Step 0 (REQUIRED FIRST): create a GitHub Check Run so the PR
								    header shows you are working:
								      CHECK_RUN_ID=\\$(gh api -X POST "repos/\\$REPO/check-runs" \\\\
								        -f name="\\$CHECK_RUN_NAME" \\\\
								        -f head_sha="\\$HEAD_SHA" \\\\
								        -f status="in_progress" \\\\
								        -F "output[title]=Lead-dev aggregating panel findings" \\\\
								        -F "output[summary]=Reading 6 panel check-run outputs for PR #\\$PR_NUMBER." \\\\
								        --jq '.id')
								      export CHECK_RUN_ID

								    Then follow the PROTOCOL in your AgentConfig (feature-review-lead-dev).
								    Final action MUST release the spawn-lock so the next review
								    cycle (e.g. after a fixer push that produces a new SHA) can fire:
								      kubectl delete configmap "\\$LOCK_CM" -n kelos-system --ignore-not-found
								    Stop when summary is posted and check run conclusion is set.
								YAML
								echo "spawned lead-dev Task for PR #$PR_NUMBER at $HEAD_SHA"
								"""
							}, dest: "spec.template.spec.containers.0.command.2"
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
			template: serviceAccountName: "argo-events-sa"
			dependencies: [{
				name:            "human-unblocked"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["unlabeled"]},
					{path: "body.label.name", type: "string", value: [labels.awaitingHuman]},
					{path: "body.repository.full_name", type: "string", value: ["^example-org/"]},
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
									serviceAccountName: "argo-events-sa"
									restartPolicy:      "Never"
									containers: [{
										name:  "resume"
										image: "maniator/gh:v2.62.0"
										command: ["/bin/sh", "-c", "PLACEHOLDER"]
										env: [{
											name: "GH_TOKEN"
											valueFrom: secretKeyRef: {
												name: "github-app-token"
												key:  "token"
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

	// ──────────────────────────────────────────────────────────────────
	// example-bot/* twin sensors — same pipeline shape as the example-org
	// set above, but scoped to example-bot-owned repos (filter regex
	// `^example-bot/`) and auth'd via the `github-pat-example-bot` PAT (a
	// fine-grained PAT can only address one resource owner, so the
	// example-org GitHub App token can't reach these repos).
	//
	// Differences from the example-org twins, in one place so future
	// edits don't drift:
	//   - name suffix `-example-bot`
	//   - dependency filter `body.repository.full_name` regex
	//     `^example-bot/` instead of `^example-org/`
	//   - `secretKeyRef.name: github-pat-example-bot` with key `GITHUB_TOKEN`
	//     for clones + issue comments + PR ops (the example-org set uses
	//     `github-app-token` with key `token` everywhere).
	//   - Panel + lead-dev use `github-app-token-example-bot` with key
	//     `token` instead — only GitHub Apps can create check runs
	//     (PATs return 403 "Resource not accessible by personal access
	//     token"). The example-bot installation of the example-org App
	//     mints those tokens via a parallel refresh CronJob.
	//   - feature-review-panel-example-bot fans out 2 roles only
	//     (security, qa) — trimmed from the full 6-role example-org
	//     panel for token budget. Designer + devrel were already
	//     dropped because tandoor-recipe-mcp has no UI surface;
	//     architect + devops were dropped as second-pass cost trim.
	//     To re-expand: add roles to the panel-spawner for-loop
	//     AND to the lead-dev-spawner regex + COUNT check (all
	//     three must agree).
	//   - feature-spawn-lead-dev-example-bot waits for 2/2 panel completions
	//     (regex + COUNT both trimmed).
	//
	// The branch-create / ideator / implementer / human-resume sensors
	// in this set are NOT flag-gated and start firing the moment they
	// reconcile. The panel + lead-dev twins ARE flag-gated by the same
	// `feature-flags.review-pipeline-enabled` ConfigMap as the example-org
	// side — flipping it enables review for BOTH owner sets at once.
	// ──────────────────────────────────────────────────────────────────

	// 1. feature-branch-create-example-bot
	{
		name:      "feature-branch-create-example-bot"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			template: serviceAccountName: "argo-events-sa"
			dependencies: [{
				name:            "feature-labeled"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["labeled"]},
					{path: "body.label.name", type: "string", value: [labels.aiFeature]},
					{path: "body.issue.number", type: "number", comparator: ">", value: ["0"]},
					{path: "body.repository.full_name", type: "string", value: ["^example-bot/"]},
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
								name:      "PLACEHOLDER_NAME"
								namespace: "argo-events"
							}
							spec: {
								template: spec: {
									serviceAccountName: "argo-events-sa"
									restartPolicy:      "Never"
									containers: [{
										name:  "create"
										image: "maniator/gh:v2.62.0"
										command: ["/bin/sh", "-c", "PLACEHOLDER"]
										env: [
											{name: "REPO", value: "PLACEHOLDER_REPO"},
											{name: "ISSUE_NUMBER", value: "PLACEHOLDER_ISSUE"},
											{name: "ISSUE_TITLE", value: "PLACEHOLDER_TITLE"},
											{name: "BRANCH_CREATED_LABEL", value: labels.branchCreated},
											{name: "AI_IMPLEMENT_LABEL", value: labels.aiImplement},
											// GH_TOKEN: example-bot-scoped PAT for the actual
											// repo ops (branch create + comment on tandoor).
											{name: "GH_TOKEN", valueFrom: secretKeyRef: {
												name: "github-pat-example-bot-events"
												key:  "GITHUB_TOKEN"
											}},
											// SCRIPT_SOURCE_TOKEN: example-org PAT, used
											// ONLY to clone k8-infra for the script body
											// (example-bot PAT can't reach example-org repos).
											{name: "SCRIPT_SOURCE_TOKEN", valueFrom: secretKeyRef: {
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
									dataTemplate:   "feature-branch-create-example-bot-issue-{{ .Input.body.issue.number }}"
								}
								dest: "metadata.name"
							},
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
										# Use the example-org PAT ($SCRIPT_SOURCE_TOKEN)
										# JUST to clone the script source — example-bot
										# fine-grained PAT in $GH_TOKEN can't reach
										# example-org repos (PATs are owner-locked).
										# Clear it before exec so the child script
										# doesn't accidentally pick it up.
										git clone --depth 1 "https://x-access-token:${SCRIPT_SOURCE_TOKEN}@github.com/example-org/k8-infra.git" /tmp/infra
										unset SCRIPT_SOURCE_TOKEN
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

	// 2. feature-ideator-example-bot
	{
		name:      "feature-ideator-example-bot"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			template: serviceAccountName: "argo-events-sa"
			dependencies: [{
				name:            "feature-comment"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["created"]},
					{path: "body.issue.labels.#.name", type: "string", value: [labels.aiFeature]},
					{path: "body.repository.full_name", type: "string", value: ["^example-bot/"]},
					{
						path: "body.comment.body"
						type: "string"
						value: ["^(<!--\\s*(ai-agent|ai-finding|ai-lead-dev-summary|needs-human-input|branch-announce|ai-bot)|:unlock:)"]
						comparator: "!="
					},
					{
						path: "body.issue.labels.#.name"
						type: "string"
						value: ["^awaiting-human$"]
						comparator: "!="
					},
				]
			}]
			triggers: [{
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
								name:      "PLACEHOLDER_NAME"
								namespace: "kelos-system"
								labels: {
									"app.kubernetes.io/managed-by": "argo-events"
									"kelos.dev/role":               "feature-ideator"
									"kelos.dev/owner-scope":        "example-bot"
								}
							}
							spec: {
								type: "claude-code"
								credentials: {
									type: "oauth"
									secretRef: name: "claude-code-oauth"
								}
								agentConfigRef: name: "feature-ideator"
								ttlSecondsAfterFinished: 3600
								podOverrides: env: [{
									name: "GH_TOKEN"
									valueFrom: secretKeyRef: {
										name: "github-pat-example-bot"
										key:  "GITHUB_TOKEN"
									}
								}]
								prompt: "(filled by parameters)"
							}
						}
						parameters: [
							{
								src: {
									dependencyName: "feature-comment"
									// See comment on the example-org sibling — comment.id
								// must be formatted with %.0f to avoid scientific
								// notation rendering as the k8s name.
								dataTemplate: "feature-ideator-example-bot-{{ .Input.body.issue.number }}-c{{ printf \"%.0f\" .Input.body.comment.id }}"
								}
								dest: "metadata.name"
							},
							{
								src: {
									dependencyName: "feature-comment"
									dataTemplate: """
									A new comment was posted on issue #{{ .Input.body.issue.number }} ({{ .Input.body.issue.title }}) in {{ .Input.body.repository.full_name }}.

									Repo:        {{ .Input.body.repository.full_name }}
									Issue:       #{{ .Input.body.issue.number }}
									Commenter:   {{ .Input.body.comment.user.login }}

									Read the FULL issue thread via `gh api repos/{{ .Input.body.repository.full_name }}/issues/{{ .Input.body.issue.number }}/comments --paginate` and the issue body via `gh issue view {{ .Input.body.issue.number }} --repo {{ .Input.body.repository.full_name }}`.

									CRITICAL — bot loop prevention:
									EVERY comment you post MUST begin with the literal first line:
									    <!-- ai-agent -->
									followed by a blank line, then your content. The webhook sensor
									filters out comments starting with that marker so your replies
									don't retrigger you. Comments without it WILL recurse.

									Follow your AgentConfig. Post ONE comment (question / proposed scope / ready-for-impl). If blocked on human, the body should be:
									    <!-- ai-agent -->
									    <!-- needs-human-input -->

									    @<author> — <your question>
									Then apply the `awaiting-human` label via `gh issue edit`.

									Stop after posting.
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

	// 2b. feature-ideator-example-bot-initial — fires on the SAME
	// `ai-feature` label-add event as branch-create, so the human gets
	// both a branch AND a proposed plan on the issue in one shot. The
	// existing comment-triggered feature-ideator-example-bot handles every
	// subsequent comment for iteration. Deterministic name per issue
	// number — re-toggling the label re-fires but kubectl returns
	// AlreadyExists and the sensor moves on, so no dup planning.
	{
		name:      "feature-ideator-example-bot-initial"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			template: serviceAccountName: "argo-events-sa"
			dependencies: [{
				name:            "feature-labeled"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["labeled"]},
					{path: "body.label.name", type: "string", value: [labels.aiFeature]},
					{path: "body.issue.number", type: "number", comparator: ">", value: ["0"]},
					{path: "body.repository.full_name", type: "string", value: ["^example-bot/"]},
				]
			}]
			triggers: [{
				template: {
					name: "spawn-ideator-initial"
					k8s: {
						operation: "create"
						source: resource: {
							apiVersion: "kelos.dev/v1alpha1"
							kind:       "Task"
							metadata: {
								name:      "PLACEHOLDER_NAME"
								namespace: "kelos-system"
								labels: {
									"app.kubernetes.io/managed-by": "argo-events"
									"kelos.dev/role":               "feature-ideator"
									"kelos.dev/owner-scope":        "example-bot"
									"kelos.dev/trigger":            "initial"
								}
							}
							spec: {
								type: "claude-code"
								credentials: {
									type: "oauth"
									secretRef: name: "claude-code-oauth"
								}
								agentConfigRef: name: "feature-ideator"
								ttlSecondsAfterFinished: 3600
								podOverrides: env: [{
									name: "GH_TOKEN"
									valueFrom: secretKeyRef: {
										name: "github-pat-example-bot"
										key:  "GITHUB_TOKEN"
									}
								}]
								prompt: "(filled by parameters)"
							}
						}
						parameters: [
							{
								src: {
									dependencyName: "feature-labeled"
									dataTemplate:   "feature-ideator-example-bot-initial-{{ .Input.body.issue.number }}"
								}
								dest: "metadata.name"
							},
							{
								src: {
									dependencyName: "feature-labeled"
									dataTemplate: """
									Issue #{{ .Input.body.issue.number }} ({{ .Input.body.issue.title }}) in {{ .Input.body.repository.full_name }} was just labeled `\(labels.aiFeature)` — this is the FIRST agent run on the issue.

									Repo:      {{ .Input.body.repository.full_name }}
									Issue:     #{{ .Input.body.issue.number }}
									Title:     {{ .Input.body.issue.title }}
									Author:    {{ .Input.body.issue.user.login }}

									Read the issue body via `gh issue view {{ .Input.body.issue.number }} --repo {{ .Input.body.repository.full_name }}`. Also check any pre-existing comments via `gh api repos/{{ .Input.body.repository.full_name }}/issues/{{ .Input.body.issue.number }}/comments --paginate` (the branch-create Job posts a `<!-- branch-announce -->` comment around the same time — ignore that one; it's not human input).

									This is the kickoff pass. Decide between:
									  A. If the issue body has enough detail (scope, success criteria,
									     concrete change asked for) → post a structured PLAN.
									  B. If the issue is vague → post a numbered list of clarifying
									     questions and tag @{{ .Input.body.issue.user.login }}.

									For (A), the plan comment should follow this shape (markdown,
									around 200-400 words total):

									    <!-- ai-agent -->

									    ## Proposed plan

									    **Goal:** <one-line restatement of what the issue asks>

									    **Approach:**
									    1. <step 1>
									    2. <step 2>
									    3. <step n>

									    **Files I expect to touch:** (best guess from the repo
									    structure — read `gh api repos/.../contents` if helpful)
									    - `path/to/file.ts`
									    - …

									    **Out of scope / deferred:**
									    - <thing the issue doesn't ask for but might be tempting>

									    **Test plan:** how I'll prove this works locally (e.g.
									    `npm test`, manual flow, etc.)

									    **Open questions for @{{ .Input.body.issue.user.login }}:**
									    - <q1 if any, else "none — proceed?">

									    ---
									    Apply the `\(labels.aiImplement)` label when this looks right and I'll execute.

									CRITICAL — bot loop prevention:
									EVERY comment you post MUST begin with the literal first line:
									    <!-- ai-agent -->
									followed by a blank line, then your content. Without this marker
									the comment-triggered ideator would retrigger itself on your own
									reply.

									Stop after posting ONE comment. The subsequent feature-ideator-
									example-bot sensor handles human replies from here.
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

	// 3. feature-implementer-example-bot
	{
		name:      "feature-implementer-example-bot"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			template: serviceAccountName: "argo-events-sa"
			dependencies: [{
				name:            "implement-labeled"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["labeled"]},
					{path: "body.label.name", type: "string", value: [labels.aiImplement]},
					{path: "body.issue.number", type: "number", comparator: ">", value: ["0"]},
					{path: "body.issue.labels.#.name", type: "string", value: [labels.branchCreated]},
					{path: "body.repository.full_name", type: "string", value: ["^example-bot/"]},
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
								name:      "PLACEHOLDER_NAME"
								namespace: "kelos-system"
								labels: {
									"app.kubernetes.io/managed-by": "argo-events"
									"kelos.dev/role":               "feature-implementer"
									"kelos.dev/owner-scope":        "example-bot"
								}
							}
							spec: {
								type: "claude-code"
								credentials: {
									type: "oauth"
									secretRef: name: "claude-code-oauth"
								}
								agentConfigRef: name: "feature-implementer"
								workspaceRef: name: "PLACEHOLDER"
								ttlSecondsAfterFinished: 7200
								podOverrides: env: [{
									name: "GH_TOKEN"
									valueFrom: secretKeyRef: {
										name: "github-pat-example-bot"
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
									dataTemplate:   "feature-implementer-example-bot-{{ .Input.body.repository.name | lower }}-{{ .Input.body.issue.number }}"
								}
								dest: "metadata.name"
							},
							{
								src: {
									dependencyName: "implement-labeled"
									dataTemplate: "{{ .Input.body.repository.name | lower }}"
								}
								dest: "spec.workspaceRef.name"
							},
							{
								src: {
									dependencyName: "implement-labeled"
									dataTemplate: """
										Issue #{{ .Input.body.issue.number }} ({{ .Input.body.issue.title }}) in {{ .Input.body.repository.full_name }} was labeled `implement`.

										Read the full issue thread. Find the branch name from the `<!-- branch-announce -->` comment. Checkout that branch (NOT a new one). Implement the feature. Detect the package manager from the lockfile (npm/pnpm/bun) per your AgentConfig and run full CI locally. Push. Open draft PR. Mark ready. Apply `pending-review` label.

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

	// 4. feature-review-panel-example-bot (trimmed to 2 roles)
	{
		name:      "feature-review-panel-example-bot"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			template: serviceAccountName: "argo-events-sa"
			dependencies: [{
				name:            "pr-pending-review"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["labeled"]},
					{path: "body.label.name", type: "string", value: ["^\(labels.pendingReview)$"]},
					{path: "body.pull_request.number", type: "number", comparator: ">", value: ["0"]},
					{path: "body.repository.full_name", type: "string", value: ["^example-bot/"]},
				]
			}]
			triggers: [for _r in [
				// Trimmed for token budget. Security catches actual bugs
				// (auth, injection, secrets); QA catches missing tests +
				// edge cases. Lowest overlap with each other and with the
				// lead-dev's own implementation pass. Architect + DevOps
				// can be added back via this list when budget allows.
				{role: "security", emoji: "shield"},
				{role: "qa", emoji: "test_tube"},
			] {
				template: {
					name: "spawn-review-\(_r.role)"
					k8s: {
						operation: "create"
						source: resource: {
							apiVersion: "batch/v1"
							kind:       "Job"
							metadata: {
								generateName: "panel-spawner-example-bot-\(_r.role)-"
								namespace:    "kelos-system"
							}
							spec: {
								backoffLimit: 0
								template: spec: {
									restartPolicy:      "Never"
									serviceAccountName: "feature-orchestrator"
									containers: [{
										name:  "spawner"
										image: "alpine/k8s:1.31.1@sha256:dfe8c7a06c41d0b6e8757da99531f8f302e9a2687fa0155af4c4087df585c9c8"
										command: ["/bin/sh", "-c", "PLACEHOLDER"]
										env: [
											{name: "ROLE", value: _r.role},
											{name: "REPO", value: "PLACEHOLDER"},
											{name: "PR_NUMBER", value: "PLACEHOLDER"},
											{name: "HEAD_SHA", value: "PLACEHOLDER"},
											{name: "BRANCH", value: "PLACEHOLDER"},
											// example-bot-installation App token. Required —
											// only GitHub Apps can create check runs (the
											// PAT path returns 403 "Resource not accessible
											// by personal access token").
											{name: "GH_TOKEN", valueFrom: secretKeyRef: {
												name: "github-app-token-example-bot"
												key:  "token"
											}},
										]
										resources: {
											requests: {cpu: "20m", memory: "64Mi"}
											limits: {cpu: "200m", memory: "256Mi"}
										}
									}]
								}
								ttlSecondsAfterFinished: 600
							}
						}
						parameters: [
							{src: {dependencyName: "pr-pending-review", dataKey: "body.repository.full_name"}, dest: "spec.template.spec.containers.0.env.1.value"},
							{src: {dependencyName: "pr-pending-review", dataTemplate: "{{ .Input.body.pull_request.number }}"}, dest: "spec.template.spec.containers.0.env.2.value"},
							{src: {dependencyName: "pr-pending-review", dataKey: "body.pull_request.head.sha"}, dest: "spec.template.spec.containers.0.env.3.value"},
							{src: {dependencyName: "pr-pending-review", dataKey: "body.pull_request.head.ref"}, dest: "spec.template.spec.containers.0.env.4.value"},
							{src: {dependencyName: "pr-pending-review", dataTemplate: #"""
								set -eu

								# Feature flag (same CM as example-org side — flipping it
								# enables review for BOTH scopes at once; there is no
								# per-scope toggle today).
								ENABLED=$(kubectl get configmap feature-flags -n kelos-system \
								  -o jsonpath='{.data.review-pipeline-enabled}' 2>/dev/null || true)
								if [ "$ENABLED" != "true" ]; then
								  echo "feature-flags.review-pipeline-enabled=$ENABLED (need 'true'); exit 0 (no spawn)"
								  exit 0
								fi

								apk add --no-cache jq >/dev/null
								if ! command -v gh >/dev/null 2>&1; then
								  wget -qO- https://github.com/cli/cli/releases/download/v2.62.0/gh_2.62.0_linux_amd64.tar.gz | tar -xz -C /tmp
								  mv /tmp/gh_2.62.0_linux_amd64/bin/gh /usr/local/bin/gh
								fi
								export GH_TOKEN

								CHECK_RUN_NAME="ai-review-${ROLE}"
								echo "creating check run $CHECK_RUN_NAME on $REPO@$HEAD_SHA ..."
								CHECK_RUN_ID=$(gh api -X POST "repos/$REPO/check-runs" \
								  -f name="$CHECK_RUN_NAME" \
								  -f head_sha="$HEAD_SHA" \
								  -f status="in_progress" \
								  -F "output[title]=${ROLE} review queued" \
								  -F "output[summary]=Spawning Kelos Task; output appears here when complete." \
								  --jq '.id')
								echo "check_run_id=$CHECK_RUN_ID"

								WORKSPACE=$(echo "$REPO" | awk -F/ '{print tolower($2)}')

								cat <<YAML | kubectl create -f -
								apiVersion: kelos.dev/v1alpha1
								kind: Task
								metadata:
								  generateName: feature-review-${ROLE}-
								  namespace: kelos-system
								  labels:
								    app.kubernetes.io/managed-by: argo-events
								    kelos.dev/role: feature-review-${ROLE}
								    kelos.dev/owner-scope: example-bot
								spec:
								  type: claude-code
								  credentials:
								    type: oauth
								    secretRef: {name: claude-code-oauth}
								  agentConfigRef: {name: feature-review-${ROLE}}
								  workspaceRef: {name: $WORKSPACE}
								  ttlSecondsAfterFinished: 3600
								  podOverrides:
								    env:
								      - name: GH_TOKEN
								        valueFrom:
								          # example-bot-installation App token (PATs cannot
								          # create check runs — App-only endpoint).
								          secretKeyRef: {name: github-app-token-example-bot, key: token}
								      - {name: REPO,            value: "$REPO"}
								      - {name: PR_NUMBER,       value: "$PR_NUMBER"}
								      - {name: HEAD_SHA,        value: "$HEAD_SHA"}
								      - {name: BRANCH,          value: "$BRANCH"}
								      - {name: CHECK_RUN_NAME,  value: "$CHECK_RUN_NAME"}
								      - {name: CHECK_RUN_ID,    value: "$CHECK_RUN_ID"}
								  prompt: |
								    Run the ${ROLE} review on PR #$PR_NUMBER ($REPO) at commit $HEAD_SHA.

								    A check run already exists for you (id=$CHECK_RUN_ID, name=$CHECK_RUN_NAME).
								    Do NOT create a new check run. PATCH this one as your AgentConfig
								    PROTOCOL describes. Env vars are set: REPO, PR_NUMBER, HEAD_SHA,
								    BRANCH, CHECK_RUN_NAME, CHECK_RUN_ID, GH_TOKEN (already set; gh CLI uses it directly).

								    Stop when the check run conclusion is set. No PR/issue comments.
								YAML
								echo "spawned feature-review-${ROLE} Task for PR #$PR_NUMBER"
								"""#
							}, dest: "spec.template.spec.containers.0.command.2"
							},
						]
					}
				}
			}]
		}
	},

	// 5. feature-spawn-lead-dev-example-bot (waits for 2/2 panel)
	{
		name:      "feature-spawn-lead-dev-example-bot"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			template: serviceAccountName: "argo-events-sa"
			dependencies: [{
				name:            "panel-check-completed"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["completed"]},
					{path: "body.check_run.name", type: "string", value: ["^ai-review-(security|qa)$"]},
					{path: "body.repository.full_name", type: "string", value: ["^example-bot/"]},
				]
			}]
			triggers: [{
				template: {
					name: "maybe-spawn-lead-dev"
					k8s: {
						operation: "create"
						source: resource: {
							apiVersion: "batch/v1"
							kind:       "Job"
							metadata: {
								generateName: "spawn-lead-dev-example-bot-"
								namespace:    "kelos-system"
							}
							spec: {
								backoffLimit: 0
								template: spec: {
									restartPolicy:      "Never"
									serviceAccountName: "feature-orchestrator"
									containers: [{
										name:  "spawner"
										image: "alpine/k8s:1.31.1@sha256:dfe8c7a06c41d0b6e8757da99531f8f302e9a2687fa0155af4c4087df585c9c8"
										command: ["/bin/sh", "-c", "PLACEHOLDER"]
										env: [
											{name: "REPO", value: "PLACEHOLDER"},
											{name: "HEAD_SHA", value: "PLACEHOLDER"},
											// example-bot-installation App token. Required for
											// reading + patching check-run state.
											{name: "GH_TOKEN", valueFrom: secretKeyRef: {
												name: "github-app-token-example-bot"
												key:  "token"
											}},
										]
										resources: {
											requests: {cpu: "20m", memory: "64Mi"}
											limits: {cpu: "200m", memory: "256Mi"}
										}
									}]
								}
								ttlSecondsAfterFinished: 600
							}
						}
						parameters: [
							{src: {dependencyName: "panel-check-completed", dataKey: "body.repository.full_name"}
								dest: "spec.template.spec.containers.0.env.0.value"
							},
							{src: {dependencyName: "panel-check-completed", dataKey: "body.check_run.head_sha"}
								dest: "spec.template.spec.containers.0.env.1.value"
							},
							{src: {dependencyName: "panel-check-completed", dataTemplate: """
								set -eu

								# Feature flag (same CM as example-org side).
								ENABLED=$(kubectl get configmap feature-flags -n kelos-system \\
								  -o jsonpath='{.data.review-pipeline-enabled}' 2>/dev/null || true)
								if [ "$ENABLED" != "true" ]; then
								  echo "feature-flags.review-pipeline-enabled=$ENABLED (need 'true'); exit 0 (no lead-dev spawn)"
								  exit 0
								fi

								apk add --no-cache jq >/dev/null
								if ! command -v gh >/dev/null 2>&1; then
								  wget -qO- https://github.com/cli/cli/releases/download/v2.62.0/gh_2.62.0_linux_amd64.tar.gz | tar -xz -C /tmp
								  mv /tmp/gh_2.62.0_linux_amd64/bin/gh /usr/local/bin/gh
								fi
								export GH_TOKEN

								# Count distinct ai-review-* check runs that are completed for this SHA.
								# Trimmed panel: 2 roles (security + qa) for token
								# budget. To re-expand, edit this regex + the
								# panel-spawner role list + COUNT threshold below
								# (all three must agree or lead-dev never fires).
								COMPLETED=$(gh api "repos/$REPO/commits/$HEAD_SHA/check-runs" --paginate \\
								  --jq '.check_runs[] | select(.status=="completed") | select(.name | test("^ai-review-(security|qa)$")) | .name' \\
								  | sort -u)
								COUNT=$(echo "$COMPLETED" | grep -c .)
								echo "panel completed: $COUNT/2 ($(echo "$COMPLETED" | tr '\n' ' '))"

								if [ "$COUNT" -lt 2 ]; then
								  echo "waiting for full panel; exit"
								  exit 0
								fi

								LOCK_CM="lead-dev-lock-${HEAD_SHA:0:12}"
								if ! kubectl create configmap "$LOCK_CM" -n kelos-system \\
								  --from-literal=sha="$HEAD_SHA" 2>/dev/null
								then
								  echo "lock $LOCK_CM already present — another spawner won the race; exit"
								  exit 0
								fi
								echo "lock $LOCK_CM acquired"

								PR_INFO=$(gh api "repos/$REPO/commits/$HEAD_SHA/pulls" --jq '.[0]')
								PR_NUMBER=$(echo "$PR_INFO" | jq -r '.number')
								BRANCH=$(echo "$PR_INFO" | jq -r '.head.ref')
								if [ -z "$PR_NUMBER" ] || [ "$PR_NUMBER" = "null" ]; then
								  echo "no PR found for SHA $HEAD_SHA — abort"
								  kubectl delete configmap "$LOCK_CM" -n kelos-system
								  exit 1
								fi

								WORKSPACE=$(echo "$REPO" | awk -F/ '{print tolower($2)}')
								cat <<YAML | kubectl create -f -
								apiVersion: kelos.dev/v1alpha1
								kind: Task
								metadata:
								  generateName: feature-lead-dev-pr$PR_NUMBER-
								  namespace: kelos-system
								  labels:
								    app.kubernetes.io/managed-by: argo-events
								    kelos.dev/role: feature-review-lead-dev
								    kelos.dev/owner-scope: example-bot
								spec:
								  type: claude-code
								  credentials:
								    type: oauth
								    secretRef: {name: claude-code-oauth}
								  agentConfigRef: {name: feature-review-lead-dev}
								  workspaceRef: {name: $WORKSPACE}
								  ttlSecondsAfterFinished: 7200
								  podOverrides:
								    env:
								      - name: GH_TOKEN
								        valueFrom:
								          # example-bot-installation App token (PATs cannot
								          # create check runs — App-only endpoint).
								          secretKeyRef: {name: github-app-token-example-bot, key: token}
								      - {name: REPO,           value: "$REPO"}
								      - {name: PR_NUMBER,      value: "$PR_NUMBER"}
								      - {name: HEAD_SHA,       value: "$HEAD_SHA"}
								      - {name: BRANCH,         value: "$BRANCH"}
								      - {name: CHECK_RUN_NAME, value: "ai-lead-dev"}
								      - {name: LOCK_CM,        value: "$LOCK_CM"}
								  prompt: |
								    Lead-dev pass on PR #$PR_NUMBER ($REPO) at commit $HEAD_SHA.

								    Step 0 (REQUIRED FIRST): create a GitHub Check Run so the PR
								    header shows you are working:
								      CHECK_RUN_ID=\\$(gh api -X POST "repos/\\$REPO/check-runs" \\\\
								        -f name="\\$CHECK_RUN_NAME" \\\\
								        -f head_sha="\\$HEAD_SHA" \\\\
								        -f status="in_progress" \\\\
								        -F "output[title]=Lead-dev aggregating panel findings" \\\\
								        -F "output[summary]=Reading 2 panel check-run outputs for PR #\\$PR_NUMBER." \\\\
								        --jq '.id')
								      export CHECK_RUN_ID

								    Then follow the PROTOCOL in your AgentConfig (feature-review-lead-dev).
								    Note: trimmed panel has 2 roles (security/qa), not 6.
								    Final action MUST release the spawn-lock so the next review
								    cycle can fire:
								      kubectl delete configmap "\\$LOCK_CM" -n kelos-system --ignore-not-found
								    Stop when summary is posted and check run conclusion is set.
								YAML
								echo "spawned lead-dev Task for PR #$PR_NUMBER at $HEAD_SHA"
								"""
							}, dest: "spec.template.spec.containers.0.command.2"
							},
						]
					}
				}
			}]
		}
	},

	// 6. feature-human-resume-example-bot
	{
		name:      "feature-human-resume-example-bot"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			template: serviceAccountName: "argo-events-sa"
			dependencies: [{
				name:            "human-unblocked"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["unlabeled"]},
					{path: "body.label.name", type: "string", value: [labels.awaitingHuman]},
					{path: "body.repository.full_name", type: "string", value: ["^example-bot/"]},
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
								generateName: "feature-resume-example-bot-"
								namespace:    "argo-events"
							}
							spec: {
								template: spec: {
									serviceAccountName: "argo-events-sa"
									restartPolicy:      "Never"
									containers: [{
										name:  "resume"
										image: "maniator/gh:v2.62.0"
										command: ["/bin/sh", "-c", "PLACEHOLDER"]
										env: [{
											name: "GH_TOKEN"
											valueFrom: secretKeyRef: {
												// `-events` variant — this Job runs
												// in argo-events ns, not kelos-system.
												name: "github-pat-example-bot-events"
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
			template: serviceAccountName: "argo-events-sa"
			dependencies: [{
				name:            "review-comment"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["created"]},
					// pull_request_review_comment events carry comment.path;
					// issue_comment events do not. argo-events rejects
					// empty-string filter values, so we rely on the
					// `^/explain` body match to narrow the slash-command
					// trigger and let the sensor's prompt detect/reject
					// non-PR-review-comment payloads.
					{path: "body.comment.body", type: "string", value: ["^/explain(\\s|$)"]},
					{path: "body.repository.full_name", type: "string", value: ["^example-org/"]},
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
								agentConfigRef: name: "code-explainer"
								ttlSecondsAfterFinished: 3600
								podOverrides: env: [{
									name: "GH_TOKEN"
									valueFrom: secretKeyRef: {
										name: "github-app-token"
										key:  "token"
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
										Comment ID:      {{ printf "%.0f" .Input.body.comment.id }}
										Comment author:  {{ .Input.body.comment.user.login }}
										Reply endpoint:  /repos/{{ .Input.body.repository.full_name }}/pulls/{{ .Input.body.pull_request.number }}/comments/{{ printf "%.0f" .Input.body.comment.id }}/replies

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
			template: serviceAccountName: "argo-events-sa"
			dependencies: [
				{
					name:            "ci-success"
					eventSourceName: "github-webhook"
					eventName:       "pr-events"
					filters: data: [
						{path: "body.state", type: "string", value: ["success"]},
						{path: "body.context", type: "string", value: ["ci/preview-build"]},
						// Require the event originate from a example-org repo.
						{path: "body.repository.full_name", type: "string", value: ["^example-org/"]},
					]
				},
				{
					name:            "image-ready"
					eventSourceName: "container-registry"
					eventName:       "image-push"
					filters: data: [
						{path: "body.repository", type: "string", value: ["^example-org/"]},
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

	// ci-failure-autofix — fires on every check_run.completed event with
	// conclusion=failure (excluding ai-* check runs and the
	// "Validate PR titles" workflow per project policy). Trigger Job
	// runs ci/scripts/autofix-dispatch.sh against the failing PR's
	// head SHA. The script dedupes (prior /fix-ci comments count as
	// attempts; cap is MAX_ATTEMPTS=3) and posts a structured /fix-ci
	// PR comment listing every failed workflow run for that SHA.
	// The existing /fix-ci comment sensor (line ~~~ in this file)
	// catches the comment and spawns a ci-fixer Kelos Task.
	//
	// Per-SHA lock via ConfigMap: many check_runs land per SHA (each
	// CI job emits one). First handler wins, others see lock and exit.
	// Lock TTL via Job ttlSecondsAfterFinished + a manual delete in
	// the script's success path so subsequent SHAs (e.g. after a
	// fixer push) get a fresh attempt.
	//
	// Killswitch: same `feature-review-killswitch` ConfigMap halts
	// this flow too — the user wanted ONE off-button for all
	// AI-driven write activity.
	//
	// REQUIRES: the App must subscribe to `check_run` events (already
	// enabled — same subscription used by feature-spawn-lead-dev).
	{
		name:      "ci-failure-autofix"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			template: serviceAccountName: "argo-events-sa"
			dependencies: [{
				name:            "check-run-failed"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["completed"]},
					{path: "body.check_run.conclusion", type: "string", value: ["failure", "timed_out"]},
					{path: "body.repository.full_name", type: "string", value: ["^example-org/"]},
					// Skip our own AI check runs — fixing those is a different
					// concern and would loop. Skip the PR-title check per the
					// repo's autofix policy.
					{
						path: "body.check_run.name"
						type: "string"
						value: ["^ai-", "^Validate PR titles$"]
						comparator: "!="
					},
				]
			}]
			triggers: [{
				template: {
					name: "run-autofix-dispatch"
					k8s: {
						operation: "create"
						source: resource: {
							apiVersion: "batch/v1"
							kind:       "Job"
							metadata: {
								generateName: "ci-autofix-dispatch-"
								namespace:    "kelos-system"
							}
							spec: {
								backoffLimit: 0
								template: spec: {
									restartPolicy:      "Never"
									serviceAccountName: "feature-orchestrator"
									containers: [{
										name:  "dispatch"
										image: "alpine/k8s:1.31.1@sha256:dfe8c7a06c41d0b6e8757da99531f8f302e9a2687fa0155af4c4087df585c9c8"
										command: ["/bin/sh", "-c", "PLACEHOLDER"]
										env: [
											{name: "REPO", value: "PLACEHOLDER"},
											{name: "HEAD_SHA", value: "PLACEHOLDER"},
											{name: "GH_TOKEN", valueFrom: secretKeyRef: {
												name: "github-app-token"
												key:  "token"
											}},
										]
										resources: {
											requests: {cpu: "20m", memory: "64Mi"}
											limits: {cpu: "300m", memory: "256Mi"}
										}
									}]
								}
								ttlSecondsAfterFinished: 600
							}
						}
						parameters: [
							{src: {dependencyName: "check-run-failed", dataKey: "body.repository.full_name"}, dest: "spec.template.spec.containers.0.env.0.value"},
							{src: {dependencyName: "check-run-failed", dataKey: "body.check_run.head_sha"}, dest: "spec.template.spec.containers.0.env.1.value"},
							{src: {dependencyName: "check-run-failed", dataTemplate: #"""
								set -eu

								# Feature flag — per-repo gate. The key in ConfigMap
								# kelos-system/feature-flags is
								#   ci-autofix-enabled-<workspace>: "true"
								# where <workspace> is the lowercased repo name (the
								# second slash-separated component of $REPO, e.g.
								# example-org/Jarvy → jarvy). A repo without an explicit
								# "true" entry is treated as DISABLED — no global
								# fallback. To enable a repo:
								#   kubectl patch cm feature-flags -n kelos-system \
								#     --type merge \
								#     -p '{"data":{"ci-autofix-enabled-jarvy":"true"}}'
								WORKSPACE=$(echo "$REPO" | awk -F/ '{print tolower($2)}')
								FLAG_KEY="ci-autofix-enabled-${WORKSPACE}"
								ENABLED=$(kubectl get configmap feature-flags -n kelos-system \
								  -o jsonpath="{.data.${FLAG_KEY}}" 2>/dev/null || true)
								if [ "$ENABLED" != "true" ]; then
								  echo "feature-flags.${FLAG_KEY}=${ENABLED:-<unset>} (need 'true'); skipping dispatch"
								  exit 0
								fi

								apk add --no-cache bash git jq curl >/dev/null
								if ! command -v gh >/dev/null 2>&1; then
								  wget -qO- https://github.com/cli/cli/releases/download/v2.62.0/gh_2.62.0_linux_amd64.tar.gz | tar -xz -C /tmp
								  mv /tmp/gh_2.62.0_linux_amd64/bin/gh /usr/local/bin/gh
								fi
								if ! command -v yq >/dev/null 2>&1; then
								  wget -qO /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64"
								  chmod +x /usr/local/bin/yq
								fi
								export GH_TOKEN

								# Per-SHA lock: many check_runs land per SHA. First handler
								# proceeds, others exit. autofix-dispatch.sh has its own
								# attempt-count guard so re-running on the same SHA is safe,
								# but the lock saves CPU + GitHub API quota.
								LOCK_CM="ci-autofix-lock-${HEAD_SHA:0:12}"
								if ! kubectl create configmap "$LOCK_CM" -n kelos-system \
								  --from-literal=sha="$HEAD_SHA" 2>/dev/null
								then
								  echo "lock $LOCK_CM exists — another dispatch handled this SHA; exit"
								  exit 0
								fi
								echo "lock $LOCK_CM acquired"

								# Resolve PR for this SHA.
								PR=$(gh api "repos/$REPO/commits/$HEAD_SHA/pulls" --jq '.[0].number // empty')
								if [ -z "$PR" ]; then
								  echo "no PR for SHA $HEAD_SHA — abort"
								  kubectl delete configmap "$LOCK_CM" -n kelos-system
								  exit 0
								fi

								# Pull autofix-dispatch.sh from k8-infra HEAD. Avoids
								# rebuilding a custom image whenever the script changes.
								git clone --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/example-org/k8-infra.git" /tmp/infra
								export REPO SHA="$HEAD_SHA" PR

								# Run dispatcher: posts /fix-ci comment with failure details
								# (acts as human-readable audit trail). Comment is bot-authored,
								# so Kelos TaskSpawner /fix-ci polling won't pick it up
								# (minimumPermission: write rejects Bot type). We spawn the
								# Kelos Task directly below to bypass that.
								bash /tmp/infra/ci/scripts/autofix-dispatch.sh

								# Spawn ci-fixer Kelos Task directly. workspaceRef chooses
								# AgentConfig: salessage→ci-fixer-nextjs, k8-infra→ci-fixer-k8-infra.
								BRANCH=$(gh api "repos/$REPO/pulls/$PR" --jq '.head.ref')
								WORKSPACE=$(echo "$REPO" | awk -F/ '{print tolower($2)}')
								case "$WORKSPACE" in
								  k8-infra) AGENT_CONFIG="ci-fixer-k8-infra" ;;
								  jarvy)    AGENT_CONFIG="ci-fixer-jarvy"    ;;
								  *)        AGENT_CONFIG="ci-fixer-nextjs"   ;;
								esac

								cat <<YAML | kubectl create -f -
								apiVersion: kelos.dev/v1alpha1
								kind: Task
								metadata:
								  generateName: ci-fixer-pr${PR}-
								  namespace: kelos-system
								  labels:
								    app.kubernetes.io/managed-by: argo-events
								    kelos.dev/role: ${AGENT_CONFIG}
								spec:
								  type: claude-code
								  credentials:
								    type: oauth
								    secretRef: {name: claude-code-oauth}
								  agentConfigRef: {name: ${AGENT_CONFIG}}
								  workspaceRef: {name: ${WORKSPACE}}
								  ttlSecondsAfterFinished: 7200
								  podOverrides:
								    env:
								      # Use GH_TOKEN (not GITHUB_TOKEN) so Kelos's
								      # built-in injection from Workspace.secretRef
								      # doesn't overwrite our App-issued token.
								      - name: GH_TOKEN
								        valueFrom:
								          secretKeyRef: {name: github-app-token, key: token}
								      - {name: REPO,      value: "${REPO}"}
								      - {name: PR_NUMBER, value: "${PR}"}
								      - {name: HEAD_SHA,  value: "${SHA}"}
								      - {name: BRANCH,    value: "${BRANCH}"}
								  prompt: |
								    CI failed on PR #${PR} (${REPO}) at commit ${SHA} on branch ${BRANCH}.
								    The most recent /fix-ci comment on this PR contains the failure
								    details (workflow, job, step, command, log tail). Read it via:
								      gh pr view ${PR} --repo ${REPO} --comments --json comments \\
								        --jq '.comments | map(select(.body | startswith("/fix-ci"))) | last.body'
								    Follow the PROTOCOL in your AgentConfig.
								YAML
								echo "spawned ${AGENT_CONFIG} Task for PR #${PR} at ${SHA}"
								"""#
							}, dest: "spec.template.spec.containers.0.command.2"
							},
						]
					}
				}
			}]
		}
	},

	// preview-build → run BuildKit Workflow when a PR is labeled `preview`
	// or pushed-to while labeled. Replaces the SalesSage GHA preview-build
	// workflow: the same Dockerfile is built in-cluster by Argo Workflows
	// using a short-lived GitHub App installation token for git clone +
	// GHCR push. The Workflow itself is defined in argoworkflows.cue as
	// WorkflowTemplate/preview-build; this Sensor only instantiates it.
	//
	// Fires on: `labeled` (label just added), `synchronize` (new commit
	// pushed on a labeled PR), `opened`/`reopened` (PR opens with the
	// label already set). Filter requires that the `preview` label is
	// present on the PR — gjson's `#(name=="preview")` lookup.
	{
		name:      "preview-build"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			template: serviceAccountName: "argo-events-sa"
			dependencies: [{
				name:            "pr-preview-event"
				eventSourceName: "github-webhook"
				eventName:       "pr-events"
				filters: data: [
					{path: "body.action", type: "string", value: ["opened", "reopened", "labeled", "synchronize"]},
					// gjson array predicate: matches if any element in
					// pull_request.labels has name == "preview".
					{path: #"body.pull_request.labels.#(name=="preview").name"#, type: "string", value: ["preview"]},
					{path: "body.repository.full_name", type: "string", value: ["^example-org/"]},
				]
			}]
			triggers: [{
				template: {
					name: "submit-build-workflow"
					k8s: {
						operation: "create"
						source: resource: {
							apiVersion: "argoproj.io/v1alpha1"
							kind:       "Workflow"
							metadata: {
								generateName: "preview-build-"
								namespace:    "argo-workflows"
								labels: {
									"app.kubernetes.io/managed-by": "argo-events"
									"k8-infra/role":                "preview-build"
								}
							}
							spec: {
								workflowTemplateRef: name: "preview-build"
								arguments: parameters: [
									{name: "owner", value:    "PLACEHOLDER"},
									{name: "repo", value:     "PLACEHOLDER"},
									{name: "slug", value:     "PLACEHOLDER"},
									{name: "sha", value:      "PLACEHOLDER"},
									{name: "prNumber", value: "PLACEHOLDER"},
								]
							}
						}
						parameters: [
							{
								src: {
									dependencyName: "pr-preview-event"
									dataKey:        "body.repository.owner.login"
								}
								dest: "spec.arguments.parameters.0.value"
							},
							{
								src: {
									dependencyName: "pr-preview-event"
									dataKey:        "body.repository.name"
								}
								dest: "spec.arguments.parameters.1.value"
							},
							{
								// slug = lowercase(repo name). Argo Events
								// templating uses sprig.
								src: {
									dependencyName: "pr-preview-event"
									dataTemplate:   #"{{ .Input.body.repository.name | lower }}"#
								}
								dest: "spec.arguments.parameters.2.value"
							},
							{
								src: {
									dependencyName: "pr-preview-event"
									dataKey:        "body.pull_request.head.sha"
								}
								dest: "spec.arguments.parameters.3.value"
							},
							{
								// gjson decodes JSON ints as float64; %.0f
								// strips the .0 so the prNumber is "182" not
								// "182.000000".
								src: {
									dependencyName: "pr-preview-event"
									dataTemplate:   #"{{ printf "%.0f" .Input.body.pull_request.number }}"#
								}
								dest: "spec.arguments.parameters.4.value"
							},
						]
					}
				}
			}]
		}
	},
]
