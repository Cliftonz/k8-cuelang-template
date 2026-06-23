package shared

let C = cluster

namespaces: [
	{
		name:    "harbor-container-webhook"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
]
