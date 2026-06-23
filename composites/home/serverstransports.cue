package home

let C = cluster

serversTransports: [
	{
		name:               "insecure-skip-verify"
		namespace:          "home-assistant"
		insecureSkipVerify: true
		tier:               C.tier
		cluster:            C.name
		owner:              "platform-team"
	},
	{
		name:               "insecure-skip-verify"
		namespace:          "truenas"
		insecureSkipVerify: true
		tier:               C.tier
		cluster:            C.name
		owner:              "platform-team"
	},
]
