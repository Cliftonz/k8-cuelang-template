package preview

let C = cluster

// Preview namespace reaper CronJob — catches orphaned preview-* namespaces
// that were not cleaned up by Argo CD's prune: true setting.
// Runs every 15 minutes, checks for namespaces without matching Applications.
cronJobs: [
	{
		name:      "preview-reaper"
		namespace: "argocd"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			schedule: "*/15 * * * *"
			jobTemplate: spec: template: {
				spec: {
					serviceAccountName: "preview-reaper"
					containers: [{
						name:  "reaper"
						image: "bitnami/kubectl:latest"
						command: ["/bin/sh", "-c", #"""
							for ns in $(kubectl get ns -l preview=true -o jsonpath='{.items[*].metadata.name}'); do
							  pr_number=$(kubectl get ns "$ns" -o jsonpath='{.metadata.labels.pr-number}')
							  slug=$(kubectl get ns "$ns" -o jsonpath='{.metadata.labels.appslug}')
							  [ -z "$pr_number" ] || [ -z "$slug" ] && continue
							  app_name="${slug}-${pr_number}"
							  if ! kubectl get application -n argocd "$app_name" >/dev/null 2>&1; then
							    echo "Orphaned namespace: $ns (app $app_name missing) — deleting"
							    kubectl delete namespace "$ns"
							  fi
							done
							"""#]
					}]
					restartPolicy: "OnFailure"
				}
			}
		}
	},

	// kelos-oauth-watchdog — every 6h, check whether the Claude Code
	// OAuth token in kelos-system is within 5 days of expiry and whether
	// any Kelos Tasks have failed with auth-error patterns. Posts to
	// Discord on either condition. Silent when healthy.
	{
		name:      "kelos-oauth-watchdog"
		namespace: "kelos-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			schedule: "0 */6 * * *"
			jobTemplate: spec: template: {
				spec: {
					serviceAccountName: "kelos-oauth-watchdog"
					restartPolicy:      "Never"
					containers: [{
						name:  "watchdog"
						image: "alpine/k8s:1.31.1@sha256:dfe8c7a06c41d0b6e8757da99531f8f302e9a2687fa0155af4c4087df585c9c8"
						command: ["/bin/sh", "-c", #"""
							set -eu
							WEBHOOK="$(cat /run/discord/url)"
							[ -z "$WEBHOOK" ] && { echo "no webhook"; exit 0; }

							# 1. OAuth expiry check
							EXPIRES=$(kubectl get secret claude-code-oauth -n kelos-system \
								-o jsonpath='{.metadata.annotations.kelos\.dev/oauth-expires-at}' 2>/dev/null || true)
							if [ -n "${EXPIRES:-}" ]; then
								NOW=$(($(date +%s) * 1000))
								REMAINING=$((EXPIRES - NOW))
								FIVE_DAYS_MS=$((5 * 86400 * 1000))
								if [ "$REMAINING" -le 0 ]; then
									curl -sf -X POST -H 'Content-Type: application/json' \
										-d '{"content":":rotating_light: Claude OAuth EXPIRED. Kelos Tasks will fail. Run the re-seed flow now. See docs/secret-management.md."}' \
										"$WEBHOOK"
								elif [ "$REMAINING" -lt "$FIVE_DAYS_MS" ]; then
									DAYS=$((REMAINING / 86400000))
									curl -sf -X POST -H 'Content-Type: application/json' \
										-d "{\"content\":\":warning: Claude OAuth expires in ${DAYS} days. Re-seed before then.\"}" \
										"$WEBHOOK"
								fi
							fi

							# 2. Recent auth-failure check on Tasks
							FAILED=$(kubectl get task -n kelos-system -o json 2>/dev/null | \
								jq -r '.items[] | select(.status.phase=="Failed") |
								       select((.status.message // "") | test("401|Unauthorized|invalid_token|auth"; "i")) |
								       .metadata.name' | head -3)
							if [ -n "${FAILED:-}" ]; then
								BODY=$(printf '{"content":":x: Kelos Task auth failures:\\n```\\n%s\\n```\\nLikely OAuth expired."}' "$FAILED")
								curl -sf -X POST -H 'Content-Type: application/json' -d "$BODY" "$WEBHOOK"
							fi
							"""#]
						volumeMounts: [{
							name:      "discord"
							mountPath: "/run/discord"
							readOnly:  true
						}]
						resources: {
							requests: {cpu: "10m", memory: "32Mi"}
							limits: {cpu: "100m", memory: "64Mi"}
						}
						securityContext: {
							runAsNonRoot:             true
							runAsUser:                65532
							runAsGroup:               65532
							allowPrivilegeEscalation: false
							readOnlyRootFilesystem:   true
							capabilities: drop: ["ALL"]
							seccompProfile: type: "RuntimeDefault"
						}
					}]
					volumes: [{
						name: "discord"
						secret: secretName: "discord-webhook"
					}]
				}
			}
		}
	},

	// ── Quiet Hours: enter (8am ET weekdays) ─────────────────────────
	// Pauses LLM-consuming agents to avoid burning Claude Pro/Max
	// session quota during operator's active work hours.
	// Scripts live at ci/scripts/quiet-hours-toggle.sh; Job git-clones
	// the repo at runtime so script updates don't require re-render.
	{
		name:      "quiet-hours-enter"
		namespace: "kelos-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			schedule:                   "0 8 * * 1-5"
			timeZone:                   "America/New_York"
			concurrencyPolicy:          "Forbid"
			successfulJobsHistoryLimit: 1
			failedJobsHistoryLimit:     1
			jobTemplate: spec: template: {
				spec: {
					serviceAccountName: "quiet-hours-toggle"
					restartPolicy:      "OnFailure"
					containers: [{
						name:  "toggle"
						image: "alpine/k8s:1.31.1@sha256:dfe8c7a06c41d0b6e8757da99531f8f302e9a2687fa0155af4c4087df585c9c8"
						command: ["/bin/sh", "-c", #"""
							set -eu
							git clone --depth 1 https://github.com/example-org/k8-infra.git /tmp/infra
							export MODE=enter
							exec bash /tmp/infra/ci/scripts/quiet-hours-toggle.sh
							"""#]
						resources: {
							requests: {cpu: "10m", memory: "64Mi"}
							limits: {cpu: "200m", memory: "256Mi"}
						}
						securityContext: {
							runAsNonRoot:             true
							runAsUser:                65532
							runAsGroup:               65532
							allowPrivilegeEscalation: false
							capabilities: drop: ["ALL"]
							seccompProfile: type: "RuntimeDefault"
						}
					}]
				}
			}
		}
	},

	// ── Quiet Hours: exit (2pm ET weekdays) ──────────────────────────
	{
		name:      "quiet-hours-exit"
		namespace: "kelos-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			schedule:                   "0 14 * * 1-5"
			timeZone:                   "America/New_York"
			concurrencyPolicy:          "Forbid"
			successfulJobsHistoryLimit: 1
			failedJobsHistoryLimit:     1
			jobTemplate: spec: template: {
				spec: {
					serviceAccountName: "quiet-hours-toggle"
					restartPolicy:      "OnFailure"
					containers: [{
						name:  "toggle"
						image: "alpine/k8s:1.31.1@sha256:dfe8c7a06c41d0b6e8757da99531f8f302e9a2687fa0155af4c4087df585c9c8"
						command: ["/bin/sh", "-c", #"""
							set -eu
							git clone --depth 1 https://github.com/example-org/k8-infra.git /tmp/infra
							export MODE=exit
							exec bash /tmp/infra/ci/scripts/quiet-hours-toggle.sh
							"""#]
						resources: {
							requests: {cpu: "10m", memory: "64Mi"}
							limits: {cpu: "200m", memory: "256Mi"}
						}
						securityContext: {
							runAsNonRoot:             true
							runAsUser:                65532
							runAsGroup:               65532
							allowPrivilegeEscalation: false
							capabilities: drop: ["ALL"]
							seccompProfile: type: "RuntimeDefault"
						}
					}]
				}
			}
		}
	},
]
