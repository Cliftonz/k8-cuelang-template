package render

#IngressInput: {
	name:              string
	namespace:         string
	host:              string
	serviceName:       string
	servicePort:       int
	tier:              string
	cluster:           string
	owner:             string
	ingressClassName?: string
	tlsSecretName?:    string
	annotations?: {[string]: string}
}

#RenderIngress: {
	in: #IngressInput
	out: {
		apiVersion: "networking.k8s.io/v1"
		kind:       "Ingress"
		metadata: {
			name:      in.name
			namespace: in.namespace
			labels: {
				"app.kubernetes.io/managed-by": "k8-infra"
				"app.kubernetes.io/part-of":    "platform"
				"infra.k8/tier":                in.tier
				"infra.k8/cluster":             in.cluster
				"infra.k8/owner":               in.owner
			}
			if in.annotations != _|_ {
				annotations: in.annotations
			}
		}
		spec: {
			if in.ingressClassName != _|_ {
				ingressClassName: in.ingressClassName
			}
			rules: [{
				host: in.host
				http: paths: [{
					path:     "/"
					pathType: "Prefix"
					backend: service: {
						name: in.serviceName
						port: number: in.servicePort
					}
				}]
			}]
			if in.tlsSecretName != _|_ {
				tls: [{
					secretName: in.tlsSecretName
					hosts: [in.host]
				}]
			}
		}
	}
}
