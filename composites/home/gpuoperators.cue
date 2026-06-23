package home

// NVIDIA GPU Operator opt-in for the home cluster.
//
// Empty by default — flip on by adding an entry below AFTER:
//   1. Re-imaging worker(s) with the Talos schematic that includes
//      siderolabs/nonfree-kmod-nvidia-{lts,production} +
//      siderolabs/nvidia-container-toolkit-{lts,production}.
//      See infrastructure/talos/nvidia-gpu.md.
//   2. Adding a `gpu-operator` namespace to namespaces.cue with PSS
//      `privileged` enforce (operator pods + node-feature-discovery use
//      hostPath, hostPID, privileged containers).
//
// Reference: https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/hardware-and-drivers/nvidia-gpu
gpuOperators: []

// Example (uncomment when GPU node is online):
//
// let C = cluster
//
// gpuOperators: [
// 	{
// 		name:          "nvidia-gpu-operator"
// 		namespace:     "gpu-operator"
// 		chartVersion:  "v25.10.1"
// 		driverVariant: "lts"
// 		extraValues: {
// 			// Single-node homelab — disable MIG, scale daemonset to one node.
// 			mig: strategy: "none"
// 			nodeSelector: "nvidia.com/gpu.present": "true"
// 		}
// 		tier:    C.tier
// 		cluster: C.name
// 		owner:   "platform-team"
// 	},
// ]
