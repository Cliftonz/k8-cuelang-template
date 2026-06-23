package home

let C = cluster

// Sibling ClusterIP Services that exist only to carry omni-kube-service-
// exposer annotations for charts whose own Services we can't safely
// annotate (helm clobbers kubectl-applied annotations on chart-owned
// objects). Selectors must match the chart's pod labels.
exposedServices: [
	{
		name:      "longhorn-frontend-omni"
		namespace: "longhorn-system"
		selector: {app: "longhorn-ui"}
		port:       80
		targetPort: 8000
		omniPort:   50082
		omniLabel:  "Longhorn (home)"
		omniPrefix: "longhornhome"
		tier:       C.tier
		cluster:    C.name
		owner:      "platform-team"
	},
]
