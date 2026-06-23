// Code generated from CRD taskspawners.kelos.dev (kelos.dev/v1alpha1); DO NOT EDIT.
// Source: kubectl get crd taskspawners.kelos.dev -o json
// Regenerate: ./ci/scripts/gen-cue-from-crds.sh kelos.dev libs/k8s/kelos/generated
// TaskSpawner is the Schema for the taskspawners API.
package kelos

import (
	"time"
	"strings"
)

#TaskSpawner: {
	// APIVersion defines the versioned schema of this representation
	// of an object.
	// Servers should convert recognized schemas to the latest
	// internal value, and
	// may reject unrecognized values.
	// More info:
	// https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
	apiVersion?: string

	// Kind is a string value representing the REST resource this
	// object represents.
	// Servers may infer this from the endpoint the client submits
	// requests to.
	// Cannot be updated.
	// In CamelCase.
	// More info:
	// https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
	kind?: string
	metadata?: {
		...
	}

	// TaskSpawnerSpec defines the desired state of TaskSpawner.
	spec?: {
		// MaxConcurrency limits the number of concurrently running
		// (non-terminal) Tasks.
		// When the limit is reached, the spawner skips creating new Tasks
		// until
		// existing ones complete. If unset or zero, there is no
		// concurrency limit.
		maxConcurrency?: int & >=0

		// MaxTotalTasks limits the total number of Tasks this spawner
		// will create
		// over its lifetime. Once reached, the spawner stops creating new
		// Tasks
		// (but continues polling to update status). If unset or zero,
		// there is
		// no limit. This counter persists across spawner restarts via
		// status.totalTasksCreated.
		maxTotalTasks?: int & >=0

		// PollInterval is how often to poll the source for new items
		// (e.g., "5m"). Defaults to "5m".
		// Deprecated: use per-source pollInterval (e.g.,
		// spec.when.githubIssues.pollInterval) instead.
		pollInterval?: string

		// Suspend tells the spawner to stop polling and creating tasks.
		// Existing running Tasks are not affected (they continue to
		// completion).
		// When set back to false, the spawner resumes from where it left
		// off.
		// Defaults to false.
		suspend?: bool

		// TaskTemplate defines the template for spawned Tasks.
		taskTemplate!: {
			// AgentConfigRef references an AgentConfig resource.
			// When set, spawned Tasks inherit this agent config reference.
			agentConfigRef?: {
				// Name is the name of the AgentConfig resource.
				name!: string
				...
			}

			// Branch is the git branch spawned Tasks should work on.
			// Supports Go text/template variables from the work item, e.g.
			// "kelos-task-{{.Number}}".
			// Available variables (all sources): {{.ID}}, {{.Title}},
			// {{.Kind}}
			// GitHub issue/Jira sources: {{.Number}}, {{.Body}}, {{.URL}},
			// {{.Labels}}, {{.Comments}}
			// GitHub pull request sources additionally expose: {{.Branch}},
			// {{.ReviewState}}, {{.ReviewComments}}
			// GitHub webhook sources: {{.Event}}, {{.Action}}, {{.Sender}},
			// {{.Ref}}, {{.Repository}}, {{.Payload}} (full payload access)
			// Linear webhook sources: {{.Type}}, {{.Action}}, {{.State}},
			// {{.Labels}}, {{.IssueID}}, {{.Payload}}
			// Cron sources: {{.Time}}, {{.Schedule}}
			branch?: string

			// Credentials specifies how to authenticate with the agent.
			credentials!: {
				// SecretRef references the Secret containing credentials.
				// Required for api-key and oauth types. Not used with none.
				secretRef?: {
					// Name is the name of the secret.
					name!: string
					...
				}

				// Type specifies the credential type.
				type!: "api-key" | "oauth" | "none"
				...
			}

			// DependsOn lists Task names that spawned Tasks depend on.
			dependsOn?: [...string]

			// Image optionally overrides the default agent container image.
			// Custom images must implement the agent image interface
			// (see docs/agent-image-interface.md).
			image?: string

			// Metadata holds optional labels and annotations for spawned
			// Tasks.
			metadata?: {
				// Annotations are merged into the spawned Task's annotations.
				// Values
				// support Go text/template with the same variables as branch and
				// promptTemplate. Values from the GitHub source (e.g.
				// kelos.dev/source-kind)
				// are applied after rendering and override reserved keys on
				// conflict.
				annotations?: [string]: string

				// Labels are merged into the spawned Task's labels. Values
				// support Go
				// text/template with the same variables as branch and
				// promptTemplate.
				// The kelos.dev/taskspawner label is always set to the
				// TaskSpawner name
				// and overrides any user value for that key.
				labels?: [string]: string
				...
			}

			// Model optionally overrides the default model.
			model?: string

			// PodOverrides allows customizing the agent pod configuration for
			// spawned Tasks.
			podOverrides?: {
				// ActiveDeadlineSeconds specifies the maximum duration in seconds
				// that the agent pod can run before being terminated.
				// This is set on the Job's activeDeadlineSeconds field.
				activeDeadlineSeconds?: int & >=1

				// Env specifies additional environment variables for the agent
				// container.
				// These are appended after the built-in env vars (credentials,
				// model, GitHub token).
				// If a user-specified env var conflicts with a built-in one, the
				// built-in takes precedence.
				env?: [...{
					// Name of the environment variable.
					// May consist of any printable ASCII characters except '='.
					name!: string

					// Variable references $(VAR_NAME) are expanded
					// using the previously defined environment variables in the
					// container and
					// any service environment variables. If a variable cannot be
					// resolved,
					// the reference in the input string will be unchanged. Double $$
					// are reduced
					// to a single $, which allows for escaping the $(VAR_NAME)
					// syntax: i.e.
					// "$$(VAR_NAME)" will produce the string literal "$(VAR_NAME)".
					// Escaped references will never be expanded, regardless of
					// whether the variable
					// exists or not.
					// Defaults to "".
					value?: string

					// Source for the environment variable's value. Cannot be used if
					// value is not empty.
					valueFrom?: {
						// Selects a key of a ConfigMap.
						configMapKeyRef?: {
							// The key to select.
							key!: string

							// Name of the referent.
							// This field is effectively required, but due to backwards
							// compatibility is
							// allowed to be empty. Instances of this type with an empty value
							// here are
							// almost certainly wrong.
							// More info:
							// https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
							name?: string

							// Specify whether the ConfigMap or its key must be defined
							optional?: bool
							...
						}

						// Selects a field of the pod: supports metadata.name,
						// metadata.namespace, `metadata.labels['<KEY>']`,
						// `metadata.annotations['<KEY>']`,
						// spec.nodeName, spec.serviceAccountName, status.hostIP,
						// status.podIP, status.podIPs.
						fieldRef?: {
							// Version of the schema the FieldPath is written in terms of,
							// defaults to "v1".
							apiVersion?: string

							// Path of the field to select in the specified API version.
							fieldPath!: string
							...
						}

						// FileKeyRef selects a key of the env file.
						// Requires the EnvFiles feature gate to be enabled.
						fileKeyRef?: {
							// The key within the env file. An invalid key will prevent the
							// pod from starting.
							// The keys defined within a source may consist of any printable
							// ASCII characters except '='.
							// During Alpha stage of the EnvFiles feature gate, the key size
							// is limited to 128 characters.
							key!: string

							// Specify whether the file or its key must be defined. If the
							// file or key
							// does not exist, then the env var is not published.
							// If optional is set to true and the specified key does not
							// exist,
							// the environment variable will not be set in the Pod's
							// containers.
							//
							// If optional is set to false and the specified key does not
							// exist,
							// an error will be returned during Pod creation.
							optional?: bool

							// The path within the volume from which to select the file.
							// Must be relative and may not contain the '..' path or start
							// with '..'.
							path!: string

							// The name of the volume mount containing the env file.
							volumeName!: string
							...
						}

						// Selects a resource of the container: only resources limits and
						// requests
						// (limits.cpu, limits.memory, limits.ephemeral-storage,
						// requests.cpu, requests.memory and requests.ephemeral-storage)
						// are currently supported.
						resourceFieldRef?: {
							// Container name: required for volumes, optional for env vars
							containerName?: string

							// Specifies the output format of the exposed resources, defaults
							// to "1"
							divisor?: matchN(>=1, [int, string]) & (number | =~"^(\\+|-)?(([0-9]+(\\.[0-9]*)?)|(\\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\\+|-)?(([0-9]+(\\.[0-9]*)?)|(\\.[0-9]+))))?$")

							// Required: resource to select
							resource!: string
							...
						}

						// Selects a key of a secret in the pod's namespace
						secretKeyRef?: {
							// The key of the secret to select from. Must be a valid secret
							// key.
							key!: string

							// Name of the referent.
							// This field is effectively required, but due to backwards
							// compatibility is
							// allowed to be empty. Instances of this type with an empty value
							// here are
							// almost certainly wrong.
							// More info:
							// https://kubernetes.io/docs/concepts/overview/working-with-objects/names/#names
							name?: string

							// Specify whether the Secret or its key must be defined
							optional?: bool
							...
						}
						...
					}
					...
				}]

				// Labels specifies additional labels to apply to the Job and its
				// Pod.
				// These are merged with the built-in labels. If a user-specified
				// label
				// conflicts with a built-in one, the built-in takes precedence.
				labels?: [string]: string

				// NodeSelector constrains agent pods to nodes matching the given
				// labels.
				nodeSelector?: [string]: string

				// Resources defines resource limits and requests for the agent
				// container.
				resources?: {
					// Claims lists the names of resources, defined in
					// spec.resourceClaims,
					// that are used by this container.
					//
					// This field depends on the
					// DynamicResourceAllocation feature gate.
					//
					// This field is immutable. It can only be set for containers.
					claims?: [...{
						// Name must match the name of one entry in
						// pod.spec.resourceClaims of
						// the Pod where this field is used. It makes that resource
						// available
						// inside a container.
						name!: string

						// Request is the name chosen for a request in the referenced
						// claim.
						// If empty, everything from the claim is made available,
						// otherwise
						// only the result of this request.
						request?: string
						...
					}]

					// Limits describes the maximum amount of compute resources
					// allowed.
					// More info:
					// https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
					limits?: [string]: matchN(>=1, [int, string]) & (number | =~"^(\\+|-)?(([0-9]+(\\.[0-9]*)?)|(\\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\\+|-)?(([0-9]+(\\.[0-9]*)?)|(\\.[0-9]+))))?$")

					// Requests describes the minimum amount of compute resources
					// required.
					// If Requests is omitted for a container, it defaults to Limits
					// if that is explicitly specified,
					// otherwise to an implementation-defined value. Requests cannot
					// exceed Limits.
					// More info:
					// https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
					requests?: [string]: matchN(>=1, [int, string]) & (number | =~"^(\\+|-)?(([0-9]+(\\.[0-9]*)?)|(\\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\\+|-)?(([0-9]+(\\.[0-9]*)?)|(\\.[0-9]+))))?$")
					...
				}

				// ServiceAccountName sets the pod's service account.
				// Use with workload identity systems such as IRSA on EKS, GKE
				// Workload Identity, or Azure Workload Identity.
				serviceAccountName?: string
				...
			}

			// PromptTemplate is a Go text/template for rendering the task
			// prompt.
			// Available variables (all sources): {{.ID}}, {{.Title}},
			// {{.Kind}}
			// GitHub issue/Jira sources: {{.Number}}, {{.Body}}, {{.URL}},
			// {{.Labels}}, {{.Comments}}
			// GitHub pull request sources additionally expose: {{.Branch}},
			// {{.ReviewState}}, {{.ReviewComments}}
			// GitHub webhook sources: {{.Event}}, {{.Action}}, {{.Sender}},
			// {{.Ref}}, {{.Repository}}, {{.Payload}} (full payload access)
			// Linear webhook sources: {{.Type}}, {{.Action}}, {{.State}},
			// {{.Labels}}, {{.IssueID}}, {{.Payload}}
			// Cron sources: {{.Time}}, {{.Schedule}}
			promptTemplate?: string

			// TTLSecondsAfterFinished limits the lifetime of a Task that has
			// finished
			// execution (either Succeeded or Failed). If set, spawned Tasks
			// will be
			// automatically deleted after the given number of seconds once
			// they reach
			// a terminal phase, allowing TaskSpawner to create a new Task.
			// If this field is unset, spawned Tasks will not be automatically
			// deleted.
			// If this field is set to zero, spawned Tasks will be eligible to
			// be deleted
			// immediately after they finish.
			ttlSecondsAfterFinished?: int & >=0

			// Type specifies the agent type (e.g., claude-code).
			type!: "claude-code" | "codex" | "gemini" | "opencode" | "cursor"

			// UpstreamRepo is the upstream repository in "owner/repo" format.
			// When set, spawned Tasks inherit this value and inject
			// KELOS_UPSTREAM_REPO into the agent container. This is typically
			// derived automatically from githubIssues.repo or
			// githubPullRequests.repo by the spawner, but can be set
			// explicitly.
			upstreamRepo?: string

			// WorkspaceRef references the Workspace that defines the
			// repository.
			// Required when using githubIssues or githubPullRequests source;
			// optional
			// for other sources.
			// When set, spawned Tasks inherit this workspace reference.
			workspaceRef?: {
				// Name is the name of the Workspace resource.
				name!: string
				...
			}
			...
		}

		// When defines the conditions that trigger task spawning.
		when!: {
			// Cron triggers task spawning on a cron schedule.
			cron?: {
				// Schedule is a cron expression (e.g., "0 9 * * 1" for every
				// Monday at 9am).
				schedule!: string
				...
			}

			// GitHubIssues discovers issues from a GitHub repository.
			githubIssues?: {
				// Assignee filters issues by assignee username. Use "*" for
				// issues with
				// any assignee, or "none" for issues with no assignee. When
				// empty, no
				// assignee filtering is applied (server-side via GitHub API).
				assignee?: string

				// Author filters issues by the username of the user who created
				// them
				// (server-side via GitHub API's "creator" parameter). When empty,
				// no
				// author filtering is applied.
				author?: string

				// CommentPolicy configures comment-based workflow control and
				// authorization.
				commentPolicy?: {
					// AllowedTeams restricts comment control to specific GitHub teams
					// in
					// org/team-slug format.
					allowedTeams?: [...=~"^[^/]+/[^/]+$"]

					// AllowedUsers restricts comment control to specific GitHub
					// usernames.
					allowedUsers?: [...string]

					// ExcludeComments blocks items whose most recent matching command
					// is an
					// exclude command. When combined with TriggerComment, the most
					// recent
					// matching command wins.
					excludeComments?: [...string]

					// MinimumPermission restricts comment control to users with at
					// least the
					// given repository permission.
					minimumPermission?: "read" | "triage" | "write" | "maintain" | "admin"

					// TriggerComment requires a matching command for the item to be
					// included.
					// When set alone, only items with a matching command are
					// discovered.
					triggerComment?: string
					...
				}

				// ExcludeAuthors filters out issues created by any of these
				// usernames
				// (client-side). When empty, no author exclusion is applied.
				excludeAuthors?: [...string]

				// ExcludeComments enables comment-based exclusion. When set,
				// issues
				// whose most recent matching comment is an ExcludeComment are
				// excluded.
				// When combined with TriggerComment, the most recent matching
				// command
				// wins — a TriggerComment after an ExcludeComment re-enables the
				// issue.
				// Deprecated: use CommentPolicy.ExcludeComments instead.
				excludeComments?: [...string]

				// ExcludeLabels filters out issues that have any of these labels
				// (client-side).
				excludeLabels?: [...string]

				// Labels filters issues by labels.
				labels?: [...string]

				// PollInterval overrides spec.pollInterval for this source (e.g.,
				// "30s", "5m").
				// When empty, spec.pollInterval is used.
				pollInterval?: string

				// PriorityLabels defines a label-based priority order for
				// discovered items.
				// When maxConcurrency limits how many tasks are created per
				// cycle,
				// items are sorted by the first matching label before task
				// creation.
				// Index 0 is the highest priority. Items without a matching label
				// are scheduled last. When empty, items are processed in
				// discovery order.
				priorityLabels?: [...string]

				// Repo optionally overrides the repository to poll for issues, in
				// "owner/repo" format or as a full URL. When empty, the
				// repository
				// is derived from the workspace repo URL in
				// taskTemplate.workspaceRef.
				// Use this for fork workflows where the workspace points to a
				// fork
				// but issues should be discovered from the upstream repository.
				repo?: string

				// Reporting configures status reporting back to the originating
				// GitHub issue.
				reporting?: {
					// Enabled posts standard status comments back to the originating
					// GitHub issue or PR.
					enabled?: bool
					...
				}

				// State filters issues by state (open, closed, all). Defaults to
				// open.
				state?: "open" | "closed" | "all"

				// TriggerComment requires a matching comment for the issue to be
				// included. When set alone, only issues with a matching comment
				// are
				// discovered. When set together with ExcludeComments, the most
				// recent
				// matching command wins (scanned in reverse chronological order).
				// Deprecated: use CommentPolicy.TriggerComment instead.
				triggerComment?: string

				// Types specifies which item types to discover: "issues",
				// "pulls", or both.
				types?: [...string]
				...
			}

			// GitHubPullRequests discovers pull requests from a GitHub
			// repository.
			githubPullRequests?: {
				// Author filters pull requests by the username of the user who
				// opened them.
				// When empty, no author filtering is applied.
				author?: string

				// CommentPolicy configures comment-based workflow control and
				// authorization.
				commentPolicy?: {
					// AllowedTeams restricts comment control to specific GitHub teams
					// in
					// org/team-slug format.
					allowedTeams?: [...=~"^[^/]+/[^/]+$"]

					// AllowedUsers restricts comment control to specific GitHub
					// usernames.
					allowedUsers?: [...string]

					// ExcludeComments blocks items whose most recent matching command
					// is an
					// exclude command. When combined with TriggerComment, the most
					// recent
					// matching command wins.
					excludeComments?: [...string]

					// MinimumPermission restricts comment control to users with at
					// least the
					// given repository permission.
					minimumPermission?: "read" | "triage" | "write" | "maintain" | "admin"

					// TriggerComment requires a matching command for the item to be
					// included.
					// When set alone, only items with a matching command are
					// discovered.
					triggerComment?: string
					...
				}

				// Draft filters pull requests by draft state. When unset, both
				// draft and
				// ready-for-review pull requests are included.
				draft?: bool

				// ExcludeAuthors filters out pull requests opened by any of these
				// usernames
				// (client-side). When empty, no author exclusion is applied.
				excludeAuthors?: [...string]

				// ExcludeComments enables comment-based exclusion. When set, PRs
				// whose most recent matching comment is an ExcludeComment are
				// excluded.
				// When combined with TriggerComment, the most recent matching
				// command
				// wins — a TriggerComment after an ExcludeComment re-enables the
				// PR.
				// Deprecated: use CommentPolicy.ExcludeComments instead.
				excludeComments?: [...string]

				// ExcludeLabels filters out pull requests that have any of these
				// labels (client-side).
				excludeLabels?: [...string]

				// Labels filters pull requests by labels.
				labels?: [...string]

				// PollInterval overrides spec.pollInterval for this source (e.g.,
				// "30s", "5m").
				// When empty, spec.pollInterval is used.
				pollInterval?: string

				// PriorityLabels defines a label-based priority order for
				// discovered items.
				// When maxConcurrency limits how many tasks are created per
				// cycle,
				// items are sorted by the first matching label before task
				// creation.
				// Index 0 is the highest priority. Items without a matching label
				// are scheduled last. When empty, items are processed in
				// discovery order.
				priorityLabels?: [...string]

				// Repo optionally overrides the repository to poll for pull
				// requests, in
				// "owner/repo" format or as a full URL. When empty, the
				// repository
				// is derived from the workspace repo URL in
				// taskTemplate.workspaceRef.
				// Use this for fork workflows where the workspace points to a
				// fork
				// but pull requests should be discovered from the upstream
				// repository.
				repo?: string

				// Reporting configures status reporting back to the originating
				// GitHub pull request.
				reporting?: {
					// Enabled posts standard status comments back to the originating
					// GitHub issue or PR.
					enabled?: bool
					...
				}

				// ReviewState filters pull requests by aggregated review state.
				// The most
				// recent APPROVED or CHANGES_REQUESTED review from each reviewer
				// on the
				// current head SHA is considered. When set to "any", review state
				// does not
				// gate discovery.
				reviewState?: "approved" | "changes_requested" | "any"

				// State filters pull requests by state (open, closed, all).
				// Defaults to open.
				state?: "open" | "closed" | "all"

				// TriggerComment requires a matching comment for the pull request
				// to be
				// included. When set alone, only PRs with a matching comment are
				// discovered. When set together with ExcludeComments, the most
				// recent
				// matching command wins based on comment timestamps.
				// Deprecated: use CommentPolicy.TriggerComment instead.
				triggerComment?: string
				...
			}

			// GitHubWebhook triggers task spawning on GitHub webhook events.
			githubWebhook?: {
				// Events is the list of GitHub event types to listen for.
				// e.g., "issue_comment", "pull_request_review", "push", "issues"
				events!: [...string] & [_, ...]

				// ExcludeAuthors excludes webhook events sent by any of these
				// usernames.
				// This is applied before filter evaluation and takes precedence
				// over
				// filter-level Author matches.
				excludeAuthors?: [...string]

				// Filters refine which events trigger tasks. If multiple filters
				// match
				// the same event type, any match triggers a task (OR semantics).
				// If empty, all events in the Events list trigger tasks.
				filters?: [...{
					// Action filters by webhook action (e.g., "created", "opened",
					// "submitted").
					action?: string

					// Author filters by the event sender's username.
					author?: string

					// BodyContains filters by substring match on the comment/review
					// body.
					bodyContains?: string

					// Branch filters push events by branch name (exact match or
					// glob).
					branch?: string

					// Draft filters PRs by draft status. nil = don't filter.
					draft?: bool

					// Event is the GitHub event type this filter applies to.
					event!: string

					// ExcludeAuthors excludes events sent by any of these usernames.
					excludeAuthors?: [...string]

					// ExcludeLabels excludes issues/PRs with any of these labels.
					excludeLabels?: [...string]

					// Labels requires the issue/PR to have all of these labels.
					labels?: [...string]

					// State filters by issue/PR state ("open", "closed").
					state?: string
					...
				}]

				// Repository restricts webhooks to a specific repository
				// (owner/repo format).
				// If empty, webhooks from any repository are accepted.
				repository?: string
				...
			}

			// Jira discovers issues from a Jira project.
			jira?: {
				// BaseURL is the Jira instance URL (e.g.,
				// "https://mycompany.atlassian.net").
				baseUrl!: =~"^https?://.+"

				// JQL is an optional JQL filter appended to the default query.
				// When set, the full query is: "project = <project> AND (<jql>)".
				// When empty, all issues in the project are discovered.
				jql?: string

				// PollInterval overrides spec.pollInterval for this source (e.g.,
				// "30s", "5m").
				// When empty, spec.pollInterval is used.
				pollInterval?: string

				// Project is the Jira project key (e.g., "PROJ").
				project!: string

				// SecretRef references a Secret containing a "JIRA_TOKEN" key
				// (required)
				// and an optional "JIRA_USER" key. When "JIRA_USER" is present,
				// Basic
				// auth is used (Jira Cloud). When absent, Bearer token auth is
				// used
				// (Jira Data Center/Server PAT).
				secretRef!: {
					// Name is the name of the secret.
					name!: string
					...
				}
				...
			}

			// LinearWebhook triggers task spawning on Linear webhook events.
			linearWebhook?: {
				// Filters refine which events trigger tasks (OR semantics within
				// same type).
				// If empty, all events in the Types list trigger tasks.
				filters?: [...{
					// Action filters by webhook action ("create", "update",
					// "remove").
					action?: "create" | "update" | "remove" | ""

					// ExcludeLabels excludes issues with any of these labels.
					excludeLabels?: [...string]

					// Labels requires the issue to have all of these labels.
					labels?: [...string]

					// States filters by Linear workflow state names (e.g., "Todo",
					// "In Progress").
					states?: [...string]

					// Type scopes this filter to a specific Linear resource type
					// (e.g., "Issue",
					// "Comment"). When empty, the filter applies to all types in the
					// parent Types list.
					type?: string
					...
				}]

				// Types is the list of Linear resource types to listen for.
				// e.g., "Issue", "Comment", "Project"
				types!: [...string] & [_, ...]
				...
			}
			...
		}
		...
	}

	// TaskSpawnerStatus defines the observed state of TaskSpawner.
	status?: {
		// ActiveTasks is the number of currently active (non-terminal)
		// Tasks.
		activeTasks?: int

		// Conditions provides detailed status information.
		conditions?: [...{
			// lastTransitionTime is the last time the condition transitioned
			// from one status to another.
			// This should be when the underlying condition changed. If that
			// is not known, then using the time when the API field changed
			// is acceptable.
			lastTransitionTime!: time.Time

			// message is a human readable message indicating details about
			// the transition.
			// This may be an empty string.
			message!: strings.MaxRunes(32768)

			// observedGeneration represents the .metadata.generation that the
			// condition was set based upon.
			// For instance, if .metadata.generation is currently 12, but the
			// .status.conditions[x].observedGeneration is 9, the condition
			// is out of date
			// with respect to the current state of the instance.
			observedGeneration?: int & >=0

			// reason contains a programmatic identifier indicating the reason
			// for the condition's last transition.
			// Producers of specific condition types may define expected
			// values and meanings for this field,
			// and whether the values are considered a guaranteed API.
			// The value should be a CamelCase string.
			// This field may not be empty.
			reason!: strings.MaxRunes(1024) & strings.MinRunes(1) & =~"^[A-Za-z]([A-Za-z0-9_,:]*[A-Za-z0-9_])?$"

			// status of the condition, one of True, False, Unknown.
			status!: "True" | "False" | "Unknown"

			// type of condition in CamelCase or in foo.example.com/CamelCase.
			type!: strings.MaxRunes(316) & =~"^([a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*/)?(([A-Za-z0-9][-A-Za-z0-9_.]*)?[A-Za-z0-9])$"
			...
		}]

		// CronJobName is the name of the CronJob running the spawner.
		// Set for cron-based sources.
		cronJobName?: string

		// DeploymentName is the name of the Deployment running the
		// spawner.
		// Set for polling-based sources (GitHub Issues, Jira).
		deploymentName?: string

		// LastDiscoveryTime is the last time the source was polled.
		lastDiscoveryTime?: time.Time

		// Message provides additional information about the current
		// status.
		message?: string

		// Phase represents the current phase of the TaskSpawner.
		phase?: string

		// TotalDiscovered is the total number of work items discovered.
		totalDiscovered?: int

		// TotalTasksCreated is the total number of Tasks created.
		totalTasksCreated?: int
		...
	}
	...
}
