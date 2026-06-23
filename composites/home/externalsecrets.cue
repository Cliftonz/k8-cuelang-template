package home

let C = cluster

// ExternalSecrets synced from OpenBao into consumer namespaces.
//
// Seed OpenBao first (requires openbao-bootstrap Job to have run + a
// human to kv-put the actual values):
//
//   kubectl -n openbao exec -it openbao-0 -- sh
//   bao login <root-token>
//   bao kv put secret/home/unifi \
//     host="https://192.168.x.x" \
//     api_key="<UniFi admin API key>" \
//     external="false"
externalSecrets: [
	{
		name:            "external-dns-unifi-secret"
		namespace:       "external-dns"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "1h"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [
			{secretKey: "host", remoteRef: {key: "home/unifi", property: "host"}},
			{secretKey: "api_key", remoteRef: {key: "home/unifi", property: "api_key"}},
			{secretKey: "external", remoteRef: {key: "home/unifi", property: "external"}},
		]
	},

	// Cloudflare API token + tunnel config for STRRL controller.
	// Seed: bao kv put secret/preview/cloudflare-tunnel
	//   account_id=... tunnel_name=... api_token=...
	{
		name:            "cloudflare-external-secret"
		namespace:       "cloudflared"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "5m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [
			{secretKey: "account_id", remoteRef: {key: "preview/cloudflare-tunnel", property: "account_id"}},
			{secretKey: "tunnel_name", remoteRef: {key: "preview/cloudflare-tunnel", property: "tunnel_name"}},
			{secretKey: "api_token", remoteRef: {key: "preview/cloudflare-tunnel", property: "api_token"}},
		]
	},

	// GitHub webhook secret + PAT for Argo Events signature verification.
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

	// Argo CD GitHub token — ApplicationSet pullRequest generator.
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

	// Argo CD notifications — github + discord webhook URL placeholders
	// resolve against keys in this Secret. Name must be exactly
	// argocd-notifications-secret to match the controller.
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

	// Kelos agent OAuth — Claude Code OAuth token + refresh-token bundle.
	// The cluster's claude-oauth-refresher CronJob uses REFRESH_TOKEN +
	// CLIENT_ID + TOKEN_URL to auto-mint new access tokens before
	// CLAUDE_CODE_OAUTH_TOKEN expires (~8h cadence). Refresh tokens last
	// ~30 days; when they near expiry the watchdog Discord-alerts the
	// human to re-run ci/scripts/refresh-claude-oauth.sh from a logged-in
	// laptop.
	//
	// Annotation `kelos.dev/oauth-expires-at` mirrors EXPIRES_AT_MS so
	// the existing kelos-oauth-watchdog CronJob can detect token
	// staleness independent of the refresher.
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
			{secretKey: "REFRESH_TOKEN", remoteRef: {key: "preview/claude-oauth-credentials", property: "REFRESH_TOKEN"}},
			{secretKey: "EXPIRES_AT_MS", remoteRef: {key: "preview/claude-oauth-credentials", property: "EXPIRES_AT_MS"}},
			{secretKey: "CLIENT_ID", remoteRef: {key: "preview/claude-oauth-credentials", property: "CLIENT_ID"}},
			{secretKey: "TOKEN_URL", remoteRef: {key: "preview/claude-oauth-credentials", property: "TOKEN_URL"}},
		]
	},

	// GitHub PAT for Kelos task spawner pods + Workspace clone/push.
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

	// GitHub PAT for Argo Events Sensor Jobs (separate Secret name to
	// avoid filename collision with kelos-system's github-pat).
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

	// GitHub PAT scoped to example-bot/* repos — separate fine-grained
	// token, separate OpenBao path. Consumed by the tandoor-recipe-mcp
	// Workspace; the existing example-org-scoped `github-pat` can't
	// reach example-bot-owned repos (fine-grained PATs are locked to one
	// resource owner). Seeded out-of-band via `bao kv put`.
	{
		name:            "github-pat-example-bot"
		namespace:       "kelos-system"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "5m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [{
			secretKey: "GITHUB_TOKEN"
			remoteRef: {key: "preview/github-pat-example-bot", property: "GITHUB_TOKEN"}
		}]
	},

	// Same example-bot PAT synced into argo-events ns — Sensor-spawned
	// Jobs (feature-branch-create-example-bot, feature-human-resume-
	// example-bot) live in argo-events and need the token mounted there.
	// Mirrors the example-org `github-pat-events` pattern.
	{
		name:            "github-pat-example-bot-events"
		namespace:       "argo-events"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "5m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [{
			secretKey: "GITHUB_TOKEN"
			remoteRef: {key: "preview/github-pat-example-bot", property: "GITHUB_TOKEN"}
		}]
	},

	// GitHub App credentials — APP_ID + INSTALLATION_ID + PRIVATE_KEY
	// (PEM). Used by gh-app-token-fetcher init containers / CronJob to
	// mint short-lived installation access tokens. App: `Open Warren -
	// Example Org`. See docs/github-app-setup.md.
	{
		name:            "github-app-creds"
		namespace:       "kelos-system"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "5m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [
			{secretKey: "APP_ID", remoteRef: {key: "preview/github-app", property: "APP_ID"}},
			{secretKey: "INSTALLATION_ID", remoteRef: {key: "preview/github-app", property: "INSTALLATION_ID"}},
			{secretKey: "PRIVATE_KEY", remoteRef: {key: "preview/github-app", property: "PRIVATE_KEY"}},
		]
	},
	// Same as above, but synced into argo-events ns (different XR name to
	// avoid cluster-scoped XR collision with the kelos-system one).
	{
		name:            "github-app-creds-events"
		namespace:       "argo-events"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "5m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [
			{secretKey: "APP_ID", remoteRef: {key: "preview/github-app", property: "APP_ID"}},
			{secretKey: "INSTALLATION_ID", remoteRef: {key: "preview/github-app", property: "INSTALLATION_ID"}},
			{secretKey: "PRIVATE_KEY", remoteRef: {key: "preview/github-app", property: "PRIVATE_KEY"}},
		]
	},

	// Argo Workflows ns parallel — App creds for the build pipeline's
	// token-refresh CronJob. Read by `github-app-token-refresh-workflows`,
	// turned into Secret/github-app-token every 30 minutes.
	{
		name:            "github-app-creds-workflows"
		namespace:       "argo-workflows"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "5m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [
			{secretKey: "APP_ID", remoteRef: {key: "preview/github-app", property: "APP_ID"}},
			{secretKey: "INSTALLATION_ID", remoteRef: {key: "preview/github-app", property: "INSTALLATION_ID"}},
			{secretKey: "PRIVATE_KEY", remoteRef: {key: "preview/github-app", property: "PRIVATE_KEY"}},
		]
	},

	// Argo CD GitHub App credentials. Serves two roles via a single Secret:
	//   1. ApplicationSet pullRequest generator (`appSecretName`) — needs
	//      githubAppID / githubAppInstallationID / githubAppPrivateKey.
	//   2. Repository credentials template for the whole example-org org —
	//      needs the `argocd.argoproj.io/secret-type: repo-creds` label,
	//      plus `url` + `type` fields. ArgoCD matches any repoURL with this
	//      `url` as a prefix and authenticates the clone via the App.
	// PATs go stale; Apps mint short-lived install tokens on every clone.
	{
		name:            "github-app-creds-argocd"
		namespace:       "argocd"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "5m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		template: {
			metadata: labels: {
				"argocd.argoproj.io/secret-type": "repo-creds"
			}
			data: {
				// ArgoCD repo-creds convention (consumed by ArgoCD itself).
				url:                     "https://github.com/example-org"
				type:                    "git"
				githubAppID:             "{{ .APP_ID }}"
				githubAppInstallationID: "{{ .INSTALLATION_ID }}"
				githubAppPrivateKey:     "{{ .PRIVATE_KEY }}"
				// Raw keys for the github-app-token-refresh-argocd CronJob,
				// which mounts THIS secret and reads /run/github-app/APP_ID
				// (same script as every other namespace's refresher). Without
				// these the refresh fails → no github-app-token secret →
				// preview-cap-watchdog stuck ContainerCreating forever.
				APP_ID:          "{{ .APP_ID }}"
				INSTALLATION_ID: "{{ .INSTALLATION_ID }}"
				PRIVATE_KEY:     "{{ .PRIVATE_KEY }}"
			}
		}
		data: [
			{secretKey: "APP_ID", remoteRef: {key: "preview/github-app", property: "APP_ID"}},
			{secretKey: "INSTALLATION_ID", remoteRef: {key: "preview/github-app", property: "INSTALLATION_ID"}},
			{secretKey: "PRIVATE_KEY", remoteRef: {key: "preview/github-app", property: "PRIVATE_KEY"}},
		]
	},

	// example-bot App installation credentials — same App, separate
	// installation on the example-bot user account. Same APP_ID +
	// PRIVATE_KEY as the example-org install; only INSTALLATION_ID
	// differs (per-installation ID). Required for the example-bot
	// review panel + lead-dev: only GitHub Apps can create check
	// runs, fine-grained PATs cannot. Lives in kelos-system because
	// the panel-spawner + lead-dev-spawner Jobs (and the Tasks they
	// embed) all run in kelos-system.
	{
		name:            "github-app-creds-example-bot"
		namespace:       "kelos-system"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "5m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [
			{secretKey: "APP_ID", remoteRef: {key: "preview/github-app-example-bot", property: "APP_ID"}},
			{secretKey: "INSTALLATION_ID", remoteRef: {key: "preview/github-app-example-bot", property: "INSTALLATION_ID"}},
			{secretKey: "PRIVATE_KEY", remoteRef: {key: "preview/github-app-example-bot", property: "PRIVATE_KEY"}},
		]
	},

	// Discord webhook URL for kelos-oauth-watchdog CronJob.
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

	// Same Discord webhook synced into argo-events ns — used by the
	// argo-sensor-error-watchdog CronJob that alerts on level=error
	// log lines in argo-events sensor pods. Different XR `name` from
	// the kelos-system and openbao copies because XR is cluster-scoped.
	{
		name:            "discord-webhook-events"
		namespace:       "argo-events"
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

	// Same Discord webhook into external-secrets ns — eso-session-watchdog
	// CronJob alerts when ClusterSecretStores have been NotReady for
	// >5min (and restarts the ESO controller).
	{
		name:            "discord-webhook-eso"
		namespace:       "external-secrets"
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

	// Same Discord webhook synced into openbao ns — openbao-auto-unseal
	// CronJob alerts when OpenBao seals (and auto-unseals it).
	// Separate ExternalSecret because the auto-unseal pod runs in the
	// openbao namespace (intra-ns NP allows + no extra rules needed).
	// Different XR `name` from the kelos-system copy because XR is
	// cluster-scoped — same name + different namespace would collide.
	{
		name:            "discord-webhook-openbao"
		namespace:       "openbao"
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

	// Crossplane provider-upjet-github credentials. The provider's
	// ProviderConfig reads a JSON blob {"token":"...","owner":"..."} from
	// key `credentials` of this Secret. ESO templates the JSON shape
	// around the existing GitHub PAT in OpenBao, so we don't need a
	// second secret path — just shape it differently for this consumer.
	{
		name:            "github-provider-creds"
		namespace:       "crossplane-system"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "5m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		template: {
			data: {
				credentials: #"""
					{"token":"{{ .GITHUB_TOKEN }}","owner":"example-org"}
					"""#
			}
		}
		data: [{
			secretKey: "GITHUB_TOKEN"
			remoteRef: {key: "preview/github-pat", property: "GITHUB_TOKEN"}
		}]
	},

	// Crossplane provider-upjet-cloudflare credentials. The
	// ProviderConfig reads {"api_token":"..."} from key `credentials`.
	// Token is a scoped one minted in Cloudflare UI with: Zone:Read,
	// Zone WAF:Edit, Zone Settings:Edit, Account Rulesets:Edit —
	// scoped to example.com. Seed via
	// ci/scripts/seed-cloudflare-token.sh.
	{
		name:            "cloudflare-provider-creds"
		namespace:       "crossplane-system"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "5m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		template: {
			data: {
				credentials: #"""
					{"api_token":"{{ .CLOUDFLARE_API_TOKEN }}"}
					"""#
			}
		}
		data: [{
			secretKey: "CLOUDFLARE_API_TOKEN"
			remoteRef: {key: "preview/cloudflare-provider-token", property: "CLOUDFLARE_API_TOKEN"}
		}]
	},

	// GHCR pull credentials. Templates a dockerconfigjson on the fly from
	// preview/ghcr-pat — a classic PAT with read:packages scope (fine-grained
	// PATs do not expose packages permissions, so the existing fine-grained
	// preview/github-pat cannot pull private GHCR images).
	//
	// Two consumers, two ExternalSecrets (XR names must be globally unique
	// across XExternalSecrets, so the live Secret name == XR name in each
	// namespace — see export/all.cue line 1037):
	//   - bb-docs/ghcr-pull-secret: kubelet imagePullSecret for Deployment
	//   - argocd/ghcr-pull-secret-image-updater: argocd-image-updater
	//     registry credentials (queries ghcr.io for digest changes)
	{
		name:            "ghcr-pull-secret"
		namespace:       "bb-docs"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "5m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		template: {
			type: "kubernetes.io/dockerconfigjson"
			data: ".dockerconfigjson": #"""
				{"auths":{"ghcr.io":{"auth":"{{ printf "%s:%s" .username .token | b64enc }}"}}}
				"""#
		}
		data: [
			{secretKey: "username", remoteRef: {key: "preview/ghcr-pat", property: "GHCR_USER"}},
			{secretKey: "token", remoteRef: {key: "preview/ghcr-pat", property: "GHCR_TOKEN"}},
		]
	},
	{
		name:            "ghcr-pull-secret-image-updater"
		namespace:       "argocd"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "5m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		template: {
			type: "kubernetes.io/dockerconfigjson"
			data: ".dockerconfigjson": #"""
				{"auths":{"ghcr.io":{"auth":"{{ printf "%s:%s" .username .token | b64enc }}"}}}
				"""#
		}
		data: [
			{secretKey: "username", remoteRef: {key: "preview/ghcr-pat", property: "GHCR_USER"}},
			{secretKey: "token", remoteRef: {key: "preview/ghcr-pat", property: "GHCR_TOKEN"}},
		]
	},

	// Velero R2 credentials. Velero's AWS plugin reads an INI-style
	// AWS credentials profile from a single key in the Secret (default
	// key name `cloud`). ESO templates the [default] profile around the
	// access key + secret stored in OpenBao at preview/r2-velero.
	{
		name:            "velero-r2-creds"
		namespace:       "velero"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "5m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		template: {
			data: {
				cloud: #"""
					[default]
					aws_access_key_id={{ .AWS_ACCESS_KEY_ID }}
					aws_secret_access_key={{ .AWS_SECRET_ACCESS_KEY }}
					"""#
			}
		}
		data: [
			{secretKey: "AWS_ACCESS_KEY_ID", remoteRef: {key: "preview/r2-velero", property: "AWS_ACCESS_KEY_ID"}},
			{secretKey: "AWS_SECRET_ACCESS_KEY", remoteRef: {key: "preview/r2-velero", property: "AWS_SECRET_ACCESS_KEY"}},
		]
	},

	// Cloudflare API token for cert-manager DNS01 challenge on the
	// example.com zone. Distinct from the tunnel token (which only
	// needs tunnel-create perms) — this one has Zone:DNS:Edit on
	// example.com. Used by the letsencrypt-example-public ClusterIssuer
	// to publish temporary _acme-challenge TXT records during cert
	// issuance + renewal.
	//
	// Seed: bao kv put secret/home/cert-manager/cloudflare api_token=...
	{
		name:            "cloudflare-api-token"
		namespace:       "cert-manager"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "1h"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [
			{secretKey: "api_token", remoteRef: {key: "home/cert-manager/cloudflare", property: "api_token"}},
		]
	},

	// Dex Google OAuth credentials + service-account JSON for Groups API.
	// The serviceAccountFilePath value the Dex chart expects is a path
	// inside the pod — we project the JSON into a file via the chart's
	// `googleSAJson` value (mounted at /etc/dex/google.json). The plain
	// client_id + client_secret feed straight into the Google connector.
	//
	// Seed:
	//   bao kv put secret/home/dex/google \
	//     client_id=<oauth web client ID> \
	//     client_secret=<oauth web client secret> \
	//     service_account_json=@dex-groups-reader.json \
	//     admin_email=admin@example.com
	{
		name:            "dex-google"
		namespace:       "dex"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "1h"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [
			{secretKey: "client_id", remoteRef: {key: "home/dex/google", property: "client_id"}},
			{secretKey: "client_secret", remoteRef: {key: "home/dex/google", property: "client_secret"}},
			{secretKey: "service_account_json", remoteRef: {key: "home/dex/google", property: "service_account_json"}},
			{secretKey: "admin_email", remoteRef: {key: "home/dex/google", property: "admin_email"}},
		]
	},

	// Dex static client secrets shared with Argo CD, OpenBao, oauth2-proxy,
	// Coder. Generated once with openssl rand -hex 32 and stashed in
	// OpenBao. Each consumer's helm release / config references these
	// via ESO too.
	//
	// Seed:
	//   bao kv put secret/home/dex/clients \
	//     argocd=$(openssl rand -hex 32) \
	//     openbao=$(openssl rand -hex 32) \
	//     oauth2proxy=$(openssl rand -hex 32) \
	//     coder=$(openssl rand -hex 32)
	{
		name:            "dex-static-clients"
		namespace:       "dex"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "1h"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [
			{secretKey: "argocd", remoteRef: {key: "home/dex/clients", property: "argocd"}},
			{secretKey: "openbao", remoteRef: {key: "home/dex/clients", property: "openbao"}},
			{secretKey: "oauth2proxy", remoteRef: {key: "home/dex/clients", property: "oauth2proxy"}},
		]
	},

	// Same dex/clients secret, projected into argocd ns for the oidc
	// config in argocd-cm. Argo CD reads its OIDC client secret via
	// `$<secret-name>:<key>` reference in the cm — but Argo CD only
	// honors the reference when the target Secret carries the label
	// `app.kubernetes.io/part-of: argocd`. Without it, argocd-server
	// logs "config referenced '$argocd-dex-client:client_secret', but
	// key does not exist in secret" and the OIDC token exchange fails
	// with invalid_client. The ESO schema defaults to
	// `app.kubernetes.io/part-of: platform` (k8-infra-wide); the
	// template below overrides just this Secret to satisfy Argo CD.
	{
		name:            "argocd-dex-client"
		namespace:       "argocd"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "1h"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		template: {
			metadata: {
				labels: {
					"app.kubernetes.io/part-of": "argocd"
				}
			}
		}
		data: [
			{secretKey: "client_secret", remoteRef: {key: "home/dex/clients", property: "argocd"}},
		]
	},

	// Same for oauth2-proxy — chart reads client secret from a Secret.
	// `client-id` must be the LITERAL string "oauth2-proxy" (matches the
	// staticClients[].id in the Dex config above). Earlier versions of
	// this ESO pulled client-id from OpenBao's oauth2proxy property,
	// which contains the secret, so oauth2-proxy was sending the secret
	// as both client_id and client_secret — Dex rejected with
	// `Invalid client_id ("849eea...")`. Template now hardcodes the id.
	{
		name:            "oauth2-proxy-dex-client"
		namespace:       "oauth-proxy"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "1h"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [
			{secretKey: "client_secret", remoteRef: {key: "home/dex/clients", property: "oauth2proxy"}},
			// Cookie secret: 32-byte random for cookie encryption. Seeded
			// at secret/home/dex/clients property `oauth2proxy_cookie`.
			{secretKey: "cookie_secret", remoteRef: {key: "home/dex/clients", property: "oauth2proxy_cookie"}},
		]
		template: {
			type: "Opaque"
			data: {
				"client-id":     "oauth2-proxy"
				"client-secret": "{{ .client_secret }}"
				"cookie-secret": "{{ .cookie_secret }}"
			}
		}
	},

	// Hermes Agent — Admin's profile, auto-sync mode. Every key at the
	// OpenBao path `secret/users/admin/hermes` becomes an env var on the
	// pod via the Secret + envFrom + Reloader chain.
	//
	// To add a new env var without re-rendering CUE:
	//   ROOT=$(kubectl -n openbao get secret openbao-keys -o jsonpath='{.data.root-token}' | base64 -d)
	//   kubectl -n openbao exec openbao-0 -- env BAO_TOKEN="$ROOT" \
	//     bao kv patch secret/users/admin/hermes MY_NEW_VAR=value
	// ESO picks it up within the refresh interval (1m), the Secret hash
	// changes, Reloader restarts the pod, MY_NEW_VAR is now in env.
	//
	// The required keys for the chart to function are:
	//   AI_GATEWAY_API_KEY  — Vercel AI Gateway key
	//   API_SERVER_KEY      — Hermes apiServer Bearer auth (bind to 0.0.0.0)
	//   HONCHO_BASE_URL     — http://honcho.honcho.svc.cluster.local:8000
	//                         (plugin reads HONCHO_BASE_URL, NOT HONCHO_URL —
	//                         wrong name = client falls back to Honcho cloud
	//                         → "Invalid API key" on the placeholder key)
	//   HONCHO_API_KEY      — placeholder; Honcho runs AUTH_USE_AUTH=false
	// Everything else (e.g. ANTHROPIC_API_KEY, OPENROUTER_API_KEY,
	// custom env) is optional and picked up automatically.
	{
		name:            "hermes-secrets"
		namespace:       "hermes"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "1m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		dataFrom: [
			{extract: {key: "users/admin/hermes"}},
		]
	},

	// Hermes Agent — Alex's profile, same auto-sync pattern.
	// Path: secret/users/dev2/hermes.
	{
		name:            "hermes-dev2-secrets"
		namespace:       "hermes"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "1m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		dataFrom: [
			{extract: {key: "users/dev2/hermes"}},
		]
	},

	// Hermes Agent — red-team profile, same auto-sync pattern.
	// Path: secret/users/redteam/hermes. Seed it with at least:
	//   API_SERVER_KEY — Hermes apiServer Bearer (bind 0.0.0.0)
	//   KALI_SSH_KEY   — private key for the Kali host (server mode SSH);
	//                    the install-kali-ssh-key init writes it to
	//                    ~/.ssh/kali_key. Multi-line PEM is fine.
	//   HONCHO_BASE_URL — http://honcho.honcho.svc.cluster.local:8000
	//                     (plugin reads HONCHO_BASE_URL, NOT HONCHO_URL)
	//   HONCHO_API_KEY — placeholder (honcho runs AUTH_USE_AUTH=false)
	// Codex OAuth needs no key here — it's a device login stored in
	// auth.json on the PVC.
	{
		name:            "hermes-redteam-secrets"
		namespace:       "hermes"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "1m"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		dataFrom: [
			{extract: {key: "users/redteam/hermes"}},
		]
	},

	// Honcho server-side secrets. Synced from secret/home/honcho in OpenBao.
	// Only LLM_OPENAI_API_KEY is required for the default Vercel AI Gateway
	// config (Honcho's text-gen features all reuse the same key). Seed
	// before this rolls out:
	//   bao kv put secret/home/honcho \
	//     LLM_OPENAI_API_KEY=<vercel-ai-gateway-key>
	//
	// The pod's `envFrom: secretRef: name: honcho-secrets` picks every key
	// up as an env var, so any future LLM_*_API_KEY etc. seeded to OpenBao
	// just appears in the pod on next sync + restart (Reloader auto-rolls).
	{
		name:            "honcho-secrets"
		namespace:       "honcho"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "1h"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [
			{secretKey: "LLM_OPENAI_API_KEY", remoteRef: {key: "home/honcho", property: "LLM_OPENAI_API_KEY"}},
		]
	},

	// Jarvy telemetry forwarder — Grafana Cloud OTLP write token.
	//
	// The collector's `bearertokenauth` extension builds the header as
	// `Authorization: Basic <token>`, so the rendered Secret's `token`
	// key must hold base64("instance_id:apikey") — NOT the raw apikey.
	// We keep the two halves as separate properties in OpenBao and let
	// ESO assemble them via the template engine.
	//
	// Seed in OpenBao (if not already laid out this way):
	//   bao kv put secret/home/jarvy/grafana-otlp-write-token \
	//     instance_id=<grafana-cloud-instance-id> \
	//     apikey=<grafana-cloud-apikey>
	//
	// Chart's `secrets.strategy: existing` consumes this Secret by name.
	{
		name:            "grafana-otlp-token"
		namespace:       "jarvy-telemetry"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "1h"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		template: {
			engineVersion: "v2"
			data: token: "{{ printf \"%s:%s\" .instance_id .apikey | b64enc }}"
		}
		data: [
			{secretKey: "instance_id", remoteRef: {key: "home/jarvy/grafana-otlp-write-token", property: "instance_id"}},
			{secretKey: "apikey", remoteRef: {key: "home/jarvy/grafana-otlp-write-token", property: "token"}},
		]
	},

	// Jarvy PII salt — straight passthrough (no assembly needed).
	{
		name:            "pii-salt"
		namespace:       "jarvy-telemetry"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "1h"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [
			{secretKey: "salt", remoteRef: {key: "home/jarvy/pii-salt", property: "salt"}},
		]
	},

	// Grafana Cloud Loki READ token — consumed by the
	// jarvy-tool-discovery CronJob to query for tool.unsupported
	// events and dispatch ci-fixer-jarvy / tool-discoverer Tasks.
	//
	// Seed in OpenBao:
	//   bao kv put secret/home/grafana/loki-read \
	//     url=https://logs-prod-006.grafana.net \
	//     user_id=<numeric Loki instance ID from Grafana Cloud Connections page> \
	//     token=<Cloud Access Policy token with logs:read scope>
	//
	// The CronJob reads url/user_id/token straight from env (no Basic
	// auth assembly needed — curl --user user_id:token handles it).
	{
		name:            "grafana-loki-read-token"
		namespace:       "kelos-system"
		secretStoreRef:  "openbao-backend"
		refreshInterval: "1h"
		tier:            C.tier
		cluster:         C.name
		owner:           "platform-team"
		data: [
			{secretKey: "url", remoteRef: {key: "home/grafana/loki-read", property: "url"}},
			{secretKey: "user_id", remoteRef: {key: "home/grafana/loki-read", property: "user_id"}},
			{secretKey: "token", remoteRef: {key: "home/grafana/loki-read", property: "token"}},
		]
	},
]
