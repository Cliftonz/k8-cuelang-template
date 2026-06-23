package xrd

// XGpuOperator defines the CompositeResourceDefinition for installing the
// NVIDIA GPU Operator on Talos. The composition wraps a Helm Release with
// Talos-required defaults: driver disabled (kmod ships via the
// siderolabs/nonfree-kmod-nvidia-* extension), toolkit disabled (the
// siderolabs/nvidia-container-toolkit-* extension owns containerd config),
// runtimeClass forced to `nvidia` so workloads land on the right runtime.
//
// Talos prereqs (machine-image schematic — see infrastructure/talos/nvidia-gpu.md):
//   - siderolabs/nonfree-kmod-nvidia-{lts|production}
//   - siderolabs/nvidia-container-toolkit-{lts|production}
//
// Reference: https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/hardware-and-drivers/nvidia-gpu
#XGpuOperator: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xgpuoperators.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XGpuOperator"
			plural: "xgpuoperators"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request an NVIDIA GPU Operator install with Talos-friendly defaults."
				properties: spec: {
					type:        "object"
					description: "GPU operator settings and ownership metadata."
					example: {
						name:          "nvidia-gpu-operator"
						namespace:     "gpu-operator"
						chartVersion:  "v25.10.1"
						driverVariant: "lts"
						extraValues: {}
						tier:    "production"
						cluster: "home"
						owner:   "platform-team"
					}
					"x-docs": {
						provider: "provider-helm"
						policyRefs: []
						behavior: [
							"Installs the nvcr.io/nvidia/charts/gpu-operator chart with driver+toolkit disabled.",
							"Talos provides the kernel module + container toolkit via system extensions.",
							"The chart auto-creates the `nvidia` RuntimeClass; pods request it via runtimeClassName.",
						]
						gotchas: [
							"Target nodes MUST be booted from a Talos image with the nvidia kmod + toolkit extensions baked in (see docs/talos schematic).",
							"driverVariant must match the extension family installed on the node (lts vs production); mismatch leaves containerd unable to load nvidia.",
							"Namespace must be created separately (XNamespace claim) — the composition does not own the namespace lifecycle.",
						]
					}
					properties: {
						name: {
							type:        "string"
							description: "Helm release name. DNS-1123."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						namespace: {
							type:        "string"
							description: "Namespace where the GPU operator will be installed."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						chartVersion: {
							type:        "string"
							description: "nvidia/gpu-operator chart version (e.g. v25.10.1)."
						}
						driverVariant: {
							type:        "string"
							description: "Talos kmod extension variant the cluster nodes booted with. Used for the operator.runtimeClass label only — the actual kernel module ships in the Talos image."
							enum: ["lts", "production"]
							default: "lts"
						}
						extraValues: {
							type:                                   "object"
							description:                            "Additional Helm values merged on top of the Talos-required defaults. Anything set here overrides the defaults — use sparingly."
							"x-kubernetes-preserve-unknown-fields": true
						}
						tier: {
							type:        "string"
							description: "Tier used for labeling and policy selection."
							enum: ["dev", "staging", "production"]
						}
						cluster: {
							type:        "string"
							description: "Logical cluster identifier."
						}
						owner: {
							type:        "string"
							description: "Owning team or service."
						}
					}
					required: ["name", "namespace", "chartVersion", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xGpuOperator: #XGpuOperator
