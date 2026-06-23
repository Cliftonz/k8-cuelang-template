package render

// StaticSite — Crossplane-free renderer matching the shape that
// platform/compositions/staticsite.cue produces under the Crossplane
// path. Three resources per claim: ConfigMap, Service, Deployment.
// Returns the list under .out; dispatch in export/raw.cue flattens.
#StaticSiteInput: {
	name:      string
	namespace: string
	tier:      string
	cluster:   string
	owner:     string
	config: {
		image: string
		port?: int
		replicas?: int
		files: {[string]: string}
		initContainers?: [...{...}]
		resources?: {...}
	}
}

#RenderStaticSite: {
	in: #StaticSiteInput
	let _labels = (#StandardLabels & {tier: in.tier, cluster: in.cluster, owner: in.owner}).out
	let _selector = {"app.kubernetes.io/name": in.name}
	let _port = *in.config.port | 8080
	let _replicas = *in.config.replicas | 1
	let _initContainers = *in.config.initContainers | []
	let _resources = *in.config.resources | {}
	out: [
		{
			apiVersion: "v1"
			kind:       "ConfigMap"
			metadata: {
				name:      in.name
				namespace: in.namespace
				labels:    _labels
			}
			data: in.config.files
		},
		{
			apiVersion: "v1"
			kind:       "Service"
			metadata: {
				name:      in.name
				namespace: in.namespace
				labels:    _labels
			}
			spec: {
				type:     "ClusterIP"
				selector: _selector
				ports: [{
					name:       "http"
					port:       80
					targetPort: _port
					protocol:   "TCP"
				}]
			}
		},
		{
			apiVersion: "apps/v1"
			kind:       "Deployment"
			metadata: {
				name:      in.name
				namespace: in.namespace
				labels:    _labels
			}
			spec: {
				replicas: _replicas
				selector: matchLabels: _selector
				template: {
					metadata: labels: _selector
					spec: {
						securityContext: {
							runAsNonRoot: true
							runAsUser:    101
							runAsGroup:   101
							fsGroup:      101
							seccompProfile: type: "RuntimeDefault"
						}
						automountServiceAccountToken: false
						initContainers:               _initContainers
						containers: [{
							name:  "web"
							image: in.config.image
							ports: [{
								name:          "http"
								containerPort: _port
								protocol:      "TCP"
							}]
							resources: _resources
							securityContext: {
								allowPrivilegeEscalation: false
								readOnlyRootFilesystem:   true
								capabilities: drop: ["ALL"]
							}
							volumeMounts: [
								{name: "shared", mountPath:      "/usr/share/nginx/html", readOnly: true},
								{name: "tmp", mountPath:         "/tmp"},
								{name: "nginx-cache", mountPath: "/var/cache/nginx"},
								{name: "nginx-run", mountPath:   "/var/run"},
							]
						}]
						volumes: [
							{name: "configmap", configMap: name: in.name},
							{name: "shared", emptyDir:      {}},
							{name: "tmp", emptyDir:         {}},
							{name: "nginx-cache", emptyDir: {}},
							{name: "nginx-run", emptyDir:   {}},
						]
					}
				}
			}
		},
	]
}
