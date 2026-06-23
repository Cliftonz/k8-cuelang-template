package preview

let C = cluster

// Namespaced ExternalSecrets — sync individual secrets from OpenBao into
// specific namespaces (cloudflared, argo-events, argocd).
externalSecrets: [
	// Cloudflare API token + account/tunnel config for STRRL controller.
	// Seed in OpenBao under preview/cloudflare-tunnel with three fields:
	//   account_id   — Cloudflare account ID (dashboard → right sidebar)
	//   tunnel_name  — any name, controller auto-creates if missing
	//   api_token    — token with scopes:
	//                  Zone:Zone:Read + Zone:DNS:Edit + Account:Cloudflare Tunnel:Edit
	{
		name:            "cloudflare-external-secret"
		namespace:       "cloudflared"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "5m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [
			{secretKey: "account_id",  remoteRef: {key: "preview/cloudflare-tunnel", property: "account_id"}},
			{secretKey: "tunnel_name", remoteRef: {key: "preview/cloudflare-tunnel", property: "tunnel_name"}},
			{secretKey: "api_token",   remoteRef: {key: "preview/cloudflare-tunnel", property: "api_token"}},
		]
	},

	// GitHub webhook secret — used by Argo Events to verify signed webhook
	// payloads from GitHub. Contains both the webhook HMAC secret and the
	// GitHub PAT used for API calls (status checks, labels, comments).
	{
		name:            "github-webhook-secret"
		namespace:       "argo-events"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "5m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [
			{secretKey: "webhook-secret", remoteRef: {key: "preview/github-webhook-secret", property: "webhook-secret"}},
			{secretKey: "token", remoteRef: {key: "preview/github-pat", property: "GITHUB_TOKEN"}},
		]
	},

	// Argo CD GitHub token — ApplicationSet pullRequest generator uses this
	// to list open PRs and their head SHAs.
	{
		name:            "github-token"
		namespace:       "argocd"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "5m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [{
			secretKey: "token"
			remoteRef: {key: "preview/github-pat", property: "GITHUB_TOKEN"}
		}]
	},

	// Argo CD notifications — service.webhook.github references $github-token
	// and service.webhook.discord references $discord-webhook-url. Both
	// placeholders resolve against keys in this Secret, which must be named
	// argocd-notifications-secret to match the controller's default
	// secret reference.
	{
		name:            "argocd-notifications-secret"
		namespace:       "argocd"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "5m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [
			{secretKey: "github-token", remoteRef: {key: "preview/github-pat", property: "GITHUB_TOKEN"}},
			{secretKey: "discord-webhook-url", remoteRef: {key: "preview/discord-webhook-url", property: "url"}},
		]
	},

	// Kelos agent OAuth — Claude Code OAuth token for AI agent Tasks.
	// Pulls the access token (CLAUDE_CODE_OAUTH_TOKEN env var) and the
	// expiry epoch-ms (EXPIRES_AT_MS), and writes the expiry as an
	// annotation on the resulting Secret so the kelos-oauth-watchdog
	// CronJob can warn on Discord 5 days before the token dies.
	// Re-seed via local Keychain extraction; see docs/secret-management.md.
	{
		name:            "claude-code-oauth"
		namespace:       "kelos-system"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "5m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		template: {
			metadata: annotations: {
				"kelos.dev/oauth-expires-at": "{{ .EXPIRES_AT_MS }}"
			}
		}
		data: [
			{secretKey: "CLAUDE_CODE_OAUTH_TOKEN", remoteRef: {key: "preview/claude-oauth-credentials", property: "CLAUDE_CODE_OAUTH_TOKEN"}},
			{secretKey: "EXPIRES_AT_MS",           remoteRef: {key: "preview/claude-oauth-credentials", property: "EXPIRES_AT_MS"}},
		]
	},

	// GitHub PAT for Kelos spawner pods + Workspace clone/push.
	// Kelos's TaskSpawner Deployment looks for env GITHUB_TOKEN sourced
	// from a Secret named exactly `github-pat` in its own namespace.
	// Workspaces resolve `secretRef.name: github-pat` against the same
	// Secret. Same OpenBao path Argo CD already reads.
	{
		name:            "github-pat"
		namespace:       "kelos-system"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "5m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [{
			secretKey: "GITHUB_TOKEN"
			remoteRef: {key: "preview/github-pat", property: "GITHUB_TOKEN"}
		}]
	},

	// GitHub PAT for Argo Events Sensor Jobs (/help, palette-init).
	// Named differently from kelos-system's `github-pat` to avoid
	// rendered-filename collision in the export.
	{
		name:            "github-pat-events"
		namespace:       "argo-events"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "5m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [{
			secretKey: "GITHUB_TOKEN"
			remoteRef: {key: "preview/github-pat", property: "GITHUB_TOKEN"}
		}]
	},

	// Discord webhook URL for the kelos-oauth-watchdog CronJob.
	// Same OpenBao path Argo CD's notifications-secret reads.
	{
		name:            "discord-webhook"
		namespace:       "kelos-system"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "5m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [{
			secretKey: "url"
			remoteRef: {key: "preview/discord-webhook-url", property: "url"}
		}]
	},

	// Argo CD CI token — used by Argo Events Sensor Jobs to authenticate
	// against the Argo CD API server when triggering app syncs.
	{
		name:            "argocd-ci-token"
		namespace:       "argo-events"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "5m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [{
			secretKey: "token"
			remoteRef: {key: "preview/argocd-ci-token", property: "token"}
		}]
	},
]
