package preview

let C = cluster

// Annotate/label overlays onto Services or other resources we don't own.
// Used when a Helm chart doesn't expose the annotation fields we need.
// See platform/xrd/objectpatch.cue — the Object uses managementPolicies
// [Observe, Update] so it cannot create or delete the target, only update
// the metadata fields listed here.
objectPatches: [
	// MetalLB speaker pods need hostNetwork + NET_RAW + hostPort; the
	// default `baseline` PodSecurity profile rejects all three. Override
	// metallb-system to `privileged` enforce. Without this the speaker
	// DaemonSet can't schedule any pods and LB IPs are never announced.
	{
		name: "metallb-system-psa-privileged"
		targetRef: {
			apiVersion: "v1"
			kind:       "Namespace"
			name:       "metallb-system"
		}
		annotations: {}
		labels: {
			"pod-security.kubernetes.io/enforce": "privileged"
		}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},

	// Expose longhorn-frontend via the Omni workload service proxy.
	// The Longhorn Helm chart (v1.7.2) does not expose service.ui.annotations
	// in values, so we overlay the annotations with an XObjectPatch.
	// Upstream request: docs/support-cases/longhorn-service-annotations.md
	{
		name: "longhorn-frontend-omni-proxy"
		targetRef: {
			apiVersion: "v1"
			kind:       "Service"
			namespace:  "longhorn-system"
			name:       "longhorn-frontend"
		}
		annotations: {
			"omni-kube-service-exposer.sidero.dev/port":   "50082"
			"omni-kube-service-exposer.sidero.dev/label":  "Longhorn"
			"omni-kube-service-exposer.sidero.dev/prefix": "longhorn"
		}
		labels:  {}
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
]
