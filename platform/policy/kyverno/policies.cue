package kyverno

// Kyverno policy set selection.
_policyVersion: *"v1" | string @tag(kyvernoPolicyVersion)

policiesByVersion: {
	v1: [
		{
			apiVersion: "kyverno.io/v1"
			kind:       "ClusterPolicy"
			metadata: {
				name: "probes-distinct-liveness-readiness"
				labels: {
					"app.kubernetes.io/managed-by": "k8-infra"
				}
			}
			spec: {
				validationFailureAction: "Audit"
				validationFailureActionOverrides: [{
					action: "Enforce"
					namespaceSelector: {
						matchExpressions: [{
							key:      "infra.k8/tier"
							operator: "In"
							values: ["staging", "production"]
						}]
					}
				}]
				background: true
				rules: [{
					name: "deny-same-httpget-endpoint"
					match: {
						resources: {
							kinds: ["Pod"]
						}
					}
					exclude: {
						resources: {
							namespaces: ["kube-system", "kyverno"]
						}
					}
					validate: {
						message: "Use distinct liveness and readiness HTTP endpoints or different thresholds."
						foreach: [{
							list: "request.object.spec.containers"
							preconditions: {
								all: [
									{
										key:      "{{ element.livenessProbe.httpGet }}"
										operator: "NotEquals"
										value:    null
									},
									{
										key:      "{{ element.readinessProbe.httpGet }}"
										operator: "NotEquals"
										value:    null
									},
								]
							}
							deny: {
								conditions: {
									all: [
										{
											key:      "{{ element.livenessProbe.httpGet.path || '' }}"
											operator: "Equals"
											value:    "{{ element.readinessProbe.httpGet.path || '' }}"
										},
										{
											key:      "{{ element.livenessProbe.httpGet.port || '' }}"
											operator: "Equals"
											value:    "{{ element.readinessProbe.httpGet.port || '' }}"
										},
										{
											key:      "{{ element.livenessProbe.httpGet.scheme || 'HTTP' }}"
											operator: "Equals"
											value:    "{{ element.readinessProbe.httpGet.scheme || 'HTTP' }}"
										},
									]
								}
							}
						}]
					}
				}]
			}
		},
		{
			apiVersion: "kyverno.io/v1"
			kind:       "ClusterPolicy"
			metadata: {
				name: "probes-liveness-reasonable-thresholds"
				labels: {
					"app.kubernetes.io/managed-by": "k8-infra"
				}
			}
			spec: {
				validationFailureAction: "Audit"
				validationFailureActionOverrides: [{
					action: "Enforce"
					namespaceSelector: {
						matchExpressions: [{
							key:      "infra.k8/tier"
							operator: "In"
							values: ["staging", "production"]
						}]
					}
				}]
				background: true
				rules: [{
					name: "require-min-liveness-thresholds"
					match: {
						resources: {
							kinds: ["Pod"]
						}
					}
					exclude: {
						resources: {
							namespaces: ["kube-system", "kyverno"]
						}
					}
					validate: {
						message: "Liveness probes must allow at least 5s between checks and 3 failures before restart."
						foreach: [{
							list: "request.object.spec.containers"
							preconditions: {
								all: [{
									key:      "{{ element.livenessProbe }}"
									operator: "NotEquals"
									value:    null
								}]
							}
							deny: {
								conditions: {
									any: [
										{
											key:      "{{ element.livenessProbe.periodSeconds || 10 }}"
											operator: "LessThan"
											value:    5
										},
										{
											key:      "{{ element.livenessProbe.failureThreshold || 3 }}"
											operator: "LessThan"
											value:    3
										},
									]
								}
							}
						}]
					}
				}]
			}
		},
		{
			apiVersion: "kyverno.io/v1"
			kind:       "ClusterPolicy"
			metadata: {
				name: "probes-require-startup-probe"
				labels: {
					"app.kubernetes.io/managed-by": "k8-infra"
				}
			}
			spec: {
				validationFailureAction: "Audit"
				validationFailureActionOverrides: [{
					action: "Enforce"
					namespaceSelector: {
						matchExpressions: [{
							key:      "infra.k8/tier"
							operator: "In"
							values: ["staging", "production"]
						}]
					}
				}]
				background: true
				rules: [{
					name: "require-startup-probe-when-liveness-is-early"
					match: {
						resources: {
							kinds: ["Pod"]
						}
					}
					exclude: {
						resources: {
							namespaces: ["kube-system", "kyverno"]
						}
					}
					validate: {
						message: "Add a startupProbe or increase liveness initialDelaySeconds for slow-starting apps."
						foreach: [{
							list: "request.object.spec.containers"
							preconditions: {
								all: [
									{
										key:      "{{ element.livenessProbe }}"
										operator: "NotEquals"
										value:    null
									},
									{
										key:      "{{ element.startupProbe }}"
										operator: "Equals"
										value:    null
									},
								]
							}
							deny: {
								conditions: {
									all: [{
										key:      "{{ element.livenessProbe.initialDelaySeconds || 0 }}"
										operator: "LessThan"
										value:    30
									}]
								}
							}
						}]
					}
				}]
			}
		},
		{
			apiVersion: "kyverno.io/v1"
			kind:       "ClusterPolicy"
			metadata: {
				name: "pdb-avoid-blocking-disruptions"
				labels: {
					"app.kubernetes.io/managed-by": "k8-infra"
				}
			}
			spec: {
				validationFailureAction: "Audit"
				validationFailureActionOverrides: [{
					action: "Enforce"
					namespaceSelector: {
						matchExpressions: [{
							key:      "infra.k8/tier"
							operator: "In"
							values: ["staging", "production"]
						}]
					}
				}]
				background: true
				rules: [{
					name: "disallow-pdb-that-blocks-disruptions"
					match: {
						resources: {
							kinds: ["PodDisruptionBudget"]
						}
					}
					exclude: {
						resources: {
							namespaces: ["kube-system", "kyverno"]
						}
					}
					validate: {
						message: "Avoid PDBs that block voluntary disruptions (minAvailable=100% or maxUnavailable=0)."
						deny: {
							conditions: {
								any: [
									{
										key:      "{{ request.object.spec.minAvailable || '' }}"
										operator: "Equals"
										value:    "100%"
									},
									{
										key:      "{{ request.object.spec.maxUnavailable || '' }}"
										operator: "Equals"
										value:    0
									},
									{
										key:      "{{ request.object.spec.maxUnavailable || '' }}"
										operator: "Equals"
										value:    "0"
									},
								]
							}
						}
					}
				}]
			}
		},
		{
			apiVersion: "kyverno.io/v1"
			kind:       "ClusterPolicy"
			metadata: {
				name: "require-team-contact"
				labels: {
					"app.kubernetes.io/managed-by": "k8-infra"
				}
			}
			spec: {
				validationFailureAction: "Enforce"
				background:              true
				rules: [{
					name: "require-team-contact-metadata"
					match: {
						any: [{
							resources: {
								kinds: ["Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"]
								namespaceSelector: {
									matchLabels: {
										"app-dev": "true"
									}
								}
							}
						}]
					}
					exclude: {
						any: [{
							resources: {
								namespaces: ["kube-system", "kyverno"]
							}
						}]
					}
					validate: {
						message: "Workloads must include metadata for owning team and contact information. Add labels app.kubernetes.io/team and app.kubernetes.io/contact."
						pattern: {
							metadata: {
								labels: {
									"app.kubernetes.io/team":    "?*"
									"app.kubernetes.io/contact": "?*"
								}
							}
						}
					}
				}]
			}
		},
	]
}

policies: policiesByVersion[_policyVersion]
