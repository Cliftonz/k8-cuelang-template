package home

let C = cluster

// OpenBao backend — ESO pulls secrets via the kubernetes auth method.
// The openbao-bootstrap Job creates the matching Vault role and policy
// (see jobs.cue + clusterroles.cue).
clusterSecretStores: [
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
