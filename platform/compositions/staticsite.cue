package compositions

// StaticSiteComposition maps an XStaticSite claim to three resources:
// ConfigMap, Service, Deployment. All three share spec.name as their
// metadata.name — different Kinds, no collision.
//
// Volume contract on the rendered Deployment (these names are stable
// and claim-provided initContainers may reference them):
//   - configmap    — the ConfigMap rendered from spec.config.files.
//                    Mounted only inside init containers (if any).
//   - shared       — emptyDir, mounted at /usr/share/nginx/html in the
//                    web container (read-only). Init containers should
//                    mount it at /shared to write files that nginx then
//                    serves. The pod's fsGroup is 101 so writes by any
//                    container running as UID 101 are readable by the
//                    web container.
//   - tmp,
//     nginx-cache,
//     nginx-run    — emptyDirs at /tmp, /var/cache/nginx, /var/run,
//                    so the web container can run with readOnlyRootFilesystem.
#StaticSiteComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "staticsite-standard"
		labels: {
			"crossplane.io/xrd":    "xstaticsites.\(#ApiGroup)"
			"infra.k8/composition": "standard"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XStaticSite"
		}
		mode: "Pipeline"
		pipeline: [{
			step: "patch-and-transform"
			functionRef: name: "crossplane-contrib-function-patch-and-transform"
			input: {
				apiVersion: "pt.fn.crossplane.io/v1beta1"
				kind:       "Resources"
				resources: [
					{
						name: "configmap"
						base: {
							apiVersion: "kubernetes.crossplane.io/v1alpha2"
							kind:       "Object"
							spec: {
								providerConfigRef: name: "in-cluster"
								forProvider: manifest: {
									apiVersion: "v1"
									kind:       "ConfigMap"
									metadata: labels: {
										"app.kubernetes.io/managed-by": "k8-infra"
										"app.kubernetes.io/part-of":    "platform"
										"infra.k8/tier":                ""
										"infra.k8/cluster":             ""
										"infra.k8/owner":               ""
									}
									data: {}
								}
							}
						}
						patches: [
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.name", toFieldPath: "spec.forProvider.manifest.metadata.name"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.namespace", toFieldPath: "spec.forProvider.manifest.metadata.namespace"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.tier", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/tier\"]"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.cluster", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/cluster\"]"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.owner", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/owner\"]"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.config.files", toFieldPath: "spec.forProvider.manifest.data"},
						]
					},
					{
						name: "service"
						base: {
							apiVersion: "kubernetes.crossplane.io/v1alpha2"
							kind:       "Object"
							spec: {
								providerConfigRef: name: "in-cluster"
								forProvider: manifest: {
									apiVersion: "v1"
									kind:       "Service"
									metadata: labels: {
										"app.kubernetes.io/managed-by": "k8-infra"
										"app.kubernetes.io/part-of":    "platform"
										"infra.k8/tier":                ""
										"infra.k8/cluster":             ""
										"infra.k8/owner":               ""
									}
									spec: {
										type: "ClusterIP"
										selector: "app.kubernetes.io/name": ""
										ports: [{
											name:     "http"
											port:     80
											protocol: "TCP"
											// targetPort patched from spec.config.port
											targetPort: 8080
										}]
									}
								}
							}
						}
						patches: [
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.name", toFieldPath: "spec.forProvider.manifest.metadata.name"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.namespace", toFieldPath: "spec.forProvider.manifest.metadata.namespace"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.tier", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/tier\"]"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.cluster", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/cluster\"]"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.owner", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/owner\"]"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.name", toFieldPath: "spec.forProvider.manifest.spec.selector[\"app.kubernetes.io/name\"]"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.config.port", toFieldPath: "spec.forProvider.manifest.spec.ports[0].targetPort"},
						]
					},
					{
						name: "deployment"
						base: {
							apiVersion: "kubernetes.crossplane.io/v1alpha2"
							kind:       "Object"
							spec: {
								providerConfigRef: name: "in-cluster"
								forProvider: manifest: {
									apiVersion: "apps/v1"
									kind:       "Deployment"
									metadata: labels: {
										"app.kubernetes.io/managed-by": "k8-infra"
										"app.kubernetes.io/part-of":    "platform"
										"infra.k8/tier":                ""
										"infra.k8/cluster":             ""
										"infra.k8/owner":               ""
									}
									spec: {
										// patched from spec.config.replicas
										replicas: 1
										selector: matchLabels: "app.kubernetes.io/name": ""
										template: {
											metadata: labels: "app.kubernetes.io/name": ""
											spec: {
												// fsGroup 101 so any init container running
												// as UID 101 can write to the `shared`
												// emptyDir in a way the web container can
												// then read.
												securityContext: {
													runAsNonRoot: true
													runAsUser:    101
													runAsGroup:   101
													fsGroup:      101
													seccompProfile: type: "RuntimeDefault"
												}
												automountServiceAccountToken: false
												// patched from spec.config.initContainers
												initContainers: []
												containers: [{
													name: "web"
													// patched from spec.config.image
													image: ""
													ports: [{
														name: "http"
														// patched from spec.config.port
														containerPort: 8080
														protocol:      "TCP"
													}]
													// patched from spec.config.resources
													resources: {}
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
													{name: "configmap", configMap: {
														// patched from spec.name
														name: ""
													}},
													{name: "shared", emptyDir:      {}},
													{name: "tmp", emptyDir:         {}},
													{name: "nginx-cache", emptyDir: {}},
													{name: "nginx-run", emptyDir:   {}},
												]
											}
										}
									}
								}
							}
						}
						patches: [
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.name", toFieldPath: "spec.forProvider.manifest.metadata.name"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.namespace", toFieldPath: "spec.forProvider.manifest.metadata.namespace"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.tier", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/tier\"]"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.cluster", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/cluster\"]"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.owner", toFieldPath: "spec.forProvider.manifest.metadata.labels[\"infra.k8/owner\"]"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.name", toFieldPath: "spec.forProvider.manifest.spec.selector.matchLabels[\"app.kubernetes.io/name\"]"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.name", toFieldPath: "spec.forProvider.manifest.spec.template.metadata.labels[\"app.kubernetes.io/name\"]"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.name", toFieldPath: "spec.forProvider.manifest.spec.template.spec.volumes[0].configMap.name"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.config.replicas", toFieldPath: "spec.forProvider.manifest.spec.replicas"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.config.image", toFieldPath: "spec.forProvider.manifest.spec.template.spec.containers[0].image"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.config.port", toFieldPath: "spec.forProvider.manifest.spec.template.spec.containers[0].ports[0].containerPort"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.config.resources", toFieldPath: "spec.forProvider.manifest.spec.template.spec.containers[0].resources"},
							{type: "FromCompositeFieldPath", fromFieldPath: "spec.config.initContainers", toFieldPath: "spec.forProvider.manifest.spec.template.spec.initContainers"},
						]
					},
				]
			}
		}]
	}
}

staticSiteComposition: #StaticSiteComposition
