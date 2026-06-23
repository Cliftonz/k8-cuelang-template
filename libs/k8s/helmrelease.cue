package k8s

// STATUS (2026-05-15): SCHEMA-ONLY — not wired into any composite yet.
// composites/home/helmreleases.cue still uses the raw XHelmRelease
// claim shape directly. To activate this contract:
//
//   1. Refactor each helmreleases.cue entry to use `#HelmRelease` from
//      this package (adds the `egress: #HelmReleaseEgress` requirement).
//   2. Update the renderer (libs/render/...) to emit a paired
//      NetworkPolicy from `egress` for each release.
//   3. Drop the manually-authored NPs in composites/home/networkpolicies.cue
//      that the egress rule now generates.
//
// Estimated effort: ~half-day for the 22 home releases. Postponed
// indefinitely; in the meantime, NP coverage is hand-maintained in
// composites/home/networkpolicies.cue (every helmrelease ns now has
// an NP — see commit 1c42b14 which closed the last 5 gaps).
//
// #HelmRelease is the composite-author input contract for every Helm
// install on a cluster. Holds the chart reference + values, plus an
// explicit egress declaration that the renderer turns into a paired
// NetworkPolicy. Authoring a HelmRelease without declaring egress fails
// `cue vet` — the goal is to catch the "Flannel didn't enforce so I
// never thought about it" class of bug at validation time, not at the
// next CNI migration.
//
// Lessons baked in:
//   - Flannel did not enforce NetworkPolicy. We migrated to Cilium
//     2026-05-06 and discovered ~7 silent NP misconfigurations whose
//     pods only worked because no policy was ever evaluated. This
//     contract makes the egress shape a required field so it's
//     reviewed at PR time alongside the chart bump.
//   - kube-apiserver is special under Cilium kube-proxy replacement
//     (reserved identity, doesn't match ipBlock CIDR rules) — model it
//     as a boolean instead of asking authors to remember the
//     `allow-egress-to-kube-apiserver` CCNP.
//   - Most workloads want intra-namespace traffic. Default it on; opt
//     out for namespaces that genuinely have one pod (e.g. Cloudflared).
#HelmRelease: {
	name:      string & =~"^[a-z][a-z0-9-]*$"
	namespace: string & =~"^[a-z][a-z0-9-]*$"
	chart: {
		name:       string
		repository: string
		version:    string
	}
	values?: {...}
	tier:    "dev" | "staging" | "production"
	cluster: string
	owner:   string

	// Egress declaration. Required. Used by the renderer to compose the
	// NetworkPolicy that lives in the same composite. Set fields to the
	// minimum the workload actually needs — `cue vet` does not enforce
	// least-privilege but PR review should.
	egress: #HelmReleaseEgress
}

#HelmReleaseEgress: {
	// kube-apiserver via the cluster Service VIP. Almost every controller
	// needs this. Enforced at runtime via the
	// allow-egress-to-kube-apiserver CCNP (additive,
	// enableDefaultDeny=false) — see
	// infrastructure/cilium/ccnp-allow-kube-apiserver.yaml.
	kubeApiserver: bool | *true

	// CoreDNS via 10.96.0.10:53 (UDP+TCP). Anything that resolves DNS
	// names needs this; effectively always true.
	dns: bool | *true

	// Allow pods in this namespace to talk to each other. Default on
	// because most charts ship with internal Service discovery
	// (operator↔webhook, server↔redis, sensors↔eventbus). Set to false
	// only if you've confirmed the chart genuinely has a single pod or
	// uses hostNetwork.
	intraNamespace: bool | *true

	// Names of OTHER namespaces this workload talks to. Renders as
	// `to: [{namespaceSelector: matchLabels.kubernetes.io/metadata.name: <ns>}]`
	// without a port restriction (we usually don't know which port a
	// downstream chart will use, and same-cluster trust is implicit).
	// Enumerate explicitly — `[]` means "no other namespaces".
	inClusterNamespaces: [...string]

	// External CIDR + port allowances. Use for chart repos, OCI registries,
	// upstream APIs. CIDR `0.0.0.0/0` is fine for HTTPS to the public
	// internet — that doesn't match the kube-apiserver identity even
	// with policyCIDRMatchMode=nodes.
	external: [...{
		cidr: string
		ports: [...{
			port:     int & >0 & <65536
			protocol: "TCP" | "UDP"
		}]
	}]

	// Egress to node IPs (kubelet on 10250 for cAdvisor, kube-proxy on
	// 10249, metrics-server scraping). Requires Cilium's
	// `policyCIDRMatchMode: [nodes]` (set in
	// infrastructure/cilium/values.yaml). Each entry is rendered as
	// `to: [{ipBlock: 0.0.0.0/0}]` with the listed ports.
	nodes: [...{
		port:     int & >0 & <65536
		protocol: "TCP" | "UDP"
	}]

	// Allow ingress from listed namespaces (e.g. Traefik for ingress
	// controllers, Prometheus for metrics scrape). Each entry renders
	// as a NetworkPolicy ingress rule from that namespace, no port
	// restriction. Empty = no other namespaces can reach this workload.
	ingressFromNamespaces: [...string]
}
