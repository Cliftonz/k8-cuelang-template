package k8s

// TaintEffect defines the valid Kubernetes taint effects.
#TaintEffect: "NoSchedule" | "NoExecute" | "PreferNoSchedule"

// Taint defines a single Kubernetes node taint.
#Taint: {
	key:    string & =~"^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$"
	value?: string
	effect: #TaintEffect
}

// NodeTaint binds a list of taints to a specific node by name.
#NodeTaint: {
	nodeName: string & =~"^[a-z][a-z0-9.-]*$"
	taints: [...#Taint] & [_, ...]
}
