package preview

let C = cluster

// Jobs — one-shot bootstrap tasks that run once per cluster.
jobs: [
	// openbao-bootstrap — initializes a freshly-deployed OpenBao instance:
	//
	//   1. Waits for OpenBao to be reachable
	//   2. If uninitialized: runs `bao operator init` with a single unseal key
	//      and stores both the unseal key and root token in the `openbao-keys`
	//      Secret in the openbao namespace
	//   3. If sealed: reads the unseal key from the Secret and unseals
	//   4. Enables the kubernetes auth method
	//   5. Writes the ESO policy (read-only on secret/data/preview/*)
	//   6. Creates the external-secrets role bound to the ESO service account
	//
	// The Job is idempotent — re-running it against an already-bootstrapped
	// OpenBao is a no-op. This allows the Job to be safely reconciled by
	// Crossplane.
	//
	// IMPORTANT: The `openbao-keys` Secret must be backed up out-of-band.
	// Losing it means losing access to every secret stored in OpenBao.
	{
		name:      "openbao-bootstrap"
		namespace: "openbao"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			backoffLimit:            6
			ttlSecondsAfterFinished: 3600
			template: {
				metadata: labels: "app.kubernetes.io/name": "openbao-bootstrap"
				spec: {
					serviceAccountName: "openbao-bootstrap"
					restartPolicy:      "OnFailure"
					// alpine/k8s is a Google-maintained image that ships with
					// kubectl, curl, jq, and sh — all the tools this Job needs.
					// Runs as UID 65532 (non-root) with a read-only rootfs and
					// a writable /tmp for any transient files.
					containers: [{
						name:  "bootstrap"
						image: "alpine/k8s:1.31.1@sha256:dfe8c7a06c41d0b6e8757da99531f8f302e9a2687fa0155af4c4087df585c9c8"
						securityContext: {
							runAsNonRoot:             true
							runAsUser:                65532
							runAsGroup:               65532
							allowPrivilegeEscalation: false
							readOnlyRootFilesystem:   true
							capabilities: drop: ["ALL"]
							seccompProfile: type: "RuntimeDefault"
						}
						volumeMounts: [{
							name:      "tmp"
							mountPath: "/tmp"
						}]
						resources: {
							requests: {cpu: "50m", memory: "64Mi"}
							limits: {cpu: "200m", memory: "128Mi"}
						}
						env: [
							{name: "BAO_ADDR", value: "http://openbao.openbao.svc.cluster.local:8200"},
							{name: "BAO_FORMAT", value: "json"},
							{name: "HOME", value: "/tmp"},
						]
						command: ["/bin/sh", "-c", #"""
							set -eu

							echo "Waiting for OpenBao to be reachable..."
							for i in $(seq 1 60); do
							  if curl -sf "${BAO_ADDR}/v1/sys/health?uninitcode=200&sealedcode=200" >/dev/null; then
							    break
							  fi
							  sleep 5
							done

							STATUS=$(curl -s "${BAO_ADDR}/v1/sys/health?uninitcode=200&sealedcode=200")
							INITIALIZED=$(echo "$STATUS" | jq -r '.initialized')
							SEALED=$(echo "$STATUS" | jq -r '.sealed')
							echo "initialized=${INITIALIZED} sealed=${SEALED}"

							if [ "$INITIALIZED" = "false" ]; then
							  echo "Initializing OpenBao..."
							  INIT=$(curl -sf -X POST "${BAO_ADDR}/v1/sys/init" \
							    -d '{"secret_shares":1,"secret_threshold":1}')
							  ROOT_TOKEN=$(echo "$INIT" | jq -r '.root_token')
							  UNSEAL_KEY=$(echo "$INIT" | jq -r '.keys[0]')

							  kubectl create secret generic openbao-keys \
							    -n openbao \
							    --from-literal=root-token="$ROOT_TOKEN" \
							    --from-literal=unseal-key="$UNSEAL_KEY" \
							    --dry-run=client -o yaml | kubectl apply -f -
							else
							  echo "Already initialized, loading keys from Secret..."
							  ROOT_TOKEN=$(kubectl get secret openbao-keys -n openbao \
							    -o jsonpath='{.data.root-token}' | base64 -d)
							  UNSEAL_KEY=$(kubectl get secret openbao-keys -n openbao \
							    -o jsonpath='{.data.unseal-key}' | base64 -d)
							fi

							if [ "$SEALED" = "true" ]; then
							  echo "Unsealing OpenBao..."
							  curl -sf -X POST "${BAO_ADDR}/v1/sys/unseal" \
							    -d "{\"key\":\"$UNSEAL_KEY\"}" >/dev/null
							fi

							AUTH="X-Vault-Token: $ROOT_TOKEN"

							echo "Enabling KV v2 secrets engine at secret/..."
							curl -s -X POST -H "$AUTH" \
							  "${BAO_ADDR}/v1/sys/mounts/secret" \
							  -d '{"type":"kv","options":{"version":"2"}}' || true

							echo "Enabling kubernetes auth method..."
							curl -s -X POST -H "$AUTH" \
							  "${BAO_ADDR}/v1/sys/auth/kubernetes" \
							  -d '{"type":"kubernetes"}' || true

							KUBE_CA=$(cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)
							curl -sf -X POST -H "$AUTH" \
							  "${BAO_ADDR}/v1/auth/kubernetes/config" \
							  -d "$(jq -n \
							    --arg host "https://kubernetes.default.svc" \
							    --arg ca "$KUBE_CA" \
							    '{kubernetes_host:$host,kubernetes_ca_cert:$ca,disable_iss_validation:true}')"

							echo "Writing eso-preview-read policy..."
							POLICY='path "secret/data/preview/*" { capabilities = ["read"] }
							path "secret/metadata/preview/*" { capabilities = ["read", "list"] }'
							curl -sf -X PUT -H "$AUTH" \
							  "${BAO_ADDR}/v1/sys/policies/acl/eso-preview-read" \
							  -d "$(jq -n --arg p "$POLICY" '{policy:$p}')"

							echo "Creating external-secrets role..."
							curl -sf -X POST -H "$AUTH" \
							  "${BAO_ADDR}/v1/auth/kubernetes/role/external-secrets" \
							  -d '{
							    "bound_service_account_names":"external-secrets",
							    "bound_service_account_namespaces":"external-secrets",
							    "policies":"eso-preview-read",
							    "ttl":"1h"
							  }'

							echo "Bootstrap complete."
							"""#]
					}]
					volumes: [{
						name: "tmp"
						emptyDir: {}
					}]
				}
			}
		}
	},
]

// ServiceAccounts required by the preview cluster infrastructure.
serviceAccounts: [
	// openbao-bootstrap — used by the OpenBao bootstrap Job to create/read
	// the openbao-keys Secret in the openbao namespace.
	{
		name:      "openbao-bootstrap"
		namespace: "openbao"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},

	// argo-events-sa — used by Argo Events Sensor-triggered Jobs
	// (sync-preview, spawn-agent). Bound to argo-events-sa-role ClusterRole
	// via a RoleBinding in rbac.cue.
	{
		name:      "argo-events-sa"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},

	// preview-reaper — used by the preview-reaper CronJob to list namespaces
	// cluster-wide, list Applications, and delete orphaned preview namespaces.
	// Bound to the preview-reaper ClusterRole via a ClusterRoleBinding.
	{
		name:      "preview-reaper"
		namespace: "argocd"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},

	// kelos-oauth-watchdog — used by the kelos-oauth-watchdog CronJob to
	// read the claude-code-oauth Secret annotation + list Tasks for
	// auth-failure detection. Bound via ClusterRoleBinding.
	{
		name:      "kelos-oauth-watchdog"
		namespace: "kelos-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},

	// feature-orchestrator — used by the feature-review-orchestrator
	// Sensor Job to create Kelos Tasks (tier-2 reviewers, fixer) and
	// read Tasks + PRs. Bound via ClusterRoleBinding.
	{
		name:      "feature-orchestrator"
		namespace: "kelos-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},

	// quiet-hours-toggle — used by quiet-hours-enter + quiet-hours-exit
	// CronJobs to patch TaskSpawners (spec.suspend) and Sensors
	// (spec.replicas) to pause LLM-consuming agents during the
	// operator's active work hours.
	{
		name:      "quiet-hours-toggle"
		namespace: "kelos-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},

]
