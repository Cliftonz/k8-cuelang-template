package preview

let C = cluster

// LAN-side ingresses for platform UIs. Hostnames live in the
// `preview.example.internal` zone — picked up by ExternalDNS UniFi webhook
// (only renders + applies when -t unifi=true) which creates the
// matching CNAMEs/A records on the UniFi controller.
//
// Routing path: LAN client → UniFi DNS → traefik LoadBalancer/NodePort
// → IngressClass=traefik routes by Host header → backend Service.
//
// Cloudflare (public) routes are unaffected — those use the wildcard
// *.preview.example.com via STRRL.
ingresses: [
	{
		name:             "argocd-lan"
		namespace:        "argocd"
		host:             "argocd.preview.example.internal"
		serviceName:      "argo-cd-argocd-server"
		servicePort:      80
		ingressClassName: "traefik"
		tier:             C.tier
		cluster:          C.name
		owner:            "platform-team"
	},
	{
		name:             "openbao-lan"
		namespace:        "openbao"
		host:             "openbao.preview.example.internal"
		serviceName:      "openbao-ui"
		servicePort:      8200
		ingressClassName: "traefik"
		tier:             C.tier
		cluster:          C.name
		owner:            "platform-team"
	},
]
