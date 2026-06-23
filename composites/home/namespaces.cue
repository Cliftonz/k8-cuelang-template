package home

let C = cluster

// Opt-in label for Goldilocks VPA recommendations dashboard. Goldilocks
// only watches namespaces carrying this label; per-namespace VPAs are
// auto-created in `Off` mode so they don't fight the explicit
// XVerticalPodAutoscaler CRs in verticalpodautoscalers.cue (which run
// in InPlaceOrRecreate mode and actually apply changes).
let _goldilocksOptIn = {"goldilocks.fairwinds.com/enabled": "true"}

namespaces: [
	{
		name:    "traefik"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
		labels:  _goldilocksOptIn
	},
	{
		name:    "longhorn-system"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
		// Longhorn manager needs privileged hostPath mounts; opt this
		// namespace out of the default baseline PSS.
		labels: {
			"pod-security.kubernetes.io/enforce": "privileged"
			"pod-security.kubernetes.io/audit":   "privileged"
			"pod-security.kubernetes.io/warn":    "privileged"
		}
	},
	{
		name:    "metallb-system"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
		// MetalLB speaker uses hostNetwork + NET_RAW capability + hostPorts
		// (7472 metrics, 7946 memberlist). All forbidden under baseline PSS.
		labels: {
			"pod-security.kubernetes.io/enforce": "privileged"
			"pod-security.kubernetes.io/audit":   "privileged"
			"pod-security.kubernetes.io/warn":    "privileged"
		}
	},
	{
		name:    "openbao"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:    "external-secrets"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
		labels:  _goldilocksOptIn
	},
	{
		name:    "external-dns"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
		labels:  _goldilocksOptIn
	},
	{
		name:    "it-tools"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:    "metube"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:    "home-assistant"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:    "n8n"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:    "webui"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:    "recipes"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	{
		name:    "argo-events"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
		labels:  _goldilocksOptIn
	},
	{
		name:    "argo-workflows"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
		// BuildKit rootless workflow pods need to set kernel-level
		// namespace flags (user/mount) and write to /workspace owned by
		// uid 1000. The chart's controller + server stay in `restricted`,
		// but workflow steps run with elevated PSA — annotate the ns
		// `privileged`. Network egress is still constrained by NetworkPolicy.
		labels: _goldilocksOptIn & {
			"pod-security.kubernetes.io/enforce": "privileged"
			"pod-security.kubernetes.io/audit":   "privileged"
			"pod-security.kubernetes.io/warn":    "privileged"
		}
	},
	{
		name:    "argocd"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
		labels:  _goldilocksOptIn
	},
	{
		name:    "cloudflared"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
		labels:  _goldilocksOptIn
	},
	{
		name:    "kelos-system"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
		// kelos operator + spawner pods + claude-code task pods don't set
		// seccompProfile/runAsNonRoot/drop-ALL/allowPrivilegeEscalation:false,
		// so cluster-default `restricted` PSS floods admission warnings on
		// every reconcile. Exempt this ns from warn/audit; pods still run
		// regardless (no enforce label set).
		labels: {
			"pod-security.kubernetes.io/audit": "privileged"
			"pod-security.kubernetes.io/warn":  "privileged"
			"goldilocks.fairwinds.com/enabled": "true"
		}
	},
	// NOTE: This XNamespace XR is paused
	// (`crossplane.io/paused: "true"`) on the live cluster so the
	// kelos Helm chart can adopt the existing namespace. Without
	// the pause, XNamespace's MergeObjects would overwrite Helm's
	// `app.kubernetes.io/managed-by=Helm` label every reconcile
	// and break helm upgrades. The PSA labels above are applied
	// live via `kubectl label` and persist across helm upgrades
	// (Helm doesn't strip foreign labels). On fresh bootstrap,
	// re-apply them manually until the XR can be un-paused.
	{
		name:    "homepage"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
		labels:  _goldilocksOptIn
	},
	{
		name:    "cert-manager"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
		labels:  _goldilocksOptIn
	},
	{
		name:    "vpa-system"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	// Descheduler — periodically rebalances pods off over-utilized
	// nodes onto under-utilized ones. Pairs with VPA: VPA rightsizes
	// individual pods, Descheduler moves pods around the cluster. Both
	// passive — they suggest/evict; the scheduler does the placement.
	{
		name:    "descheduler"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
		labels:  _goldilocksOptIn
	},
	{
		name:    "goldilocks"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
		labels:  _goldilocksOptIn
	},
	// Reloader (stakater) — watches Deployments annotated with
	// `reloader.stakater.com/auto: "true"` and restarts them when their
	// referenced Secrets/ConfigMaps change. Fixes the Dex stale-env-var
	// trap where ESO rotates a Secret on disk but the pod's in-memory
	// env vars (resolved at startup from secretKeyRef) stay stale until
	// the next manual restart.
	{
		name:    "reloader"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
	// OpenCost namespace removed 2026-05-16 — see helmreleases.cue comment.
	{
		name:    "velero"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
		// Velero's node-agent daemonset mounts hostPath
		// (/var/lib/kubelet/pods + /var/lib/kubelet/plugins) so kopia
		// can read pod-volume contents directly off the node. Forbidden
		// under baseline PSS — opt this ns into privileged.
		labels: {
			"pod-security.kubernetes.io/enforce": "privileged"
			"pod-security.kubernetes.io/audit":   "privileged"
			"pod-security.kubernetes.io/warn":    "privileged"
			"goldilocks.fairwinds.com/enabled":   "true"
		}
	},
	// Dex — OIDC issuer bridging Google Workspace to in-cluster
	// consumers (Argo CD, OpenBao, oauth2-proxy). LAN-only via
	// dex.example.com. Public TLD required for Google OAuth client
	// config validation; LAN-only resolution via UniFi DNS, real
	// Let's Encrypt cert via DNS01 + Cloudflare.
	{
		name:    "dex"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
		labels:  _goldilocksOptIn
	},
	// oauth2-proxy — wraps OIDC around apps that don't have native
	// OIDC support (Traefik dashboard, OpenCost, Goldilocks). Single
	// deployment, single Dex static client, cookie scoped to
	// .example.internal so one login covers every protected app.
	{
		name:    "oauth-proxy"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
		labels:  _goldilocksOptIn
	},
	// Jarvy telemetry forwarder — public OTLP forwarder for the Jarvy
	// CLI's opt-in telemetry. Wraps otel/opentelemetry-collector-contrib,
	// PII-anonymizes via salted SHA-256, and ships to Grafana Cloud.
	// Exposed at https://jarvyotel.example.com via Cloudflare Tunnel
	// (STRRL ingress class). Argo CD reconciles from the example-org OCI
	// chart `ghcr.io/example-org/charts/jarvy-telemetry-forwarder`.
	{
		name:    "jarvy-telemetry"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
		labels:  _goldilocksOptIn
	},
	// CloudNativePG — Postgres operator. Reconciles `Cluster` CRs (one per
	// app needing a Postgres instance) into StatefulSets + Services with
	// auto-generated app Secrets containing the connection URI. Used today
	// by Coder; reusable for any future app needing a managed Postgres.
	//
	// Installed via Crossplane (XHelmRelease) rather than the bootstrap
	// `infrastructure/cloudnative-pg/install.sh` path so its lifecycle
	// matches the rest of the platform. Bootstrap script skips
	// `phase_cnpg` when `INSTALL_CNPG=0` is set.
	{
		name:    "cnpg-system"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
		labels:  _goldilocksOptIn
	},
	// Hermes Agent — Nous Research's Hermes Agent, deployed via the
	// vendored ultraworkers chart in infrastructure/hermes-agent/. LAN-only
	// at hermes.example.internal. Single-replica Deployment (chart
	// enforces this when persistence is on) with a 50Gi Longhorn PVC
	// at /opt/data holding HERMES_HOME (conversation history, skills,
	// session FTS DB). API key comes from secret/home/hermes in OpenBao.
	{
		name:    "hermes"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
		labels:  _goldilocksOptIn
	},
	// cert-distribution — serves the OpenBao root CA + per-OS install
	// instructions at https://ca.example.com. Sized for a single nginx
	// pod with two tiny init containers, so no resource-quota gymnastics.
	{
		name:    "cert-distribution"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
		labels:  _goldilocksOptIn
	},
	// Honcho — self-hosted dialectic memory infrastructure for stateful
	// agents (plastic-labs/honcho). Single-pod deployment bundling API +
	// deriver worker + pgvector Postgres + Redis cache. Hermes uses it
	// for cross-session user modeling. Manifests live in
	// infrastructure/honcho/honcho.yaml; ArgoCD Application in argocd.cue.
	{
		name:    "honcho"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
		labels:  _goldilocksOptIn
	},
	// TrueNAS — namespace holds the selectorless Service + EndpointSlice
	// + ServersTransport that front the TrueNAS web UI
	// (https://192.168.1.148:8443) at truenas.example.internal. No
	// workloads run here.
	{
		name:    "truenas"
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
]
