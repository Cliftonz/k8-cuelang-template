package render

#StorageClassInput: {
	name:                 string
	provisioner:          string
	reclaimPolicy:        string
	allowVolumeExpansion: bool
	volumeBindingMode:    string
	parameters: {[string]: string}
	tier:    string
	cluster: string
	owner:   string
}

#RenderStorageClass: {
	in: #StorageClassInput
	out: {
		apiVersion: "storage.k8s.io/v1"
		kind:       "StorageClass"
		metadata: {
			name: in.name
			labels: (#StandardLabels & {tier: in.tier, cluster: in.cluster, owner: in.owner}).out
		}
		provisioner:          in.provisioner
		reclaimPolicy:        in.reclaimPolicy
		allowVolumeExpansion: in.allowVolumeExpansion
		volumeBindingMode:    in.volumeBindingMode
		parameters:           in.parameters
	}
}
