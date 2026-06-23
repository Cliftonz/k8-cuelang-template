package preview

let C = cluster

// MetalLB IP pool — single L2 advertisement of LAN IPs that
// LoadBalancer Services in this cluster can claim.
//
// Reserve this range OUTSIDE your UniFi DHCP scope before the
// metallb HelmRelease comes up. UniFi → Settings → Networks →
// (your LAN) → DHCP → set Address Range to end at .239.
metallbPools: [
	{
		name:    "lan"
		addresses: ["192.168.3.221-192.168.3.254"]
		tier:    C.tier
		cluster: C.name
		owner:   "platform-team"
	},
]
