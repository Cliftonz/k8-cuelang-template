package home

let C = cluster

// LAN-side ingresses for household services. Hostnames are published to
// the UniFi controller by ExternalDNS. The `external-dns.alpha.kubernetes.io/target`
// annotation forces edns to publish the internal LB IP (192.168.1.235)
// rather than Traefik's first-listed Service IP (DMZ 192.168.2.240).
//
// Each ingress also carries `gethomepage.dev/*` annotations so the
// Homepage dashboard at home.example.internal auto-discovers the service
// and renders a tile with name + group + icon. Icons are sourced from
// the dashboard-icons project (https://github.com/walkxcode/dashboard-icons).
//
// Backends are created by composites/home/externalbackends.cue
// (Service + EndpointSlice → 192.168.1.148:<NodePort>).
let _internalTarget = {"external-dns.alpha.kubernetes.io/target": "192.168.1.235"}

// Homepage's auto-discovery sets a default pod-selector of
// `app.kubernetes.io/name=<ingress-name>` and tries to fetch pod status from
// the ingress's namespace. Two patterns we use:
//   1. In-cluster services with a real backing pod (argocd, openbao):
//      override `gethomepage.dev/pod-selector` to match the actual pod
//      label so Homepage shows live pod status.
//   2. External backends running off-cluster (truenas-hosted):
//      override `gethomepage.dev/namespace` + `pod-selector` to point at
//      the Traefik proxy that fronts them — if Traefik is down, the route
//      is dead anyway, so it's an honest health signal.
// `siteMonitor` adds an HTTP probe widget regardless (independent of pod
// status).
let _proxyAsStatus = {
	"gethomepage.dev/namespace":    "traefik"
	"gethomepage.dev/pod-selector": "app.kubernetes.io/name=traefik"
}

// cert-manager auto-issues a cert from the OpenBao PKI ClusterIssuer
// (infrastructure/cert-manager/clusterissuer-openbao.yaml) for any
// Ingress carrying this annotation + a tls block. Each ingress sets
// tlsSecretName: "<name>-tls" so cert-manager writes the cert into a
// dedicated Secret per service.
//
// Browsers will still warn until the OpenBao Root CA is installed on
// the client device. The cert + per-OS install steps are served at
// https://ca.example.com (see staticsites.cue + docs/trust-internal-ca.md).
let _certIssuer = {"cert-manager.io/cluster-issuer": "openbao-example-internal"}

// Real Let's Encrypt cert via Cloudflare DNS01. Used by hosts on the
// public TLD `example.com` (Google OAuth requires a public TLD; LAN
// resolution still via UniFi). Issuer manifest:
// infrastructure/cert-manager/clusterissuer-letsencrypt-example-public.yaml
let _publicCertIssuer = {"cert-manager.io/cluster-issuer": "letsencrypt-example-public"}

// Traefik middleware chain that delegates to oauth2-proxy in the
// oauth-proxy namespace AND redirects unauthenticated users to the
// sign-in flow on 401. Apply to any Ingress that has no native auth
// (Traefik dashboard, OpenCost, Goldilocks, future Hubble UI).
//
// Composition (see infrastructure/oauth-proxy/):
//   forward-auth-dex   → ForwardAuth → oauth2-proxy /oauth2/auth
//   signin-redirect    → errors{401} → oauth2-proxy /oauth2/start (302)
// Combined in the `auth-with-redirect` Chain middleware so a fresh
// browser visit auto-bounces through Google login instead of stopping
// at a bare 401 page. Cookie scope `.example.internal` keeps one
// sign-in valid across every gated app.
let _oauthProxyAuth = {
	"traefik.ingress.kubernetes.io/router.middlewares": "oauth-proxy-auth-with-redirect@kubernetescrd"
}

