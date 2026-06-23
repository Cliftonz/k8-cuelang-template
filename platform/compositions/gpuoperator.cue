package compositions

// GpuOperatorComposition maps an XGpuOperator claim to a Helm provider Release
// for the NVIDIA gpu-operator chart with Talos-friendly defaults baked in.
//
// Defaults (NOT overridable via spec.extraValues — these are Talos-mandatory):
//   driver.enabled    = false   (kmod ships via Talos system extension)
//   toolkit.enabled   = false   (toolkit ships via Talos system extension)
//   operator.runtimeClass = nvidia   (chart auto-creates the RuntimeClass)
//
// Anything else (resource limits, MIG strategy, dcgm-exporter tweaks, etc.)
// goes through spec.extraValues and is merged shallow-over the defaults by
// the patch-and-transform function. Deep merging is not supported — set
// nested keys with full paths.
#GpuOperatorComposition: {
	apiVersion: "apiextensions.crossplane.io/v1"
	kind:       "Composition"
	metadata: {
		name: "gpuoperator-talos"
		labels: {
			"crossplane.io/xrd":    "xgpuoperators.\(#ApiGroup)"
			"infra.k8/composition": "talos"
		}
	}
	spec: {
		compositeTypeRef: {
			apiVersion: "\(#ApiGroup)/v1alpha1"
			kind:       "XGpuOperator"
		}
		mode: "Pipeline"
		pipeline: [{
			step: "patch-and-transform"
			functionRef: name: "crossplane-contrib-function-patch-and-transform"
			input: {
				apiVersion: "pt.fn.crossplane.io/v1beta1"
				kind:       "Resources"
				resources: [{
					name: "release"
					base: {
						apiVersion: "helm.crossplane.io/v1beta1"
						kind:       "Release"
						metadata: name: "gpu-operator"
						spec: {
							providerConfigRef: name: "in-cluster"
							rollbackLimit: 3
							forProvider: {
								chart: {
									name:       "gpu-operator"
									repository: "https://helm.ngc.nvidia.com/nvidia"
									version:    ""
								}
								namespace: ""
								values: {
									// Talos-mandatory defaults — the kmod and
									// container toolkit ship as Talos system
									// extensions, NOT as DaemonSets in-cluster.
									driver: enabled:  false
									toolkit: enabled: false
									operator: {
										// Chart auto-creates RuntimeClass with
										// this name + handler matching it.
										runtimeClass: "nvidia"
										// Forward defaultRuntime hint to the
										// validator so its readiness probe
										// targets nvidia, not the default.
										defaultRuntime: "nvidia"
									}
									// validator runs a CUDA workload that
									// requires the runtime — scope it here
									// so opt-in is one-shot.
									validator: driver: env: [{
										name:  "DISABLE_DEV_CHAR_SYMLINK_CREATION"
										value: "true"
									}]
								}
							}
						}
					}
					patches: [
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.name", toFieldPath: "metadata.name"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.namespace", toFieldPath: "spec.forProvider.namespace"},
						{type: "FromCompositeFieldPath", fromFieldPath: "spec.chartVersion", toFieldPath: "spec.forProvider.chart.version"},
						{
							type:          "FromCompositeFieldPath"
							fromFieldPath: "spec.extraValues"
							toFieldPath:   "spec.forProvider.values"
							policy: fromFieldPath: "Optional"
							// MergeOptions: keep the defaults baked into the
							// base manifest; user-supplied keys win on top.
							mergeOptions: {
								keepMapValues: true
								appendSlice:   false
							}
						},
					]
				}]
			}
		}]
	}
}

gpuOperatorComposition: #GpuOperatorComposition
