package preview

let C = cluster

// ClusterSecretStores — cluster-scoped secret backends referenced by
// ExternalSecret and ClusterExternalSecret resources.
clusterSecretStores: [
	// OpenBao backend — provides secret storage for GHCR pull secrets,
	// Cloudflare tunnel credentials, Cloudflare API token, GitHub PATs,
	// Anthropic API keys, and preview app secrets.
	//
	// NOTE: For a dev/preview cluster we use the openbao server's
	// kubernetes auth method with a service account token. In production
	// you would use AppRole or external auth.
	{
		name:    "openbao-backend"
		cluster: C.name
		owner:   "platform-team"
		config: {
			provider: vault: {
				server:  "http://openbao.openbao.svc.cluster.local:8200"
				path:    "secret"
				version: "v2"
				auth: kubernetes: {
					mountPath: "kubernetes"
					role:      "external-secrets"
					serviceAccountRef: {
						name:      "external-secrets"
						namespace: "external-secrets"
					}
				}
			}
		}
	},
]
