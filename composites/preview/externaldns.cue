package preview

let C = cluster

// ──────────────────────────────────────────────────────────────────────
// ExternalDNS — UniFi webhook provider
//
// Optional. Activates only when the build is rendered with -t unifi=true,
// e.g.:
//   make export-cluster CLUSTER=preview UNIFI=true
//   make apply         CLUSTER=preview UNIFI=true
//
// What it does: lets ExternalDNS publish DNS records to a local UniFi
// controller (UDM/UDM Pro/UDR) so in-cluster Ingresses get internal
// hostnames resolvable on the LAN. Useful for split-horizon access to
// previews without round-tripping through Cloudflare's edge.
//
// Reference upstream: https://github.com/kashalls/external-dns-unifi-webhook
//
// Required OpenBao secret (seed before enabling):
//   secret/preview/unifi
//     host:     "https://192.168.x.x"        (UniFi controller URL)
//     api_key:  "<API key from UniFi → Settings → Admins → Add Admin>"
//     external: "false"                      (set "true" if controller
//                                             is NOT UniFi hardware)
//
// Domain filter is set per-cluster below; adjust to whatever LAN-zone
// you want UniFi to own (e.g. "lan.example.com" or a private TLD).
// ──────────────────────────────────────────────────────────────────────

unifiExtras: {
	// Domain that ExternalDNS is allowed to manage on the UniFi controller.
	// Records outside this filter are ignored.
	// Use an internal-only TLD so records never leak to public DNS.
	_domainFilter: "preview.example.internal"

	namespaces: [
		{
			name:    "external-dns"
			tier:    C.tier
			cluster: C.name
			owner:   "platform-team"
		},
	]

	helmReleases: [
		{
			name:      "external-dns-unifi"
			namespace: "external-dns"
			chart: {
				name:       "external-dns"
				repository: "https://kubernetes-sigs.github.io/external-dns/"
				version:    "1.15.0"
			}
			values: {
				fullnameOverride: "external-dns-unifi"
				logLevel:         "info"

				provider: {
					name: "webhook"
					webhook: {
						image: {
							repository: "ghcr.io/kashalls/external-dns-unifi-webhook"
							tag:        "v0.8.2"
						}
						env: [
							{name: "UNIFI_HOST",                valueFrom: secretKeyRef: {name: "external-dns-unifi-secret", key: "host"}},
							{name: "UNIFI_API_KEY",             valueFrom: secretKeyRef: {name: "external-dns-unifi-secret", key: "api_key"}},
							{name: "UNIFI_EXTERNAL_CONTROLLER", valueFrom: secretKeyRef: {name: "external-dns-unifi-secret", key: "external"}},
							{name: "LOG_LEVEL", value: "info"},
						]
						livenessProbe: httpGet: {path: "/healthz", port: "http-webhook"}
						readinessProbe: httpGet: {path: "/readyz",  port: "http-webhook"}
					}
				}

				// Skip TLS spec on Ingresses — the LAN zone is internal-only,
				// no cert provisioning required at this layer.
				extraArgs: ["--ignore-ingress-tls-spec"]

				// sync = create, update, AND delete orphans within domainFilter.
				policy:        "sync"
				sources:       ["ingress", "service"]
				txtOwnerId:    "k8-infra-preview"
				txtPrefix:     "k8s."
				domainFilters: [_domainFilter]

				resources: {
					requests: {cpu: "50m", memory: "64Mi"}
					limits: {cpu: "200m", memory: "128Mi"}
				}
			}
			tier:    C.tier
			cluster: C.name
			owner:   "platform-team"
		},
	]

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
				{secretKey: "host",     remoteRef: {key: "preview/unifi", property: "host"}},
				{secretKey: "api_key",  remoteRef: {key: "preview/unifi", property: "api_key"}},
				{secretKey: "external", remoteRef: {key: "preview/unifi", property: "external"}},
			]
		},
	]
}
