// Code generated from CRD workspaces.kelos.dev (kelos.dev/v1alpha1); DO NOT EDIT.
// Source: kubectl get crd workspaces.kelos.dev -o json
// Regenerate: ./ci/scripts/gen-cue-from-crds.sh kelos.dev libs/k8s/kelos/generated
// Workspace is the Schema for the workspaces API.
package kelos

import "strings"

#Workspace: {
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

	// WorkspaceSpec defines the desired state of Workspace.
	spec?: {
		// Files are written into the cloned repository before the agent
		// starts.
		// This can be used to inject plugin-like assets such as skills
		// (for example, ".claude/skills/<name>/SKILL.md") and instruction
		// files
		// like "CLAUDE.md" or "AGENTS.md".
		files?: [...{
			// Content is the file content to write.
			content!: string

			// Path is the relative file path inside the repository (for
			// example,
			// ".claude/skills/reviewer/SKILL.md" or "CLAUDE.md").
			path!: strings.MinRunes(1)
			...
		}]

		// Ref is the git reference to checkout (branch, tag, or commit
		// SHA).
		// Defaults to the repository's default branch if not specified.
		ref?: string

		// Remotes are additional git remotes to configure after cloning.
		// The credential from SecretRef applies to all remotes.
		remotes?: [...{
			// Name is the git remote name (must not be "origin").
			name!: strings.MinRunes(1)

			// URL is the git remote URL.
			url!: =~"^(https?://|git://|git@).*"
			...
		}]

		// Repo is the git repository URL to clone.
		repo!: =~"^(https?://|git://|git@).*"

		// SecretRef references a Secret containing a GITHUB_TOKEN key for
		// git
		// authentication and GitHub CLI (gh) operations.
		secretRef?: {
			// Name is the name of the secret.
			name!: string
			...
		}
		...
	}
	...
}
