package xrd

// XVerticalPodAutoscaler — wraps autoscaling.k8s.io/v1 VerticalPodAutoscaler.
// VPA observes resource usage of the targeted workload and either:
//   - records recommendations (updateMode: Off), or
//   - evicts pods so they restart with new resources (updateMode: Auto), or
//   - resizes pods in-place when possible, falling back to evict
//     (updateMode: InPlaceOrRecreate — K8s 1.33+ beta).
//
// In-place resize requires:
//   - K8s ≥ 1.33 with InPlacePodVerticalScaling feature gate (default-on
//     since 1.34/1.36)
//   - VPA ≥ 1.4 with the InPlaceOrRecreate feature gate
//   - For zero-restart resize: container.resizePolicy on the target Pod
//     spec set to NotRequired for the resource(s) being changed.
//     Without this, the kubelet still restarts the container even
//     though the Pod itself is preserved.
//
// Reference:
//   https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler
//   https://kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources/
#XVerticalPodAutoscaler: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xverticalpodautoscalers.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XVerticalPodAutoscaler"
			plural: "xverticalpodautoscalers"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a VerticalPodAutoscaler for a workload."
				properties: spec: {
					type:        "object"
					description: "VPA target + update policy."
					properties: {
						name: {
							type:        "string"
							description: "VPA resource name."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Namespace where the target workload lives."
						}
						targetRef: {
							type:        "object"
							description: "Workload the VPA observes + (optionally) resizes."
							properties: {
								apiVersion: {
									type:        "string"
									description: "Target apiVersion (e.g. apps/v1)."
								}
								kind: {
									type:        "string"
									description: "Target kind (Deployment, StatefulSet, DaemonSet, ...)."
								}
								name: {
									type:        "string"
									description: "Target resource name."
								}
							}
							required: ["apiVersion", "kind", "name"]
						}
						updateMode: {
							type: "string"
							description: """
								VPA update behavior:
								  - Off: only emit recommendations (no eviction).
								  - Initial: apply recommendations only at pod create.
								  - Recreate: evict pods to apply new resources.
								  - Auto: same as Recreate (default).
								  - InPlaceOrRecreate: try in-place resize first,
								    fall back to eviction. Requires K8s 1.33+.
								"""
							enum: ["Off", "Initial", "Recreate", "Auto", "InPlaceOrRecreate"]
							default: "Off"
						}
						resourcePolicy: {
							type: "object"
							description: """
								Per-container caps on what VPA can recommend.
								containerPolicies[0].containerName=\"*\" applies to
								all containers. Use minAllowed / maxAllowed to bound
								recommendations.
								"""
							"x-kubernetes-preserve-unknown-fields": true
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
							description: "Team or service that owns this VPA."
						}
					}
					required: ["name", "namespace", "targetRef", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xVerticalPodAutoscaler: #XVerticalPodAutoscaler
