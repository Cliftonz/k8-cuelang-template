package xrd

// XStaticSite provisions a small read-only HTTP server (intended for
// nginx-unprivileged or a compatible image) that serves files materialized
// into an emptyDir at /usr/share/nginx/html by init containers at pod
// startup.
//
// Render shape (per claim):
//   - ConfigMap <name>        — keys from spec.config.files. Mounted in
//                                init containers at /configmap, never on
//                                the web container.
//   - Service   <name>        — ClusterIP, port 80 → containerPort.
//   - Deployment <name>       — single container, read-only root FS,
//                                runs as UID 101 (nginx-unprivileged
//                                default). The web container's html root
//                                is an emptyDir named `shared`.
//
// Volume contract (the names below are stable; claim-provided init
// containers reference them):
//   - configmap  — the ConfigMap mount. Read-only.
//   - shared     — emptyDir mounted at /usr/share/nginx/html in the
//                   web container (read-only there). Init containers
//                   should mount it at /shared and write files to it.
//   - tmp, nginx-cache, nginx-run — writable emptyDirs the nginx-
//                   unprivileged image needs when root FS is read-only.
//
// The claim is responsible for the full `initContainers` list. For the
// common case of "copy the ConfigMap into /shared" the claim typically
// includes a busybox `cp -L /configmap/. /shared/` step as the first
// init container. Subsequent init containers can mount `shared` to add
// runtime-fetched files (e.g. pulling a cert from an internal service).
//
// Why not a Helm chart: every existing chart that does this (bjw-s
// app-template, bitnami nginx) carries surface area we don't need.
// One opinionated XRD keeps the contract narrow and the rendered YAML
// auditable.
#XStaticSite: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xstaticsites.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XStaticSite"
			plural: "xstaticsites"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "An opinionated read-only static-content HTTP server."
				properties: spec: {
					type:        "object"
					description: "Desired static-site shape and placement metadata."
					properties: {
						name: {
							type:        "string"
							description: "Used as the name of every rendered resource (ConfigMap, Service, Deployment)."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Namespace where all resources are created."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						tier: {
							type:        "string"
							description: "Deployment tier."
							enum: ["dev", "staging", "production"]
						}
						cluster: {
							type:        "string"
							description: "Target cluster name."
						}
						owner: {
							type:        "string"
							description: "Owning team or service."
						}
						config: {
							type:        "object"
							description: "Web server, content, and pod-level configuration."
							properties: {
								image: {
									type:        "string"
									description: "Container image for the web server. Must listen on `port` as UID 101, serve from /usr/share/nginx/html, and tolerate a read-only root filesystem with writable /tmp /var/cache/nginx /var/run."
								}
								port: {
									type:        "integer"
									description: "Container port the web server listens on. Service is created at port 80 → this port."
									default:     8080
								}
								replicas: {
									type:        "integer"
									description: "Desired replica count."
									default:     1
								}
								files: {
									type:        "object"
									description: "Files to serve. Keys are filenames, values are the file body. Rendered into the ConfigMap and copied to /shared by the built-in init container."
									additionalProperties: type: "string"
								}
								initContainers: {
									type:        "array"
									description: "Additional init containers that run after the built-in copy step. They should mount the `shared` emptyDir at /shared and run as UID 101. Pass-through PodSpec init container schema."
									default: []
									items: {
										type:                                   "object"
										"x-kubernetes-preserve-unknown-fields": true
									}
								}
								resources: {
									type:        "object"
									description: "Resource requests/limits for the web container. Pass-through K8s ResourceRequirements schema."
									"x-kubernetes-preserve-unknown-fields": true
								}
							}
							required: ["image", "files"]
						}
					}
					required: ["name", "namespace", "tier", "cluster", "owner", "config"]
				}
			}
		}]
	}
}

xStaticSite: #XStaticSite
