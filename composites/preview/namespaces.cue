package preview

let C = cluster

namespaces: [
	{
		name:    "argo-events"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:    "argocd"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:    "traefik"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:    "external-secrets"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:    "openbao"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:    "cloudflared"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:    "metallb-system"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
]
