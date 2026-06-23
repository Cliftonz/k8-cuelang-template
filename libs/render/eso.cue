package render

#ExternalSecretInput: {
	name:            string
	namespace:       string
	secretStoreRef:  string
	refreshInterval: string
	// One of `data` or `dataFrom` (or both) must be set. ESO validates
	// this downstream; we leave the schema permissive so callers can pick.
	data?: [...{
		secretKey: string
		remoteRef: {...}
	}]
	// Bulk-discover mode: ESO syncs every key at the referenced remote
	// path(s). Use this for env-var-as-secret flows where you want new
	// keys dropped in OpenBao to appear automatically in the pod env
	// (no CUE re-render). Each item is `{extract: {key, version?, ...}}`
	// or `{find: {...}}`.
	dataFrom?: [...{...}]
	template?: {...}
	tier:    string
	cluster: string
	owner:   string
}

#RenderExternalSecret: {
	in: #ExternalSecretInput
	out: {
		apiVersion: "external-secrets.io/v1beta1"
		kind:       "ExternalSecret"
		metadata: {
			name:      in.name
			namespace: in.namespace
			labels: (#StandardLabels & {tier: in.tier, cluster: in.cluster, owner: in.owner}).out
		}
		spec: {
			secretStoreRef: {
				name: in.secretStoreRef
				kind: "ClusterSecretStore"
			}
			refreshInterval: in.refreshInterval
			target: {
				name: in.name
				if in.template != _|_ {
					template: in.template
				}
			}
			if in.data != _|_ {
				data: in.data
			}
			if in.dataFrom != _|_ {
				dataFrom: in.dataFrom
			}
		}
	}
}

#ClusterExternalSecretInput: {
	name:    string
	cluster: string
	owner:   string
	config: {...}
	tier?: string
}

#RenderClusterExternalSecret: {
	in: #ClusterExternalSecretInput
	let _tier = *in.tier | "production"
	out: {
		apiVersion: "external-secrets.io/v1beta1"
		kind:       "ClusterExternalSecret"
		metadata: {
			name: in.name
			labels: (#StandardLabels & {tier: _tier, cluster: in.cluster, owner: in.owner}).out
		}
		spec: in.config
	}
}

#ClusterSecretStoreInput: {
	name:    string
	cluster: string
	owner:   string
	config: {...}
	tier?: string
}

#RenderClusterSecretStore: {
	in: #ClusterSecretStoreInput
	let _tier = *in.tier | "production"
	out: {
		apiVersion: "external-secrets.io/v1beta1"
		kind:       "ClusterSecretStore"
		metadata: {
			name: in.name
			labels: (#StandardLabels & {tier: _tier, cluster: in.cluster, owner: in.owner}).out
		}
		spec: in.config
	}
}
