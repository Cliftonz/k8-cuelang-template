package home

let C = cluster

// openbao-bootstrap — initializes OpenBao on the home cluster:
//   1. Waits for the OpenBao pod to be reachable.
//   2. If uninitialized: runs `bao operator init` with a single unseal
//      key and persists both the unseal key and root token in the
//      `openbao-keys` Secret in the openbao namespace.
//   3. If sealed: reads the unseal key from the Secret and unseals.
//   4. Enables the KV v2 engine at `secret/`.
//   5. Enables the kubernetes auth method.
//   6. Writes the `eso-home-read` policy (read on secret/data/home/*).
//   7. Creates the `external-secrets` role bound to ESO's SA.
//
// Idempotent — re-running against a healthy OpenBao is a no-op.
//
// CRITICAL: back up the `openbao-keys` Secret out-of-band. Losing it
// means losing access to every secret stored in OpenBao.
jobs: [
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

							echo "Writing eso-home-read policy..."
							# Grants access to BOTH home/* and preview/* paths.
							# Preview cluster was merged into home (2026-04-27); ESO
							# resources still reference preview/* keys to avoid
							# rekeying every secret. Backup files in
							# k8-infra-openbao-backup-* use preview/ paths too.
							# users/* covers per-user secrets (e.g. hermes
							# reads users/admin/hermes + users/dev2/hermes).
							POLICY='path "secret/data/home/*" { capabilities = ["read"] }
							path "secret/metadata/home/*" { capabilities = ["read", "list"] }
							path "secret/data/preview/*" { capabilities = ["read"] }
							path "secret/metadata/preview/*" { capabilities = ["read", "list"] }
							path "secret/data/users/*" { capabilities = ["read"] }
							path "secret/metadata/users/*" { capabilities = ["read", "list"] }'
							curl -sf -X PUT -H "$AUTH" \
							  "${BAO_ADDR}/v1/sys/policies/acl/eso-home-read" \
							  -d "$(jq -n --arg p "$POLICY" '{policy:$p}')"

							echo "Creating external-secrets role..."
							curl -sf -X POST -H "$AUTH" \
							  "${BAO_ADDR}/v1/auth/kubernetes/role/external-secrets" \
							  -d '{
							    "bound_service_account_names":"external-secrets",
							    "bound_service_account_namespaces":"external-secrets",
							    "policies":"eso-home-read",
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

serviceAccounts: [
	{
		name:      "openbao-bootstrap"
		namespace: "openbao"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},
	// openbao-auto-unseal CronJob runs as this SA. No RBAC bindings —
	// the Job reads openbao-keys + discord-webhook via volume mount
	// (kubelet projects the Secret on behalf of the pod; no API calls
	// from the pod itself).
	{
		name:      "openbao-auto-unseal"
		namespace: "openbao"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},
	// openbao-readonly-watchdog CronJob — gets openbao-0 logs and
	// deletes the pod if RO-FS errors appear. RBAC bound via
	// openbao-readonly-watchdog ClusterRole / namespace RoleBinding.
	{
		name:      "openbao-readonly-watchdog"
		namespace: "openbao"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},
	// eso-session-watchdog CronJob — restarts external-secrets controller
	// when any ClusterSecretStore has been Ready=False for ≥5min (catches
	// the stale-session-after-OpenBao-restart trap). RBAC via the
	// eso-session-watchdog ClusterRoleBinding.
	// (Below: the ServiceAccount for the CronJob.)
	{
		name:      "eso-session-watchdog"
		namespace: "external-secrets"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},
	{
		name:      "argo-events-sa"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},
	{
		name:      "preview-reaper"
		namespace: "argocd"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},
	{
		name:      "kelos-oauth-watchdog"
		namespace: "kelos-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},
	// argo-sensor-error-watchdog SA — periodically scans argo-events
	// sensor pod logs for level=error lines and Discord-alerts.
	// Permissioned by ClusterRole/argo-sensor-error-watchdog +
	// a namespace-scoped RoleBinding (logs/get is per-namespace).
	{
		name:      "argo-sensor-error-watchdog"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},
	{
		name:      "feature-orchestrator"
		namespace: "kelos-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},
	{
		name:      "velero-restore-drill"
		namespace: "velero"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},
	{
		name:      "quiet-hours-toggle"
		namespace: "kelos-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},

	// SA used by github-app-token-refresh CronJob in each namespace.
	// Permissioned by ClusterRole/github-app-token-refresh + a
	// RoleBinding per namespace. Different XR names per namespace
	// because XServiceAccount XRs are cluster-scoped.
	{
		name:      "github-app-token-refresh"
		namespace: "kelos-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},
	{
		name:      "github-app-token-refresh-events"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},
	// example-bot-installation parallel — same App, separate installation
	// token mint path. Lives in kelos-system because the example-bot
	// panel + lead-dev spawners run there.
	{
		name:      "github-app-token-refresh-example-bot"
		namespace: "kelos-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},
	// Argo Workflows ns parallel — build workflow steps need a fresh
	// installation token to (a) git-clone the PR HEAD over HTTPS and (b)
	// `docker login ghcr.io` with the App as the user before pushing.
	{
		name:      "github-app-token-refresh-workflows"
		namespace: "argo-workflows"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},
	// argocd ns parallel — token consumed by the preview-cap-watchdog
	// CronJob so it can DELETE the `preview` label off stale PRs when
	// the active preview count exceeds the per-cluster cap.
	{
		name:      "github-app-token-refresh-argocd"
		namespace: "argocd"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},

	// claude-oauth-refresher SA — used by the CronJob that auto-renews
	// the Claude Code OAuth access token via refresh-token grant.
	{
		name:      "claude-oauth-refresher"
		namespace: "kelos-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},

	// ai-cost-aggregator SA — used by the hourly CronJob that sums
	// Kelos Task pod cost-usd + token counts and posts a Discord
	// summary so the operator can see which agent class is most
	// expensive.
	{
		name:      "ai-cost-aggregator"
		namespace: "kelos-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},

	// jarvy-tool-discovery SA — used by the daily CronJob that
	// queries Grafana Cloud Loki for tool.unsupported events and
	// dispatches tool-discoverer Kelos Tasks per new tool name.
	{
		name:      "jarvy-tool-discovery"
		namespace: "kelos-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
	},
]
