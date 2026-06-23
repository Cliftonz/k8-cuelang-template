package home

let C = cluster

// Velero backup Schedules for the home cluster. Each entry becomes an
// XBackupPolicy claim, which Crossplane materializes as a velero.io/v1
// Schedule in the velero namespace. Velero's own controller then fires
// Backup CRs on the cron cadence.
//
// What gets volume-backed vs. just resource-backed:
//   - defaultVolumesToFsBackup: true → File System Backup (Kopia/restic
//     Pod Volume Backup). Captures PVC file contents. Required for stateful
//     apps (Postgres, file-backed DBs, agent HERMES_HOME, etc.). This is the
//     ONLY working volume-data path on home — there is no CSI snapshotter,
//     so snapshotVolumes is a no-op here and stays false.
//   - both false → Just k8s manifests + Secrets/ConfigMaps. Sufficient for
//     stateless apps; cheap.
//
// NOTE: snapshotVolumes (native/CSI snapshots) is NOT the FSB toggle. They
// were conflated originally, which silently broke volume backups after the
// 2026-05-21 cluster recreate stripped openbao's per-pod backup-volumes
// annotation (the implicit FSB trigger). defaultVolumesToFsBackup makes FSB
// explicit and recreate-proof.
//
// Default exclusions strip the noisy resources that bloat backups without
// restore value (events, endpoints, endpointslices) — overridable per
// schedule via spec.excludedResources.
//
// Replaces the raw-YAML velero-schedules ApplicationSet (the only
// exception to the CUE → render → reconcile pattern in this repo).
backupPolicies: [
	// OpenBao hourly — every secret in the cluster traces back to this.
	// Already in place pre-GitOps; vendored here so future cluster
	// rebuilds don't need to re-apply by hand.
	{
		name: "velero-openbao-hourly"
		spec: {
			name:               "velero-openbao-hourly"
			schedule:                 "0 * * * *"
			ttl:                      "720h0m0s" // 30 days
			snapshotVolumes:          false
			defaultVolumesToFsBackup: true
			includedNamespaces: ["openbao"]
			tier:               C.tier
			cluster:            C.name
			owner:              "platform-team"
		}
	},

	// Cluster-wide resource snapshot (no volume data). Captures manifests
	// + Secrets so a full DR can replay desired state into a fresh
	// cluster. argo-events excluded because per-PR sensors churn
	// manifests fast enough to bloat backups for no recovery benefit
	// (recreated from ApplicationSet on rebuild anyway).
	{
		name: "velero-cluster-resources-daily"
		spec: {
			name:                    "velero-cluster-resources-daily"
			schedule:                "0 4 * * *"
			ttl:                     "720h0m0s"
			snapshotVolumes:         false
			includeClusterResources: true
			excludedNamespaces: [
				"argo-events",
				"kube-public",
				"kube-node-lease",
			]
			excludedResources: [
				"events",
				"events.events.k8s.io",
				"endpoints",
				"endpointslices",
				"replicasets.apps",
			]
			tier:    C.tier
			cluster: C.name
			owner:   "platform-team"
		}
	},

	// Hermes Agent — both profiles (admin, dev2). 50Gi PVC each holding
	// HERMES_HOME (config, conversation history, sessions, learned
	// skills, FTS DB). Daily cadence is plenty; data grows slowly and
	// conversation loss tolerance is high.
	{
		name: "velero-hermes-daily"
		spec: {
			name:               "velero-hermes-daily"
			schedule:                 "30 3 * * *" // 3:30am local
			ttl:                      "720h0m0s"
			snapshotVolumes:          false
			defaultVolumesToFsBackup: true
			includedNamespaces: ["hermes"]
			tier:               C.tier
			cluster:            C.name
			owner:              "platform-team"
		}
	},

	// Honcho — pgvector Postgres holding all dialectic memory (peer
	// representations, conversation summaries, dream consolidations,
	// vector embeddings). Redis is cache-only emptyDir; not backed up.
	{
		name: "velero-honcho-daily"
		spec: {
			name:               "velero-honcho-daily"
			schedule:                 "45 3 * * *" // 3:45am, offset from Hermes
			ttl:                      "720h0m0s"
			snapshotVolumes:          false
			defaultVolumesToFsBackup: true
			includedNamespaces: ["honcho"]
			tier:               C.tier
			cluster:            C.name
			owner:              "platform-team"
		}
	},
]
