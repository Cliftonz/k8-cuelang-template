package xrd

// XBackupPolicy defines the CompositeResourceDefinition for Velero
// backup Schedule resources. A claim becomes a velero.io/v1 Schedule
// in the velero namespace, owned + GitOps-reconciled via Crossplane
// provider-kubernetes.
//
// Volume data capture — two independent Velero mechanisms, do not
// confuse them:
//
//   defaultVolumesToFsBackup — File System Backup (Kopia / restic Pod
//     Volume Backup). Walks every pod volume in scope and backs up PVC
//     file contents. This is what actually captures stateful data on
//     this cluster — there is NO CSI VolumeSnapshotClass installed, so
//     it is the only working path. Set true for stateful workloads
//     (Postgres, file-backed DBs, agent HERMES_HOME).
//
//   snapshotVolumes — native / CSI volume snapshots. Requires a
//     VolumeSnapshotClass + CSI snapshotter (absent here). Leaving it
//     true with no snapshotter just produces per-PVC errors, so FSB
//     schedules set it false.
//
// Two supported shapes via the same XRD:
//
//   namespace-scoped — set spec.includedNamespaces to a single-element
//     list and spec.defaultVolumesToFsBackup: true. Use for stateful
//     workloads where PVC contents matter.
//
//   cluster-wide — leave spec.includedNamespaces empty and set
//     spec.includeClusterResources: true. Captures manifests only
//     (defaultVolumesToFsBackup false to keep them cheap). Combine with
//     spec.excludedNamespaces and spec.excludedResources to avoid
//     backing up noisy churners (argo-events sensor pods, events,
//     endpoints, etc.).
#XBackupPolicy: {
	apiVersion: "apiextensions.crossplane.io/v2"
	kind:       "CompositeResourceDefinition"
	metadata: name: "xbackuppolicies.\(#ApiGroup)"
	spec: {
		group: #ApiGroup
		scope: "Cluster"
		names: {
			kind:   "XBackupPolicy"
			plural: "xbackuppolicies"
		}
		versions: [{
			name:          "v1alpha1"
			served:        true
			referenceable: true
			schema: openAPIV3Schema: {
				type:        "object"
				description: "Request a Velero backup Schedule."
				properties: spec: {
					type:        "object"
					description: "Backup Schedule settings."
					properties: {
						name: {
							type:        "string"
							description: "Schedule resource name (velero/Schedule)."
							pattern:     "^[a-z][a-z0-9-]*$"
						}
						schedule: {
							type:        "string"
							description: "Cron expression for backup cadence."
						}
						ttl: {
							type:        "string"
							description: "Retention duration (Go duration string, e.g. 720h0m0s for 30 days)."
							default:     "720h0m0s"
						}
						snapshotVolumes: {
							type:        "boolean"
							description: "Run native/CSI volume snapshots. Requires a VolumeSnapshotClass (not installed on home) — leave false and use defaultVolumesToFsBackup for file-based data capture."
							default:     false
						}
						defaultVolumesToFsBackup: {
							type:        "boolean"
							description: "File System Backup (kopia/restic Pod Volume Backup) of all in-scope pod volumes. The only working volume-data path on home (no CSI snapshotter). Set true for stateful workloads."
							default:     false
						}
						includedNamespaces: {
							type:        "array"
							description: "Namespaces to include. Leave empty for cluster-wide (requires includeClusterResources=true)."
							items: type: "string"
							default: []
						}
						excludedNamespaces: {
							type:        "array"
							description: "Namespaces to exclude. Useful for cluster-wide schedules."
							items: type: "string"
							default: []
						}
						excludedResources: {
							type:        "array"
							description: "Resource kinds to skip. Defaults strip the noisy ones (events, endpoints) that bloat backups without restore value."
							items: type: "string"
							default: ["events", "events.events.k8s.io", "endpoints", "endpointslices"]
						}
						includeClusterResources: {
							type:        "boolean"
							description: "Capture cluster-scoped resources (PVs, CRDs, ClusterRoles, etc.). Set true for full DR snapshots."
							default:     false
						}
						selector: {
							type:        "object"
							description: "Optional label selector to scope to a subset of resources within included namespaces."
							additionalProperties: {type: "string"}
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
							description: "Team or service that owns this Schedule."
						}
					}
					required: ["name", "schedule", "tier", "cluster", "owner"]
				}
			}
		}]
	}
}

xBackupPolicy: #XBackupPolicy
