package home

let C = cluster

// External-host backends — Service + EndpointSlice pointing at IPs that
// live outside the cluster. Each entry creates a `<name>-backend`
// Service in its namespace that the corresponding XIngress targets.
externalBackends: [
	{
		name:       "it-tools-backend"
		namespace:  "it-tools"
		port:       80
		targetPort: 30063
		addresses: ["192.168.1.148"]
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:       "home-assistant-backend"
		namespace:  "home-assistant"
		port:       443
		targetPort: 30103
		protocol:   "TCP"
		portName:   "https"
		addresses: ["192.168.1.148"]
		// Home Assistant serves TLS with a self-signed cert. Tell Traefik
		// to talk HTTPS to the backend and to use the insecure-skip-verify
		// ServersTransport defined in serverstransports.cue.
		annotations: {
			"traefik.ingress.kubernetes.io/service.serversscheme":    "https"
			"traefik.ingress.kubernetes.io/service.serverstransport": "home-assistant-insecure-skip-verify@kubernetescrd"
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:       "n8n-backend"
		namespace:  "n8n"
		port:       80
		targetPort: 30109
		addresses: ["192.168.1.148"]
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:       "webui-backend"
		namespace:  "webui"
		port:       80
		targetPort: 31028
		addresses: ["192.168.1.148"]
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:       "recipes-backend"
		namespace:  "recipes"
		port:       80
		targetPort: 30290
		addresses: ["192.168.1.148"]
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:       "metube-backend"
		namespace:  "metube"
		port:       80
		targetPort: 30094
		addresses: ["192.168.1.148"]
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:       "truenas-backend"
		namespace:  "truenas"
		port:       443
		targetPort: 8443
		protocol:   "TCP"
		portName:   "https"
		addresses: ["192.168.1.148"]
		// TrueNAS web UI ships with a self-signed cert. Tell Traefik to
		// talk HTTPS to the backend and to use the insecure-skip-verify
		// ServersTransport in the truenas namespace.
		annotations: {
			"traefik.ingress.kubernetes.io/service.serversscheme":    "https"
			"traefik.ingress.kubernetes.io/service.serverstransport": "truenas-insecure-skip-verify@kubernetescrd"
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
]
