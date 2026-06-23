package home

let C = cluster

// Two MetalLB pools, one per L2 segment the reverse-proxy serves.
// Both opt-in (autoAssign:false) so Services must explicitly pick a pool
// via `metallb.universe.tf/address-pool` annotation — prevents a random
// workload Service from grabbing a DMZ IP.
//
// Reserve both ranges OUTSIDE the UniFi DHCP scope before apply.
// Node NIC on vlan10 is required for the `lan-internal` pool to actually
// ARP-announce on the internal segment.
metallbPools: [
	{
		name: "lan-dmz"
		addresses: ["192.168.2.240-192.168.2.250"]
		autoAssign: false
		tier:       C.tier
		cluster:    C.name
		owner:      "platform-team"
	},
	{
		name: "lan-internal"
		addresses: ["192.168.1.235-192.168.1.239"]
		autoAssign: false
		tier:       C.tier
		cluster:    C.name
		owner:      "platform-team"
	},
]
