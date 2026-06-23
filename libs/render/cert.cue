package render

#CertificateInput: #NamespacedConfigInput

#RenderCertificate: {
	in: #CertificateInput
	out: {
		apiVersion: "cert-manager.io/v1"
		kind:       "Certificate"
		metadata: {
			name:      in.name
			namespace: in.namespace
			labels: (#StandardLabels & {tier: in.tier, cluster: in.cluster, owner: in.owner}).out
		}
		spec: in.config
	}
}
