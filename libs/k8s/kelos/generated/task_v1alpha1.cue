// Code generated from CRD tasks.kelos.dev (kelos.dev/v1alpha1); DO NOT EDIT.
// Source: kubectl get crd tasks.kelos.dev -o json
// Regenerate: ./ci/scripts/gen-cue-from-crds.sh kelos.dev libs/k8s/kelos/generated
// Task is the Schema for the tasks API.
package kelos

import "time"

#Task: {
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

	// TaskSpec defines the desired state of Task.
	spec?: {
		// AgentConfigRef references an AgentConfig resource.
		agentConfigRef?: {
			// Name is the name of the AgentConfig resource.
			name!: string
			...
		}

		// Branch is the git branch this Task works on. When set, an init
		// container checks out this branch before the agent starts. The
		// controller ensures only one Task with the same Branch value
		// runs at a time for the same workspace.
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

		// DependsOn lists Task names that must succeed before this Task
		// starts.
		dependsOn?: [...string]

		// Image optionally overrides the default agent container image.
		// Custom images must implement the agent image interface
		// (see docs/agent-image-interface.md).
		image?: string

		// Model optionally overrides the default model.
		model?: string

		// PodOverrides allows customizing the agent pod configuration.
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

		// Prompt is the task prompt to send to the agent.
		prompt!: string

		// TTLSecondsAfterFinished limits the lifetime of a Task that has
		// finished
		// execution (either Succeeded or Failed). If set, the Task will
		// be
		// automatically deleted after the given number of seconds once it
		// reaches
		// a terminal phase, allowing TaskSpawner to create a new Task.
		// If this field is unset, the Task will not be automatically
		// deleted.
		// If this field is set to zero, the Task will be eligible to be
		// deleted
		// immediately after it finishes.
		ttlSecondsAfterFinished?: int & >=0

		// Type specifies the agent type (e.g., claude-code).
		type!: "claude-code" | "codex" | "gemini" | "opencode" | "cursor"

		// UpstreamRepo is the upstream repository in "owner/repo" format.
		// When set, the KELOS_UPSTREAM_REPO environment variable is
		// injected
		// into the agent container so that post-run PR capture and gh CLI
		// operations target the correct repository in fork workflows.
		upstreamRepo?: string

		// WorkspaceRef optionally references a Workspace resource for the
		// agent to work in.
		workspaceRef?: {
			// Name is the name of the Workspace resource.
			name!: string
			...
		}
		...
	}

	// TaskStatus defines the observed state of Task.
	status?: {
		// CompletionTime is when the Task completed.
		completionTime?: time.Time

		// JobName is the name of the Job created for this Task.
		jobName?: string

		// Message provides additional information about the current
		// status.
		message?: string

		// Outputs contains URLs and references produced by the agent
		// (e.g. branch names, PR URLs).
		outputs?: [...string]

		// Phase represents the current phase of the Task.
		phase?: string

		// PodName is the name of the Pod running the Task.
		podName?: string

		// Results contains structured key-value outputs produced by the
		// agent.
		results?: [string]: string

		// StartTime is when the Task started running.
		startTime?: time.Time
		...
	}
	...
}