ingresses: [
	{
		name:             "it-tools"
		namespace:        "it-tools"
		host:             "it-tools.example.internal"
		serviceName:      "it-tools-backend"
		servicePort:      80
		ingressClassName: "traefik"
		tlsSecretName:    "\(name)-tls"
		annotations: {
			_internalTarget
			_proxyAsStatus
			_certIssuer
			"gethomepage.dev/enabled":     "true"
			"gethomepage.dev/name":        "IT Tools"
			"gethomepage.dev/group":       "Tools"
			"gethomepage.dev/icon":        "it-tools.png"
			"gethomepage.dev/description": "Swiss-army-knife dev tools"
			"gethomepage.dev/href":        "http://it-tools.example.internal"
			"gethomepage.dev/siteMonitor": "http://it-tools.example.internal"
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:             "home-assistant"
		namespace:        "home-assistant"
		host:             "home-assistant.example.internal"
		serviceName:      "home-assistant-backend"
		servicePort:      443
		ingressClassName: "traefik"
		tlsSecretName:    "\(name)-tls"
		annotations: {
			_internalTarget
			_proxyAsStatus
			_certIssuer

			// HA upstream at https://192.168.1.148:30103 serves HTTPS
			// with a self-signed cert. Traefik defaults to HTTP upstream
			// unless told otherwise — these annotations make it use
			// HTTPS + skip cert verification.
			"traefik.ingress.kubernetes.io/service.serversscheme":    "https"
			"traefik.ingress.kubernetes.io/service.serverstransport": "home-assistant-insecure-skip-verify@kubernetescrd"

			// HA has use_x_forwarded_for: true but its trusted_proxies list
			// omits the SNAT'd cluster node IPs, so it 400s on any proxied
			// request carrying XFF. Strip the header at the edge. Middleware
			// defined in helmreleases.cue (traefik extraObjects).
			"traefik.ingress.kubernetes.io/router.middlewares":       "home-assistant-strip-xff@kubernetescrd"
			"gethomepage.dev/enabled":                                "true"
			"gethomepage.dev/name":                                   "Home Assistant"
			"gethomepage.dev/group":                                  "Smart Home"
			"gethomepage.dev/icon":                                   "home-assistant.png"
			"gethomepage.dev/description":                            "Smart-home automation hub"
			"gethomepage.dev/href":                                   "http://home-assistant.example.internal"
			"gethomepage.dev/siteMonitor":                            "http://home-assistant.example.internal"
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:             "n8n"
		namespace:        "n8n"
		host:             "n8n.example.internal"
		serviceName:      "n8n-backend"
		servicePort:      80
		ingressClassName: "traefik"
		tlsSecretName:    "\(name)-tls"
		annotations: {
			_internalTarget
			_proxyAsStatus
			_certIssuer
			"gethomepage.dev/enabled":     "true"
			"gethomepage.dev/name":        "n8n"
			"gethomepage.dev/group":       "Tools"
			"gethomepage.dev/icon":        "n8n.png"
			"gethomepage.dev/description": "Workflow automation"
			"gethomepage.dev/href":        "http://n8n.example.internal"
			"gethomepage.dev/siteMonitor": "http://n8n.example.internal"
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:             "metube"
		namespace:        "metube"
		host:             "metube.example.internal"
		serviceName:      "metube-backend"
		servicePort:      80
		ingressClassName: "traefik"
		tlsSecretName:    "\(name)-tls"
		annotations: {
			_internalTarget
			_proxyAsStatus
			_certIssuer
			"gethomepage.dev/enabled":     "true"
			"gethomepage.dev/name":        "MeTube"
			"gethomepage.dev/group":       "Tools"
			"gethomepage.dev/icon":        "metube.png"
			"gethomepage.dev/description": "yt-dlp web UI"
			"gethomepage.dev/href":        "http://metube.example.internal"
			"gethomepage.dev/siteMonitor": "http://metube.example.internal"
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:             "truenas"
		namespace:        "truenas"
		host:             "truenas.example.internal"
		serviceName:      "truenas-backend"
		servicePort:      443
		ingressClassName: "traefik"
		tlsSecretName:    "\(name)-tls"
		annotations: {
			_internalTarget
			_proxyAsStatus
			_certIssuer

			// TrueNAS UI at https://192.168.1.148:8443 serves HTTPS with
			// a self-signed cert. Match the home-assistant pattern:
			// HTTPS upstream + per-namespace insecure-skip-verify transport.
			"traefik.ingress.kubernetes.io/service.serversscheme":    "https"
			"traefik.ingress.kubernetes.io/service.serverstransport": "truenas-insecure-skip-verify@kubernetescrd"
			"gethomepage.dev/enabled":                                "true"
			"gethomepage.dev/name":                                   "TrueNAS"
			"gethomepage.dev/group":                                  "Platform"
			"gethomepage.dev/icon":                                   "truenas.png"
			"gethomepage.dev/description":                            "NAS appliance UI"
			"gethomepage.dev/href":                                   "https://truenas.example.internal"
			"gethomepage.dev/siteMonitor":                            "https://truenas.example.internal"
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:             "webui"
		namespace:        "webui"
		host:             "webui.example.internal"
		serviceName:      "webui-backend"
		servicePort:      80
		ingressClassName: "traefik"
		tlsSecretName:    "\(name)-tls"
		annotations: {
			_internalTarget
			_proxyAsStatus
			_certIssuer
			"gethomepage.dev/enabled":     "true"
			"gethomepage.dev/name":        "Open WebUI"
			"gethomepage.dev/group":       "Tools"
			"gethomepage.dev/icon":        "open-webui.png"
			"gethomepage.dev/description": "LLM chat front-end"
			"gethomepage.dev/href":        "http://webui.example.internal"
			"gethomepage.dev/siteMonitor": "http://webui.example.internal"
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:             "recipes"
		namespace:        "recipes"
		host:             "recipes.example.internal"
		serviceName:      "recipes-backend"
		servicePort:      80
		ingressClassName: "traefik"
		tlsSecretName:    "\(name)-tls"
		annotations: {
			_internalTarget
			_proxyAsStatus
			_certIssuer
			"gethomepage.dev/enabled":     "true"
			"gethomepage.dev/name":        "Recipes"
			"gethomepage.dev/group":       "Smart Home"
			"gethomepage.dev/icon":        "tandoor.png"
			"gethomepage.dev/description": "Household recipe manager"
			"gethomepage.dev/href":        "http://recipes.example.internal"
			"gethomepage.dev/siteMonitor": "http://recipes.example.internal"
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:             "argocd-lan"
		namespace:        "argocd"
		host:             "argocd.example.internal"
		serviceName:      "argo-cd-argocd-server"
		servicePort:      80
		ingressClassName: "traefik"
		tlsSecretName:    "\(name)-tls"
		annotations: {
			_internalTarget
			_certIssuer
			"gethomepage.dev/enabled":      "true"
			"gethomepage.dev/name":         "Argo CD"
			"gethomepage.dev/group":        "Platform"
			"gethomepage.dev/icon":         "argocd.png"
			"gethomepage.dev/description":  "GitOps engine"
			"gethomepage.dev/href":         "http://argocd.example.internal"
			"gethomepage.dev/siteMonitor":  "http://argocd.example.internal"
			"gethomepage.dev/pod-selector": "app.kubernetes.io/name=argocd-server"
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:             "openbao-lan"
		namespace:        "openbao"
		host:             "openbao.example.internal"
		serviceName:      "openbao-ui"
		servicePort:      8200
		ingressClassName: "traefik"
		tlsSecretName:    "\(name)-tls"
		annotations: {
			_internalTarget
			_certIssuer
			"gethomepage.dev/enabled":      "true"
			"gethomepage.dev/name":         "OpenBao"
			"gethomepage.dev/group":        "Platform"
			"gethomepage.dev/icon":         "vault.png"
			"gethomepage.dev/description":  "Secret store"
			"gethomepage.dev/href":         "http://openbao.example.internal"
			"gethomepage.dev/siteMonitor":  "http://openbao.example.internal"
			"gethomepage.dev/pod-selector": "app.kubernetes.io/name=openbao"
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	// Gates the Goldilocks dashboard behind Dex via oauth2-proxy.
	{
		name:             "goldilocks"
		namespace:        "goldilocks"
		host:             "goldilocks.example.internal"
		serviceName:      "goldilocks-dashboard"
		servicePort:      80
		ingressClassName: "traefik"
		tlsSecretName:    "\(name)-tls"
		annotations: {
			_internalTarget
			_certIssuer
			_oauthProxyAuth
			"gethomepage.dev/enabled":      "true"
			"gethomepage.dev/name":         "Goldilocks"
			"gethomepage.dev/group":        "Platform"
			"gethomepage.dev/icon":         "kubernetes.png"
			"gethomepage.dev/description":  "VPA recommendations dashboard"
			"gethomepage.dev/href":         "http://goldilocks.example.internal"
			"gethomepage.dev/siteMonitor":  "http://goldilocks.example.internal"
			"gethomepage.dev/pod-selector": "app.kubernetes.io/component=dashboard"
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	// Hubble ingress removed 2026-06-16 — Cilium was reverted to Flannel
	// (2026-05-20), so the hubble-ui backend no longer exists. The route
	// was a dead pointer returning 404.
	// OpenCost ingress removed 2026-05-16 — see helmreleases.cue comment.
	{
		name:             "homepage"
		namespace:        "homepage"
		host:             "home.example.internal"
		serviceName:      "homepage"
		servicePort:      3000
		ingressClassName: "traefik"
		tlsSecretName:    "\(name)-tls"
		// Homepage doesn't need to discover itself, but the target annotation
		// is still needed so external-dns publishes the right LB IP.
		//
		// html-cache Middleware overrides the Next.js `s-maxage=...`
		// Cache-Control (which browsers ignore) with a browser-honoured
		// `public, max-age=300`. Defined in
		// infrastructure/homepage/middleware-html-cache.yaml.
		annotations: {
			_internalTarget
			_certIssuer
			"traefik.ingress.kubernetes.io/router.middlewares": "homepage-html-cache@kubernetescrd"
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// Dex — OIDC issuer at dex.example.com. Two Ingresses for split-
	// horizon: LAN clients reach Dex via Traefik internal LB (fast, no
	// hairpin through Cloudflare); off-LAN clients reach via Cloudflare
	// tunnel. Same backend, same issuer URL — token signing claim
	// matches regardless of which path the browser took.
	{
		name:             "dex"
		namespace:        "dex"
		host:             "dex.example.com"
		serviceName:      "dex"
		servicePort:      5556
		ingressClassName: "traefik"
		tlsSecretName:    "\(name)-tls"
		annotations: {
			_internalTarget
			_publicCertIssuer
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	// Public exposure for off-LAN access. Cloudflared tunnel terminates
	// TLS at Cloudflare edge using their wildcard cert. No `tls:` block
	// on this Ingress — the tunnel controller handles routing and CF
	// edges handles HTTPS. Google sign-in + hostedDomains restriction
	// in Dex's connector gates auth; non-example.com users can't
	// complete the flow even if they reach this URL.
	{
		name:             "dex-public"
		namespace:        "dex"
		host:             "dex.example.com"
		serviceName:      "dex"
		servicePort:      5556
		ingressClassName: "cloudflare-tunnel"
		tier:             C.tier
		cluster:          C.name
		owner:            "platform-team"
	},

	// Jarvy telemetry forwarder — public OTLP/HTTP endpoint for the
	// Jarvy CLI's opt-in telemetry. Cloudflared terminates TLS at the
	// edge with CF's wildcard cert; cluster-internal traffic from the
	// tunnel pod is HTTP.
	//
	// Path was: cloudflared → forwarder Service:4318 (direct, no rate
	// limit). Per the security review, requests now route via Traefik
	// so an in-cluster Middleware can enforce per-IP rate limiting +
	// body-size cap. STRRL's cloudflare-tunnel controller registers
	// this Ingress's backend as the tunnel target — pointing it at
	// the traefik Service means cloudflared forwards to Traefik on
	// port 80. The matching Traefik IngressRoute + rate-limit/body-
	// limit Middlewares live in helmreleases.cue's traefik
	// extraObjects (in the jarvy-telemetry namespace), routing to
	// the forwarder Service:4318 after enforcement.
	//
	// Lives in the traefik namespace because the Ingress backend
	// Service must be in the same namespace — its only purpose now
	// is tunnel registration, not application routing.
	{
		name:             "jarvy-telemetry"
		namespace:        "traefik"
		host:             "jarvyotel.example.com"
		serviceName:      "traefik"
		servicePort:      80
		ingressClassName: "cloudflare-tunnel"
		tier:             C.tier
		cluster:          C.name
		owner:            "platform-team"
	},

	// Friendly alias on the jarvy.dev product domain. STRRL registers
	// this with the same tunnel and creates the proxied CNAME on
	// jarvy.dev (orange cloud → tunnel). Requires jarvy.dev to be on
	// the same Cloudflare account as the tunnel; the STRRL API token
	// must include jarvy.dev in its Zone Resources. The IngressRoute
	// in helmreleases.cue matches both hostnames so rate-limit and
	// body-limit middlewares apply identically.
	{
		name:             "jarvy-telemetry-jarvy-dev"
		namespace:        "traefik"
		host:             "telemetry.jarvy.dev"
		serviceName:      "traefik"
		servicePort:      80
		ingressClassName: "cloudflare-tunnel"
		tier:             C.tier
		cluster:          C.name
		owner:            "platform-team"
	},

	// openbao-ca-page — distributes the OpenBao root CA + per-OS install
	// instructions so household devices can trust *.example.internal
	// certs without browser warnings. Served at ca.example.internal,
	// LAN-only via UniFi A record → Traefik LB. No public DNS, no
	// Cloudflare, no Let's Encrypt.
	//
	// Bypasses Traefik's global HTTP→HTTPS redirect (set on the `web`
	// entrypoint with priority 1000, see helmreleases.cue) by binding
	// explicitly to BOTH entrypoints and raising router priority to
	// 2000. Web router serves plain HTTP directly (so the very first
	// `curl http://ca.example.internal/openbao-root.crt` doesn't try
	// to verify a cert the caller doesn't yet trust — the chicken-and-
	// egg pinch). Websecure router serves HTTPS with the OpenBao-PKI
	// cert for visitors who already have the root installed.
	//
	// Intentionally unauthenticated — the CA cert is a public artifact.
	// Integrity is verified by the SHA-256 digest the page displays
	// alongside the download link.
	{
		name:             "openbao-ca-page"
		namespace:        "cert-distribution"
		host:             "ca.example.internal"
		serviceName:      "openbao-ca-page"
		servicePort:      80
		ingressClassName: "traefik"
		tlsSecretName:    "\(name)-tls"
		annotations: {
			_internalTarget
			_certIssuer
			"traefik.ingress.kubernetes.io/router.entrypoints": "web,websecure"
			"traefik.ingress.kubernetes.io/router.priority":    "2000"
			"gethomepage.dev/enabled":                          "true"
			"gethomepage.dev/name":                             "Trust CA"
			"gethomepage.dev/group":                            "Platform"
			// Sort first within Platform — lowest weight wins; everything
			// else is unweighted (0) and falls back to alphabetical.
			"gethomepage.dev/weight":       "-1000"
			"gethomepage.dev/icon":         "openbao.png"
			"gethomepage.dev/description":  "Install the example.internal root CA"
			"gethomepage.dev/href":         "http://ca.example.internal"
			"gethomepage.dev/siteMonitor":  "http://ca.example.internal"
			"gethomepage.dev/pod-selector": "app.kubernetes.io/name=openbao-ca-page"
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// oauth2-proxy callback endpoint at oauth.example.internal. Browser
	// hits this during the OAuth dance; cookie is set on .example.internal
	// so subsequent visits to OpenCost / Goldilocks / Traefik dashboard
	// skip the sign-in.
	{
		name:             "oauth-proxy"
		namespace:        "oauth-proxy"
		host:             "oauth.example.internal"
		serviceName:      "oauth2-proxy"
		servicePort:      80
		ingressClassName: "traefik"
		tlsSecretName:    "\(name)-tls"
		annotations: {
			_internalTarget
			_certIssuer
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// Traefik dashboard — exposed at traefik.example.internal, gated by
	// oauth2-proxy ForwardAuth middleware. The Traefik chart already
	// creates the `traefik-dashboard` Service (port 8080 internally,
	// servicePort 8080) in the traefik namespace.
	{
		name:             "traefik-dashboard"
		namespace:        "traefik"
		host:             "traefik.example.internal"
		serviceName:      "traefik-dashboard"
		servicePort:      8080
		ingressClassName: "traefik"
		tlsSecretName:    "\(name)-tls"
		annotations: {
			_internalTarget
			_certIssuer
			_oauthProxyAuth
			"gethomepage.dev/enabled":      "true"
			"gethomepage.dev/name":         "Traefik"
			"gethomepage.dev/group":        "Platform"
			"gethomepage.dev/icon":         "traefik.png"
			"gethomepage.dev/description":  "Ingress controller dashboard"
			"gethomepage.dev/href":         "http://traefik.example.internal"
			"gethomepage.dev/siteMonitor":  "http://traefik.example.internal"
			"gethomepage.dev/pod-selector": "app.kubernetes.io/name=traefik"
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// Honcho — self-hosted dialectic memory. Dex-gated so any LAN browser
	// can poke at the FastAPI directly (e.g. for debug). Hermes hits it
	// via the in-cluster Service, not this Ingress.
	{
		name:             "honcho"
		namespace:        "honcho"
		host:             "honcho.example.internal"
		serviceName:      "honcho"
		servicePort:      8000
		ingressClassName: "traefik"
		tlsSecretName:    "\(name)-tls"
		annotations: {
			_internalTarget
			_certIssuer
			_oauthProxyAuth
			"gethomepage.dev/enabled":      "true"
			"gethomepage.dev/name":         "Honcho"
			"gethomepage.dev/group":        "AI"
			"gethomepage.dev/icon":         "openai.png"
			"gethomepage.dev/description":  "Honcho dialectic memory (Dex-gated)"
			"gethomepage.dev/href":         "https://honcho.example.internal/docs"
			"gethomepage.dev/siteMonitor":  "http://honcho.example.internal/health"
			"gethomepage.dev/pod-selector": "app.kubernetes.io/name=honcho"
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// Hermes Dashboard — Admin's profile. Browser entrypoint behind Dex.
	// TUI tab is embedded via PTY/WebSocket (HERMES_DASHBOARD_TUI=1).
	// Dashboard runs in the same pod as the gateway (PID-namespace
	// requirement from Hermes docs).
	{
		name:             "hermes-admin-dashboard"
		namespace:        "hermes"
		host:             "hermes-admin-dashboard.example.internal"
		serviceName:      "hermes-hermes-agent"
		servicePort:      9119
		ingressClassName: "traefik"
		tlsSecretName:    "\(name)-tls"
		annotations: {
			_internalTarget
			_certIssuer
			_oauthProxyAuth
			"gethomepage.dev/enabled":      "true"
			"gethomepage.dev/name":         "Hermes Dashboard (Admin)"
			"gethomepage.dev/group":        "Hermes Profiles"
			"gethomepage.dev/icon":         "openai.png"
			"gethomepage.dev/description":  "Web dashboard + TUI — Admin (Dex-gated)"
			"gethomepage.dev/href":         "https://hermes-admin-dashboard.example.internal"
			"gethomepage.dev/siteMonitor":  "http://hermes-admin-dashboard.example.internal"
			"gethomepage.dev/pod-selector": "app.kubernetes.io/name=hermes-agent"
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// Hermes Dashboard — Alex's profile.
	{
		name:             "hermes-dev2-dashboard"
		namespace:        "hermes"
		host:             "hermes-dev2-dashboard.example.internal"
		serviceName:      "hermes-dev2-hermes-agent"
		servicePort:      9119
		ingressClassName: "traefik"
		tlsSecretName:    "\(name)-tls"
		annotations: {
			_internalTarget
			_certIssuer
			_oauthProxyAuth
			"gethomepage.dev/enabled":      "true"
			"gethomepage.dev/name":         "Hermes Dashboard (Alex)"
			"gethomepage.dev/group":        "Hermes Profiles"
			"gethomepage.dev/icon":         "openai.png"
			"gethomepage.dev/description":  "Web dashboard + TUI — Alex (Dex-gated)"
			"gethomepage.dev/href":         "https://hermes-dev2-dashboard.example.internal"
			"gethomepage.dev/siteMonitor":  "http://hermes-dev2-dashboard.example.internal"
			"gethomepage.dev/pod-selector": "app.kubernetes.io/name=hermes-agent"
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// Hermes Dashboard — red-team profile. The ONLY external entrypoint for
	// the red-team agent (no Bearer API Ingress exists). Dex-gated via
	// oauth2-proxy (_oauthProxyAuth) → only Google-authenticated example-org
	// users get in. /oauth2 routing for this host is added to the hermes
	// oauth bridge in helmreleases.cue.
	{
		name:             "hermes-redteam-dashboard"
		namespace:        "hermes"
		host:             "hermes-redteam-dashboard.example.internal"
		serviceName:      "hermes-redteam-hermes-agent"
		servicePort:      9119
		ingressClassName: "traefik"
		tlsSecretName:    "\(name)-tls"
		annotations: {
			_internalTarget
			_certIssuer
			_oauthProxyAuth
			"gethomepage.dev/enabled":      "true"
			"gethomepage.dev/name":         "Hermes Dashboard (Red-Team)"
			"gethomepage.dev/group":        "Hermes Profiles"
			"gethomepage.dev/icon":         "openai.png"
			"gethomepage.dev/description":  "Autonomous pentest agent — Dex-gated"
			"gethomepage.dev/href":         "https://hermes-redteam-dashboard.example.internal"
			"gethomepage.dev/siteMonitor":  "http://hermes-redteam-dashboard.example.internal"
			"gethomepage.dev/pod-selector": "app.kubernetes.io/name=hermes-agent"
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
]
