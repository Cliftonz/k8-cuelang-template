package render

import (
	"strconv"
)

// ServersTransport — Traefik CR. Optional insecureSkipVerify.
#ServersTransportInput: {
	name:                string
	namespace:           string
	tier:                string
	cluster:             string
	owner:               string
	insecureSkipVerify?: bool
}

#RenderServersTransport: {
	in: #ServersTransportInput
	out: {
		apiVersion: "traefik.io/v1alpha1"
		kind:       "ServersTransport"
		metadata: {
			name:      in.name
			namespace: in.namespace
			labels: (#StandardLabels & {tier: in.tier, cluster: in.cluster, owner: in.owner}).out
		}
		if in.insecureSkipVerify != _|_ {
			spec: insecureSkipVerify: in.insecureSkipVerify
		}
	}
}

// ExposedService — ClusterIP Service annotated for omni-kube-service-exposer.
#ExposedServiceInput: {
	name:      string
	namespace: string
	selector: {[string]: string}
	port?:      int
	portName?:  string
	targetPort: int | string
	omniPort:   int
	omniLabel:  string
	omniPrefix: string
	tier:       string
	cluster:    string
	owner:      string
}

#RenderExposedService: {
	in: #ExposedServiceInput
	let _portName = *in.portName | "http"
	let _port = *in.port | 80
	out: {
		apiVersion: "v1"
		kind:       "Service"
		metadata: {
			name:      in.name
			namespace: in.namespace
			labels: (#StandardLabels & {tier: in.tier, cluster: in.cluster, owner: in.owner}).out
			annotations: {
				"omni-kube-service-exposer.sidero.dev/port":   strconv.FormatInt(in.omniPort, 10)
				"omni-kube-service-exposer.sidero.dev/label":  in.omniLabel
				"omni-kube-service-exposer.sidero.dev/prefix": in.omniPrefix
			}
		}
		spec: {
			type:     "ClusterIP"
			selector: in.selector
			ports: [{
				name:       _portName
				port:       _port
				targetPort: in.targetPort
				protocol:   "TCP"
			}]
		}
	}
}

// ExternalBackend — Service + EndpointSlice pair pointing at off-cluster IPs.
// Returns a list of two manifests under .out.
#ExternalBackendInput: {
	name:       string
	namespace:  string
	port:       int
	targetPort: int | string
	addresses: [...string]
	protocol?: "TCP" | "UDP"
	portName?: string
	annotations?: {[string]: string}
	tier:    string
	cluster: string
	owner:   string
}

#RenderExternalBackend: {
	in: #ExternalBackendInput
	let _portName = *in.portName | "http"
	let _proto = *in.protocol | "TCP"
	out: [
		{
			apiVersion: "v1"
			kind:       "Service"
			metadata: {
				name:      in.name
				namespace: in.namespace
				labels: (#StandardLabels & {tier: in.tier, cluster: in.cluster, owner: in.owner}).out
				if in.annotations != _|_ {
					annotations: in.annotations
				}
			}
			spec: {
				ports: [{
					name:       _portName
					port:       in.port
					targetPort: in.targetPort
					protocol:   _proto
				}]
			}
		},
		{
			apiVersion: "discovery.k8s.io/v1"
			kind:       "EndpointSlice"
			metadata: {
				name:      "\(in.name)-1"
				namespace: in.namespace
				labels: {
					(#StandardLabels & {tier: in.tier, cluster: in.cluster, owner: in.owner}).out
					"kubernetes.io/service-name": in.name
				}
			}
			addressType: "IPv4"
			ports: [{
				name:     _portName
				port:     in.targetPort
				protocol: _proto
			}]
			endpoints: [{
				addresses: in.addresses
				conditions: ready: true
			}]
		},
	]
}

// MetalLBPool — IPAddressPool + L2Advertisement pair.
#MetalLBPoolInput: {
	name: string
	addresses: [...string]
	tier:           string
	cluster:        string
	owner:          string
	namespace?:     string
	autoAssign?:    bool
	avoidBuggyIPs?: bool
}

#RenderMetalLBPool: {
	in: #MetalLBPoolInput
	let _ns = *in.namespace | "metallb-system"
	out: [
		{
			apiVersion: "metallb.io/v1beta1"
			kind:       "IPAddressPool"
			metadata: {
				name:      in.name
				namespace: _ns
				labels: (#StandardLabels & {tier: in.tier, cluster: in.cluster, owner: in.owner}).out
			}
			spec: {
				addresses: in.addresses
				if in.autoAssign != _|_ {
					autoAssign: in.autoAssign
				}
				if in.avoidBuggyIPs != _|_ {
					avoidBuggyIPs: in.avoidBuggyIPs
				}
			}
		},
		{
			apiVersion: "metallb.io/v1beta1"
			kind:       "L2Advertisement"
			metadata: {
				name:      in.name
				namespace: _ns
				labels: (#StandardLabels & {tier: in.tier, cluster: in.cluster, owner: in.owner}).out
			}
			spec: ipAddressPools: [in.name]
		},
	]
}
