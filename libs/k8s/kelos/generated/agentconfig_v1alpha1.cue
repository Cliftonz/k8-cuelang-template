// Code generated from CRD agentconfigs.kelos.dev (kelos.dev/v1alpha1); DO NOT EDIT.
// Source: kubectl get crd agentconfigs.kelos.dev -o json
// Regenerate: ./ci/scripts/gen-cue-from-crds.sh kelos.dev libs/k8s/kelos/generated
// AgentConfig is the Schema for the agentconfigs API.
package kelos

import "strings"

#AgentConfig: {
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

	// AgentConfigSpec defines the desired state of AgentConfig.
	spec?: {
		// AgentsMD is written to the agent's instruction file
		// (e.g., ~/.claude/CLAUDE.md for Claude Code).
		// This is additive and does not overwrite the repo's own
		// instruction files.
		agentsMD?: string

		// MCPServers defines MCP (Model Context Protocol) servers to make
		// available to the agent. Each entry is written to the agent's
		// native
		// MCP configuration (e.g., ~/.claude.json for Claude Code).
		mcpServers?: [...{
			// Args are command-line arguments for the server process.
			// Only used when type is "stdio".
			args?: [...string]

			// Command is the executable to run for stdio transport.
			// Required when type is "stdio".
			command?: string

			// Env are environment variables for the server process.
			// Only used when type is "stdio".
			env?: [string]: string

			// EnvFrom references a Secret whose data keys are environment
			// variable
			// names and values are environment variable values. Only used
			// when
			// type is "stdio". Values from EnvFrom take precedence over
			// inline Env
			// for overlapping keys.
			envFrom?: {
				// SecretRef references the Secret to read data from.
				secretRef!: {
					// Name is the name of the secret.
					name!: string
					...
				}
				...
			}

			// Headers are HTTP headers to include in requests.
			// Only used when type is "http" or "sse".
			headers?: [string]: string

			// HeadersFrom references a Secret whose data keys are header
			// names
			// and values are header values. Only used when type is "http" or
			// "sse".
			// Values from HeadersFrom take precedence over inline Headers for
			// overlapping keys.
			headersFrom?: {
				// SecretRef references the Secret to read data from.
				secretRef!: {
					// Name is the name of the secret.
					name!: string
					...
				}
				...
			}

			// Name identifies this MCP server. Used as the key in the
			// agent's MCP configuration.
			name!: strings.MinRunes(1)

			// Type is the transport type: "stdio", "http", or "sse".
			type!: "stdio" | "http" | "sse"

			// URL is the server endpoint for http or sse transport.
			// Required when type is "http" or "sse".
			url?: string
			...
		}]

		// Plugins defines plugin bundles containing skills and agents.
		// Each plugin is mounted as a directory and installed using the
		// agent's native mechanism (e.g., --plugin-dir for Claude Code,
		// ~/.codex/skills for Codex, extensions for Gemini).
		plugins?: [...{
			// Agents defines sub-agents for this plugin.
			// Each becomes agents/<name>.md in the plugin directory.
			agents?: [...{
				content!: string
				name!:    strings.MinRunes(1)
				...
			}]

			// Name is the plugin name. Used as the plugin directory name
			// and for namespacing in Claude Code (e.g., <name>:skill-name).
			name!: strings.MinRunes(1)

			// Skills defines skills for this plugin.
			// Each becomes skills/<name>/SKILL.md in the plugin directory.
			skills?: [...{
				content!: string
				name!:    strings.MinRunes(1)
				...
			}]
			...
		}]

		// Skills defines skills.sh packages to install into the plugin
		// volume.
		// Each entry references a package in owner/repo format from the
		// skills.sh
		// ecosystem, installed via "npx skills add" in an init container.
		skills?: [...{
			// Skill selects a specific skill by name from the package.
			// If empty, all skills in the package are installed.
			skill?: string

			// Source is the skills.sh package in owner/repo format
			// (e.g., "vercel-labs/agent-skills").
			source!: strings.MinRunes(1)
			...
		}]
		...
	}
	...
}
