package home

import "strings"

let C = cluster

// Comma-joined "owner/name" list of example-org repos onboarded for
// preview environments. Derived from _repos in argocd.cue so that
// adding a repo to the ApplicationSet generator automatically adds it
// to the preview-cap-watchdog scan.
_previewRepoList: strings.Join([for r in _repos {"\(r.owner)/\(r.name)"}], " ")

// Hard cap on concurrent active previews across all example-org repos.
// The stack-label workflow in each repo is the primary gate (it refuses
// to label the (N+1)-th PR). This number is the safety net the watchdog
// CronJob enforces in case A's label-add raced the count check, or a
// human manually applied a label.
//
// At ~2.5 GiB per preview with the full Supabase stack, 6 ≈ 15 GiB —
// roughly half of the 4-node ~30 GiB cluster allocatable, leaving
// headroom for platform workloads (Argo, ESO, OpenBao, hermes, honcho,
// jarvy-telemetry, Velero, etc).
_previewCap: 6

// Preview reaper CronJob — two-pass cleanup for orphaned preview envs.
//
// Pass 1: Applications stuck in deletion. Argo CD's
// resources-finalizer.argoproj.io is supposed to prune managed resources
// before letting the Application CR be garbage-collected. We have
// observed cases where the application-controller logs
// "Skipping auto-sync: deletion in progress" with process_finalizers_ms=0
// indefinitely — the controller sees the deletionTimestamp but never
// enters the prune code path. Live example 2026-05-23: salessage-182
// sat with deletionTimestamp for 17h while the underlying Deployment,
// CNPG cluster, mailpit, and Ingress kept consuming RAM + Longhorn PVs.
// Pass 1 finds any preview-labeled Application whose deletionTimestamp
// is >15 min old, force-removes the finalizer, and deletes the target
// namespace. The Application CR is then GC'd immediately and the
// namespace cascade-deletes everything.
//
// Pass 2: namespaces whose owning Application is already gone. The
// original case this CronJob was written for — Argo CD's prune missed
// the namespace, leaving it Active with no owner. Less common after
// Pass 1 lands but kept as a backstop.
//
// Runs every 15 minutes. Threshold of 15 min on stuck-deletes means
// worst-case a preview lingers 30 min after PR close (one cycle to
// observe deletionTimestamp passing threshold, plus a possible second
// before the namespace fully GCs).
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
							set -eu

							# ---------------------------------------------------------
							# Pass 1: Applications stuck mid-deletion (>15 min old
							# deletionTimestamp). Force-remove finalizer + delete ns.
							# ---------------------------------------------------------
							now=$(date -u +%s)
							threshold=900   # 15 min

							for app in $(kubectl get application -n argocd \
							             -l preview=true \
							             -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
							  ts=$(kubectl get application -n argocd "$app" \
							       -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || true)
							  [ -z "$ts" ] && continue

							  # ISO8601 → epoch
							  ts_epoch=$(date -u -d "$ts" +%s 2>/dev/null \
							            || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null \
							            || echo "0")
							  age=$(( now - ts_epoch ))
							  [ "$age" -lt "$threshold" ] && continue

							  target_ns=$(kubectl get application -n argocd "$app" \
							              -o jsonpath='{.spec.destination.namespace}')
							  echo "Stuck deleting: argocd/$app (age=${age}s, ns=$target_ns) — force-cleanup"

							  if [ -n "$target_ns" ]; then
							    kubectl delete namespace "$target_ns" --wait=false 2>&1 || true
							  fi
							  kubectl patch application -n argocd "$app" \
							    --type=merge \
							    -p '{"metadata":{"finalizers":[]}}' 2>&1 || true
							done

							# ---------------------------------------------------------
							# Pass 2: orphaned preview-* namespaces with no Application.
							# ---------------------------------------------------------
							for ns in $(kubectl get ns -l preview=true \
							            -o jsonpath='{.items[*].metadata.name}'); do
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

	// openbao-auto-unseal — every 15 min, hit /v1/sys/seal-status. If
	// sealed, post a Discord alert AND call /v1/sys/unseal with the
	// stored key. Outcome (success / failure) is sent to Discord so
	// the operator has explicit confirmation. Exits 0 silently when
	// already unsealed — no Discord noise on the happy path.
	//
	// File-backed OpenBao seals on every pod restart (no cloud-KMS
	// auto-unseal here). Without this CronJob, the cluster silently
	// loses every ESO-synced Secret refresh + the Claude OAuth
	// refresher path until a human re-unseals from a laptop. Saw the
	// failure mode on 2026-05-12 after a NetworkPolicy rollout
	// triggered an openbao-0 restart.
	//
	// Cadence: was */2 (720 Jobs/day) — overkill for an event that
	// happens at most once per pod restart. Reduced to */15 on
	// 2026-05-23 after the cluster-wide apiserver pressure incident
	// showed how many Jobs/min this generates. Worst case: ~15 min of
	// sealed OpenBao between restart and auto-unseal, which only
	// affects the ESO refresh interval (5 min for most secrets).
	//
	// Security note: the unseal key sits in the openbao-keys Secret
	// (same place the bootstrap Job uses it). This Job adds no new
	// trust boundary; it just automates the unseal step. A proper
	// production auto-unseal would use cloud KMS (AWS/GCP/Azure) and
	// remove the key from the cluster entirely — out of scope for
	// the homelab tier.
	{
		name:      "openbao-auto-unseal"
		namespace: "openbao"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			schedule:                   "*/15 * * * *"
			concurrencyPolicy:          "Forbid"
			successfulJobsHistoryLimit: 1
			failedJobsHistoryLimit:     3
			jobTemplate: spec: {
				backoffLimit: 0
				template: spec: {
					serviceAccountName: "openbao-auto-unseal"
					restartPolicy:      "Never"
					containers: [{
						name:  "unseal"
						image: "alpine/k8s:1.31.1@sha256:dfe8c7a06c41d0b6e8757da99531f8f302e9a2687fa0155af4c4087df585c9c8"
						command: ["/bin/sh", "-c", #"""
							set -eu
							# alpine/k8s ships jq + curl already; no apk add
							# (which would fail under readOnlyRootFilesystem
							# + runAsNonRoot anyway).

							BAO_ADDR="http://openbao.openbao.svc:8200"

							# 1. seal-status: is OpenBao sealed?
							STATUS=$(curl -sfS "${BAO_ADDR}/v1/sys/seal-status" || echo '{"sealed":"network-error"}')
							SEALED=$(echo "$STATUS" | jq -r '.sealed')

							if [ "$SEALED" = "false" ]; then
								echo "openbao unsealed; nothing to do"
								exit 0
							fi

							if [ "$SEALED" = "network-error" ]; then
								echo "could not reach $BAO_ADDR/v1/sys/seal-status — openbao may be Pending or NP-blocked. Exiting without action." >&2
								exit 1
							fi

							echo "openbao is SEALED — attempting auto-unseal"

							# 2. Attempt unseal with the stored key.
							UNSEAL_KEY=$(cat /run/openbao-keys/unseal-key)
							UNSEAL_RESP=$(curl -sS -X POST -H "Content-Type: application/json" \
								-d "$(jq -nc --arg k "$UNSEAL_KEY" '{key:$k}')" \
								"${BAO_ADDR}/v1/sys/unseal" || echo '{}')
							NOW_SEALED=$(echo "$UNSEAL_RESP" | jq -r '.sealed // "unknown"')

							# 3. Post Discord with the outcome. Single message
							# covers both "we detected it sealed" AND result, so
							# the operator gets one notification per event.
							WEBHOOK=$(cat /run/discord/url 2>/dev/null || true)
							if [ -n "$WEBHOOK" ]; then
								if [ "$NOW_SEALED" = "false" ]; then
									BODY=$(printf '{"content":":unlock: **OpenBao auto-unseal** — was sealed, now unsealed. Likely cause: openbao-0 pod restart. Investigate restart cause in `kubectl -n openbao describe pod openbao-0`."}')
								else
									ERR=$(echo "$UNSEAL_RESP" | jq -c '.errors // .' 2>/dev/null || echo "$UNSEAL_RESP")
									BODY=$(printf '{"content":":fire: **OpenBao auto-unseal FAILED** — still sealed after attempt. Response: `%s`. Run `ci/scripts/unseal-openbao.sh` from a laptop or investigate manually."}' "$ERR")
								fi
								curl -sS -X POST -H 'Content-Type: application/json' \
									-d "$BODY" "$WEBHOOK" >/dev/null || \
									echo "discord post failed (continuing)" >&2
							fi

							# 4. Exit code reflects unseal outcome so kubectl
							# pod state surfaces failures even if Discord drops.
							if [ "$NOW_SEALED" = "false" ]; then
								echo "auto-unseal complete"
								exit 0
							else
								echo "auto-unseal failed: $UNSEAL_RESP" >&2
								exit 1
							fi
							"""#]
						volumeMounts: [
							{name: "openbao-keys", mountPath: "/run/openbao-keys", readOnly: true},
							{name: "discord", mountPath: "/run/discord", readOnly: true},
						]
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
					volumes: [
						{name: "openbao-keys", secret: secretName: "openbao-keys"},
						// Synced by the discord-webhook-openbao XR ES into
						// the openbao ns. Different name from the kelos-
						// system copy because XR is cluster-scoped.
						{name: "discord", secret: secretName: "discord-webhook-openbao"},
					]
					// No automount of SA token — the Job makes no API calls.
					automountServiceAccountToken: false
				}
			}
		}
	},

	// openbao-readonly-watchdog — every 5 min, scan openbao-0 logs for
	// `read-only file system` errors and, if present, delete the pod so
	// the StatefulSet remounts the PVC fresh. The auto-unseal CronJob
	// (above) re-unseals within ~2 min.
	//
	// The trap (seen 2026-05-14 + 2026-05-15 on home cluster): Longhorn
	// engine has a brief blip → PVC mount flips to read-only → OpenBao
	// keeps running but every write fails from the FS layer up. No
	// alert until an operator notices ESO is failing. This watchdog
	// catches it within 5 min.
	{
		name:      "openbao-readonly-watchdog"
		namespace: "openbao"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			schedule:                   "*/5 * * * *"
			concurrencyPolicy:          "Forbid"
			successfulJobsHistoryLimit: 1
			failedJobsHistoryLimit:     3
			jobTemplate: spec: {
				backoffLimit: 0
				template: spec: {
					serviceAccountName: "openbao-readonly-watchdog"
					restartPolicy:      "Never"
					containers: [{
						name:  "watchdog"
						image: "alpine/k8s:1.31.1@sha256:dfe8c7a06c41d0b6e8757da99531f8f302e9a2687fa0155af4c4087df585c9c8"
						command: ["/bin/sh", "-c", #"""
							set -eu
							WEBHOOK="$(cat /run/discord/url 2>/dev/null || true)"

							# Grep last 5 min of openbao-0 logs. --since covers
							# pod restarts (kubectl logs --since uses the
							# kubelet's view, which spans container restarts).
							LOG=$(kubectl -n openbao logs openbao-0 --since=5m 2>&1 || true)

							if ! echo "$LOG" | grep -q "read-only file system"; then
								echo "no RO-FS errors in last 5min"
								exit 0
							fi

							echo "RO-FS detected — deleting openbao-0 to remount"

							# Snapshot a few sample errors for the alert body.
							SAMPLES=$(echo "$LOG" | grep "read-only file system" | head -3)

							# Delete the pod. StatefulSet recreates it; auto-
							# unseal CronJob re-unseals within ~2 min.
							if ! kubectl -n openbao delete pod openbao-0 --wait=false 2>&1; then
								echo "failed to delete openbao-0" >&2
								if [ -n "$WEBHOOK" ]; then
									curl -sS -X POST -H 'Content-Type: application/json' \
										-d "$(printf '{"content":":fire: **OpenBao RO-FS detected** but pod delete FAILED. Manual intervention needed. Samples: %s"}' "$(echo "$SAMPLES" | head -1 | sed 's/"/\\"/g' | cut -c1-200)")" \
										"$WEBHOOK" >/dev/null || true
								fi
								exit 1
							fi

							if [ -n "$WEBHOOK" ]; then
								BODY=$(printf '{"content":":wrench: **OpenBao RO-FS watchdog** — detected `read-only file system` errors in openbao-0 logs. Deleted the pod to force remount; auto-unseal will re-unseal within 2 min. Investigate Longhorn engine for transient errors around this time. Sample: `%s`"}' "$(echo "$SAMPLES" | head -1 | sed 's/"/\\"/g' | cut -c1-300)")
								curl -sS -X POST -H 'Content-Type: application/json' \
									-d "$BODY" "$WEBHOOK" >/dev/null || \
									echo "discord post failed (continuing)" >&2
							fi

							echo "openbao-0 deleted; new pod will come up"
							"""#]
						volumeMounts: [
							{name: "discord", mountPath: "/run/discord", readOnly: true},
						]
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
					volumes: [
						{name: "discord", secret: secretName: "discord-webhook-openbao"},
					]
				}
			}
		}
	},

	// eso-session-watchdog — every 5 min, check ClusterSecretStore
	// Ready conditions. If any has been Ready=False for ≥5 min, the
	// external-secrets controller has likely cached a dead session
	// (OpenBao restart, network blip, etc.); restart the controller
	// deployment so it re-establishes auth. Discord-alerts the action.
	//
	// The trap (seen 2026-05-15 on home cluster): OpenBao went RO,
	// the readonly-watchdog killed the pod, new OpenBao came up clean,
	// but every ExternalSecret stayed `SecretSyncedError` for 30+ min
	// because the ESO controller cached a token for a server that no
	// longer existed. Operator-side fix was `kubectl rollout restart`.
	//
	// IMPORTANT — these three constants must stay coupled:
	//   schedule */5 * * * *  → tick every 300s
	//   STALENESS_THRESHOLD   = 300s (must be ≤ tick interval, else
	//                                  detection latency 2x worst case)
	//   COOLDOWN_SEC          = 1800s (must be ≥ a full ESO rollout +
	//                                  CSS-resync window so we don't
	//                                  thrash; argo-sensor uses 24h
	//                                  tombstones — we go shorter so
	//                                  legit re-flaps still get acted on)
	{
		name:      "eso-session-watchdog"
		namespace: "external-secrets"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			schedule:                   "*/5 * * * *"
			concurrencyPolicy:          "Forbid"
			// startingDeadlineSeconds: skip catch-up runs after a
			// controller-manager pause (Talos rolling upgrades). Without
			// this, Forbid + a >5min pause queues missed schedules and
			// the controller does wasted scheduling work.
			startingDeadlineSeconds: 120
			// History bumped from 1 → 5: forensic value of being able to
			// `kubectl logs job/...` for the previous few ticks vastly
			// outweighs the etcd cost of 4 extra completed Pod objects.
			successfulJobsHistoryLimit: 5
			failedJobsHistoryLimit:     3
			jobTemplate: spec: {
				// Pod-level deadline — if `kubectl patch` hangs on an
				// apiserver pause, the Job is killed at 180s and the
				// next 5-min tick runs cleanly. Without this, a single
				// hung Pod silently disables the watchdog under Forbid.
				activeDeadlineSeconds: 180
				backoffLimit:          0
				template: spec: {
					serviceAccountName: "eso-session-watchdog"
					restartPolicy:      "Never"
					// Bound SA-token lifetime to ~10min via projection,
					// audience-locked to the apiserver. Default mount is
					// a Pod-lifetime token valid for any audience — a
					// stolen token here could be replayed against any
					// service that trusts the cluster JWT issuer.
					automountServiceAccountToken: false
					containers: [{
						name: "watchdog"
						// Pinned by digest (manifest-list SHA — works on
						// both arm64 and amd64 nodes). Resolve a new
						// digest with: `docker manifest inspect alpine/k8s:1.31.1`
						// or `crane digest alpine/k8s:1.31.1`.
						image: "alpine/k8s:1.31.1@sha256:dfe8c7a06c41d0b6e8757da99531f8f302e9a2687fa0155af4c4087df585c9c8"
						command: ["/bin/sh", "-c", #"""
							set -eu

							# ── Tunables (kept together so a future bump touches one place).
							# Schedule (*/5) ↔ STALENESS_THRESHOLD ↔ COOLDOWN_SEC must
							# stay in sync; the block comment above documents the contract.
							STALENESS_THRESHOLD=300
							COOLDOWN_SEC=1800
							ESCALATION_AGE=1800
							RUNBOOK="docs/troubleshooting-2026-05-15-post-recovery-hardening.md"
							PUSHGW="http://opencost-prometheus-prometheus-pushgateway.opencost.svc:9091"
							KUBECTL="kubectl --request-timeout=20s"

							# OpenBao-seeded secrets often carry a trailing \n that
							# leaks into curl's URL on some clients. Strip it.
							WEBHOOK="$(tr -d '\r\n' </run/discord/url 2>/dev/null || true)"

							notify_discord() {
								body="$1"
								if [ -z "$WEBHOOK" ]; then
									# Webhook not synced yet (ESO itself may be the
									# broken thing). Log to stderr; bumped history
									# limit means `kubectl logs job/...` finds it.
									echo "WOULD ALERT (no webhook): $body" >&2
									return 0
								fi
								# Build JSON via jq — no shell-interpolation injection
								# into the body, no Discord-markdown impersonation
								# from attacker-controlled CSS status messages.
								jq -nc --arg c "$body" '{content: $c}' \
									| curl -sS -m 10 -X POST -H 'Content-Type: application/json' \
										--data-binary @- "$WEBHOOK" >/dev/null 2>&1 \
									|| echo "discord post failed (continuing)" >&2
							}

							push_metric() {
								# Pushgateway is best-effort — never fail the
								# watchdog if metrics push is unreachable.
								payload="$1"
								printf '%s\n' "$payload" \
									| curl -sS -m 5 --data-binary @- \
										"$PUSHGW/metrics/job/eso_session_watchdog" \
										>/dev/null 2>&1 \
									|| echo "pushgateway push failed (continuing)" >&2
							}

							NOW=$(date +%s)

							# Heartbeat every tick. Operator alert:
							#   time() - k8_infra_eso_session_watchdog_last_tick_seconds > 900
							# detects a suspended or unschedulable watchdog.
							push_metric "$(printf '# TYPE k8_infra_eso_session_watchdog_last_tick_seconds gauge\nk8_infra_eso_session_watchdog_last_tick_seconds %s\n' "$NOW")"

							# ── 1. List CSS state in ONE apiserver round-trip.
							# Use jq's fromdateiso8601 — busybox `date -d` cannot
							# parse RFC3339 in alpine/k8s, and silent parse failure
							# was the original bug (threshold collapsed to 0).
							if ! CSS_JSON=$($KUBECTL get clustersecretstore -o json 2>&1); then
								err=$(printf '%s' "$CSS_JSON" | tr -d '\n' | cut -c1-400)
								notify_discord ":fire: **ESO watchdog** could NOT list ClusterSecretStores (self-failure). apiserver / RBAC / NP issue. Output: \`$err\`"
								exit 1
							fi

							# Emit TSV: <name>\t<reason>\t<message_clean>\t<age_seconds>
							# Only stale-enough CSSes survive the filter:
							#   - Ready condition exists and is False
							#   - lastTransitionTime parses (silently skip if not)
							#   - age ≥ STALENESS_THRESHOLD
							# The gsub() strips Discord-markdown chars from message
							# so a hostile CSS status message cannot impersonate
							# operator instructions in the trusted watchdog channel.
							STALE=$(printf '%s' "$CSS_JSON" | jq -r \
								--argjson now "$NOW" \
								--argjson thr "$STALENESS_THRESHOLD" '
								.items[]
								| . as $css
								| ($css.status.conditions[]? | select(.type=="Ready")) as $r
								| select($r.status == "False")
								| ($r.lastTransitionTime | fromdateiso8601? // empty) as $ltt
								| select($ltt != null)
								| select(($now - $ltt) >= $thr)
								| [$css.metadata.name,
								   ($r.reason // "?"),
								   (($r.message // "")
								     | gsub("[`@<>*_~|]"; " ")
								     | .[0:200]),
								   ($now - $ltt)]
								| @tsv
								')

							if [ -z "$STALE" ]; then
								echo "result=ok stale_count=0 ts=$NOW"
								exit 0
							fi

							STALE_COUNT=$(printf '%s\n' "$STALE" | wc -l | tr -d ' ')
							STALE_NAMES=$(printf '%s\n' "$STALE" | cut -f1 | paste -sd, -)
							MAX_AGE=$(printf '%s\n' "$STALE" | awk -F'\t' '{if($4>m)m=$4} END{print m+0}')
							REP_REASON=$(printf '%s' "$STALE" | head -1 | cut -f2)
							REP_MSG=$(printf '%s' "$STALE" | head -1 | cut -f3)

							# Bounded label cardinality: {network, auth, other}.
							REASON_BLOB=$(printf '%s %s' "$REP_REASON" "$REP_MSG" | tr '[:upper:]' '[:lower:]')
							case "$REASON_BLOB" in
								*connection*refused*|*"i/o timeout"*|*"no such host"*|*"network is unreachable"*) REASON_CLASS=network ;;
								*401*|*403*|*unauthorized*|*forbidden*|*token*|*permission*|*denied*)               REASON_CLASS=auth ;;
								*)                                                                                  REASON_CLASS=other ;;
							esac

							echo "result=stale stale_count=$STALE_COUNT max_age=$MAX_AGE class=$REASON_CLASS names=$STALE_NAMES"

							# ── 2. Locate the ESO Deployment by chart label, not
							# hardcoded name. A Helm release rename then surfaces
							# loudly (Discord alert) instead of silently no-op'ing.
							DEPLOY=$($KUBECTL -n external-secrets get deploy \
								-l app.kubernetes.io/name=external-secrets,app.kubernetes.io/instance=external-secrets \
								-o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
							DEPLOY_COUNT=$(echo "$DEPLOY" | wc -w | tr -d ' ')
							if [ "$DEPLOY_COUNT" != "1" ]; then
								notify_discord ":fire: **ESO watchdog** expected exactly one ESO Deployment matching \`app.kubernetes.io/name=external-secrets\`, found $DEPLOY_COUNT: \`$DEPLOY\`. Chart may have been renamed; update watchdog selector."
								exit 1
							fi

							# ── 3. Cooldown — skip restart if we restarted recently.
							LAST_RESTART=$($KUBECTL -n external-secrets get deploy "$DEPLOY" \
								-o 'jsonpath={.spec.template.metadata.annotations.k8-infra\.io/eso-session-watchdog-restart-epoch}' \
								2>/dev/null || true)
							LAST_RESTART="${LAST_RESTART:-0}"
							SINCE_LAST=$((NOW - LAST_RESTART))

							if [ "$LAST_RESTART" -gt 0 ] && [ "$SINCE_LAST" -lt "$COOLDOWN_SEC" ]; then
								AGO_MIN=$((SINCE_LAST / 60))
								if [ "$MAX_AGE" -ge "$ESCALATION_AGE" ]; then
									# Restart fired ${AGO_MIN}m ago and CSS is STILL stale.
									# Escalate with rotating-light so the operator notices
									# this is not transient.
									notify_discord ":rotating_light: **ESO watchdog** — restart $AGO_MIN min ago did NOT recover CSS [$STALE_NAMES] (still Ready=False for $((MAX_AGE/60)) min, class=$REASON_CLASS). Root cause is not transient — manual investigation needed.
							Runbook: $RUNBOOK
							Verify: kubectl -n external-secrets describe clustersecretstore $(printf '%s' "$STALE_NAMES" | cut -d, -f1)
							Reason: $REP_REASON"
									push_metric "$(printf '# TYPE k8_infra_eso_session_watchdog_escalation_total counter\nk8_infra_eso_session_watchdog_escalation_total{class=\"%s\"} 1\n' "$REASON_CLASS")"
								else
									echo "result=cooldown since_last=${SINCE_LAST}s threshold=${COOLDOWN_SEC}s class=$REASON_CLASS"
								fi
								exit 0
							fi

							# ── 4. Patch the Deployment.
							# Annotations:
							#   restart-epoch       — unix time, drives cooldown above
							#   restart-fingerprint — sha256 of (names+reason); identical
							#                         payload renders identically across
							#                         ticks → strategic-merge no-op. The
							#                         audit log gets one entry per unique
							#                         incident, not one per tick.
							#   restart-source      — self-documenting; an operator
							#                         inspecting the Deployment a week
							#                         later can find this watchdog from
							#                         the annotation alone.
							FINGERPRINT=$(printf '%s|%s' "$STALE_NAMES" "$REP_REASON" | sha256sum | cut -c1-12)
							PATCH=$(jq -nc \
								--arg epoch "$NOW" \
								--arg fp "$FINGERPRINT" \
								'{spec:{template:{metadata:{annotations:{
									"k8-infra.io/eso-session-watchdog-restart-epoch": $epoch,
									"k8-infra.io/eso-session-watchdog-restart-fingerprint": $fp,
									"k8-infra.io/eso-session-watchdog-restart-source": "eso-session-watchdog"
								}}}}}')

							if ! PATCH_OUT=$($KUBECTL -n external-secrets patch deploy "$DEPLOY" \
									--type=strategic --patch "$PATCH" 2>&1); then
								err=$(printf '%s' "$PATCH_OUT" | tr -d '\n' | cut -c1-400)
								notify_discord ":fire: **ESO watchdog** detected stale CSS [$STALE_NAMES] but FAILED to patch \`$DEPLOY\`: \`$err\`. Manual intervention needed.
							Runbook: $RUNBOOK"
								push_metric "$(printf '# TYPE k8_infra_eso_session_watchdog_patch_failed_total counter\nk8_infra_eso_session_watchdog_patch_failed_total{class=\"%s\"} 1\n' "$REASON_CLASS")"
								exit 1
							fi

							# Single Discord alert regardless of how many CSSes flipped.
							# Includes runbook + correlation handles (Job name, verify
							# command, fingerprint) so the 3-AM operator has everything
							# in one message.
							notify_discord ":arrows_counterclockwise: **ESO session watchdog** — CSS [$STALE_NAMES] Ready=False for $((MAX_AGE/60)) min (class=$REASON_CLASS). Patched Deployment \`$DEPLOY\` (fingerprint $FINGERPRINT); CSS should recover within ~30s.
							Reason: $REP_REASON
							Job: $(hostname)
							Runbook: $RUNBOOK
							Verify: kubectl -n external-secrets rollout status deploy/$DEPLOY --timeout=90s"

							push_metric "$(printf '# TYPE k8_infra_eso_session_watchdog_restart_total counter\nk8_infra_eso_session_watchdog_restart_total{class=\"%s\"} 1\n' "$REASON_CLASS")"

							echo "result=restarted deploy=$DEPLOY fingerprint=$FINGERPRINT count=$STALE_COUNT class=$REASON_CLASS"
							"""#]
						volumeMounts: [
							{name: "discord", mountPath: "/run/discord", readOnly: true},
							// SA token projected with audience+expiration —
							// see Pod-spec volumes below.
							{name: "sa-token", mountPath: "/var/run/secrets/kubernetes.io/serviceaccount", readOnly: true},
						]
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
					volumes: [
						{name: "discord", secret: secretName: "discord-webhook-eso"},
						// Projected SA token: ~10min lifetime, audience-locked
						// to the apiserver, paired with the cluster CA and the
						// Pod's namespace via downwardAPI. Mounted at the path
						// kubectl reads by default so no env-var changes needed.
						{
							name: "sa-token"
							projected: {
								sources: [
									{serviceAccountToken: {
										path:              "token"
										audience:          "https://kubernetes.default.svc"
										expirationSeconds: 600
									}},
									{configMap: {
										name: "kube-root-ca.crt"
										items: [{key: "ca.crt", path: "ca.crt"}]
									}},
									{downwardAPI: {
										items: [{
											path: "namespace"
											fieldRef: fieldPath: "metadata.namespace"
										}]
									}},
								]
							}
						},
					]
				}
			}
		}
	},

	// argo-sensor-error-watchdog — every 10 min, scan argo-events sensor
	// pods for `"level":"error"` log lines and Discord-alert any new
	// fingerprint. Catches silent argo-events trigger failures (e.g. an
	// invalid metadata.name from a malformed dataTemplate). Dedup via
	// a ConfigMap tombstone keyed on the error fingerprint; alerts only
	// fire once per fingerprint within ~24h.
	//
	// Background: 2026-05-12 — GitHub comment.id crossed 2^32 and Go's
	// text/template default render became scientific notation, producing
	// invalid k8s names. argo-events logged each trigger failure at
	// `level=error` but nothing surfaced higher up. Saw nothing until
	// we deep-dived sensor pod logs by hand. See
	// docs/argo-events-large-int-pitfall.md.
	{
		name:      "argo-sensor-error-watchdog"
		namespace: "argo-events"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			schedule:                   "*/10 * * * *"
			concurrencyPolicy:          "Forbid"
			successfulJobsHistoryLimit: 1
			failedJobsHistoryLimit:     3
			jobTemplate: spec: {
				backoffLimit: 0
				template: spec: {
					serviceAccountName: "argo-sensor-error-watchdog"
					restartPolicy:      "Never"
					containers: [{
						name:  "watchdog"
						image: "alpine/k8s:1.31.1@sha256:dfe8c7a06c41d0b6e8757da99531f8f302e9a2687fa0155af4c4087df585c9c8"
						command: ["/bin/sh", "-c", #"""
							set -eu
							WEBHOOK="$(cat /run/discord/url 2>/dev/null || true)"
							if [ -z "$WEBHOOK" ]; then
								echo "no Discord webhook; nothing to alert with"
								exit 0
							fi

							# Look at sensor pod logs from the past 12 min (cron
							# runs every 10; 2-min overlap absorbs jitter).
							PODS=$(kubectl -n argo-events get pods -l sensor-name \
								-o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}')
							if [ -z "$PODS" ]; then
								echo "no running sensor pods (unusual but exit clean)"
								exit 0
							fi

							# Allowlist of patterns we know are transient cluster
							# events, not app bugs (NATS reconnects during
							# eventbus restart, leader-election timeouts during
							# Talos upgrades, etc.). Errors matching any of these
							# fingerprint patterns are dropped before alerting.
							# Tune carefully — too broad and we miss real bugs.
							INFRA_NOISE='nats|connection refused|context deadline exceeded|leader election lost|no such host|i/o timeout|reconcileID.*ETIMEDOUT|reconnect|connection reset|TLS handshake timeout'

							# Collect ALL fingerprints across all pods first, so
							# we can decide between per-fingerprint Discord pings
							# vs a consolidated "many errors this tick" alert.
							# Format: lines of "POD\tFINGERPRINT".
							ALL_NEW=""
							for POD in $PODS; do
								LOGS=$(kubectl -n argo-events logs "$POD" --since=12m 2>/dev/null || true)
								[ -z "$LOGS" ] && continue
								ERRORS=$(printf '%s' "$LOGS" | grep '"level":"error"' || true)
								[ -z "$ERRORS" ] && continue

								FINGERPRINTS=$(printf '%s' "$ERRORS" | \
									jq -r 'select(.level=="error") | .msg + " :: " + ((.error // "") | tostring[:100])' \
									2>/dev/null | sort -u || true)

								# Drop infra-noise patterns.
								FINGERPRINTS=$(printf '%s\n' "$FINGERPRINTS" | grep -vEi "$INFRA_NOISE" || true)

								# For each remaining fingerprint, check whether
								# it's a NEW sighting (no tombstone CM yet).
								# Build the per-pod NEW list; consolidation logic
								# below decides whether to send 1 alert or N.
								printf '%s\n' "$FINGERPRINTS" | while IFS= read -r FP; do
									[ -z "$FP" ] && continue
									HASH=$(printf '%s' "$POD $FP" | sha256sum | cut -c1-12)
									CM="error-alert-$HASH"
									if kubectl -n argo-events get configmap "$CM" >/dev/null 2>&1; then
										echo "skipped (already alerted): $POD :: $FP"
										continue
									fi
									# Stash NEW finding to a shared file the
									# parent shell will read after the subshell
									# while-loop exits. /tmp survives within
									# this Pod's filesystem for the script's
									# lifetime.
									printf '%s\t%s\n' "$POD" "$FP" >> /tmp/new-findings.txt
								done
							done

							NEW=""
							[ -s /tmp/new-findings.txt ] && NEW=$(cat /tmp/new-findings.txt)
							NEW_COUNT=0
							[ -n "$NEW" ] && NEW_COUNT=$(printf '%s\n' "$NEW" | wc -l | tr -d ' ')

							if [ "$NEW_COUNT" = "0" ]; then
								echo "no new error fingerprints this tick"
							elif [ "$NEW_COUNT" -le 3 ]; then
								# Few enough to alert individually.
								printf '%s\n' "$NEW" | while IFS=$'\t' read -r POD FP; do
									HASH=$(printf '%s' "$POD $FP" | sha256sum | cut -c1-12)
									CM="error-alert-$HASH"
									kubectl -n argo-events create configmap "$CM" \
										--from-literal=fingerprint="$FP" \
										--from-literal=pod="$POD" \
										--from-literal=detected_at="$(date -u +%FT%TZ)" \
										>/dev/null 2>&1 || true
									BODY=$(jq -nc \
										--arg pod "$POD" \
										--arg fp "$FP" \
										'{content: ("⚠️ argo-events sensor error\n**pod**: `" + $pod + "`\n**fingerprint**: `" + $fp + "`\n\nSee docs/argo-events-large-int-pitfall.md for the most-recent class. Allowlist tweak: edit INFRA_NOISE regex in argo-sensor-error-watchdog CronJob.")}')
									curl -sfS -X POST -H 'Content-Type: application/json' \
										-d "$BODY" "$WEBHOOK" >/dev/null || true
									echo "alerted: $POD :: $FP"
								done
							else
								# Burst — fold into ONE alert. Likely a
								# cluster-wide event (Talos upgrade, eventbus
								# restart, etc.) where N separate pings would
								# just be noise.
								HEAD=$(printf '%s\n' "$NEW" | head -3 | awk -F'\t' '{printf "• %s :: %s\n", $1, $2}')
								BODY=$(jq -nc \
									--arg count "$NEW_COUNT" \
									--arg head "$HEAD" \
									'{content: ("⚠️ argo-events sensor errors burst — " + $count + " new fingerprints this tick (likely a cluster-wide event, not per-sensor bugs)\n\nFirst 3:\n```\n" + $head + "\n```\nIf this is expected (e.g. you are upgrading the cluster), ignore. If unexpected: `kubectl -n argo-events logs -l sensor-name --tail=200 | grep -i error`.")}')
								curl -sfS -X POST -H 'Content-Type: application/json' \
									-d "$BODY" "$WEBHOOK" >/dev/null || true
								# Tombstone every fingerprint so we don't re-alert
								# any of them in the next 24h.
								printf '%s\n' "$NEW" | while IFS=$'\t' read -r POD FP; do
									HASH=$(printf '%s' "$POD $FP" | sha256sum | cut -c1-12)
									CM="error-alert-$HASH"
									kubectl -n argo-events create configmap "$CM" \
										--from-literal=fingerprint="$FP" \
										--from-literal=pod="$POD" \
										--from-literal=detected_at="$(date -u +%FT%TZ)" \
										--from-literal=alerted_via=burst \
										>/dev/null 2>&1 || true
								done
								echo "burst alert: $NEW_COUNT fingerprints folded into one Discord message"
							fi
							rm -f /tmp/new-findings.txt

							# Garbage collect alert-tombstone CMs older than 24h.
							# Keeps the dedup window finite — if the same error
							# recurs after a day of silence, we alert again.
							# jq's fromdateiso8601 handles the RFC3339 parsing
							# so we don't depend on busybox date -d or python3.
							NOW_TS=$(date -u +%s)
							STALE=$(kubectl -n argo-events get configmap -o json 2>/dev/null | \
								jq -r --argjson now "$NOW_TS" \
								'.items[] | select(.metadata.name | startswith("error-alert-")) | select((.metadata.creationTimestamp | fromdateiso8601) < ($now - 86400)) | .metadata.name')
							for CM in $STALE; do
								kubectl -n argo-events delete configmap "$CM" --ignore-not-found 2>/dev/null || true
							done

							echo "scan complete"
							"""#]
						volumeMounts: [
							{name: "discord", mountPath: "/run/discord", readOnly: true},
							// readOnlyRootFilesystem makes / read-only; the
							// consolidation logic stashes newly-detected
							// fingerprints to /tmp/new-findings.txt across a
							// subshell boundary. Mount emptyDir at /tmp so the
							// pid 1 script can scribble there.
							{name: "scratch", mountPath: "/tmp"},
						]
						resources: {
							requests: {cpu: "10m", memory: "32Mi"}
							limits: {cpu: "200m", memory: "128Mi"}
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
					volumes: [
						{name: "discord", secret: secretName: "discord-webhook-events"},
						{name: "scratch", emptyDir: {}},
					]
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
			// Suspended — claude-oauth-refresher CronJob keeps the access
			// token fresh on a 30m cadence, making the watchdog's expiry
			// alert noisy/redundant. Auth-failure alerts also chain into
			// the refresher's own retry loop. Re-enable (suspend=false)
			// if the refresher is ever decommissioned.
			suspend: true
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

	// github-app-token-refresh-{kelos,events} — every 30m, mint a fresh
	// installation access token for the `Open Warren - Example Org`
	// GitHub App and write it to Secret/github-app-token in the same
	// namespace. Tasks and Jobs reference that Secret via secretKeyRef
	// for $GH_TOKEN, replacing the long-lived github-pat.
	//
	// Token validity: 1h. Refresh cadence: 30m. So the secret is always
	// at most 30m old; even if a refresh fails, downstream jobs have
	// up to 30m of buffer before needing intervention.
	//
	// Two CronJobs (one per namespace) because Secret references are
	// namespace-scoped. Both use the same script body via a shared CUE
	// let-binding.
	// claude-oauth-refresher — every 30m, exchange the stored Claude
	// REFRESH_TOKEN for a fresh CLAUDE_CODE_OAUTH_TOKEN and write the
	// rotated bundle back to OpenBao. ESO then syncs OpenBao → the
	// claude-code-oauth Secret so agents pick up the new access token
	// on next pod start.
	//
	// Idempotent: if the access token still has > 90min of life, exits
	// without calling Anthropic. Refresh tokens rotate on each call —
	// both new access AND new refresh are persisted. If refresh fails
	// (network blip, refresh-token expired), existing tokens are left
	// unchanged and next cron tick retries; on outright refresh-token
	// expiry the existing kelos-oauth-watchdog Discord-alerts.
	{
		name:      "claude-oauth-refresher"
		namespace: "kelos-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			schedule:                   "*/30 * * * *"
			concurrencyPolicy:          "Forbid"
			successfulJobsHistoryLimit: 1
			failedJobsHistoryLimit:     2
			jobTemplate: spec: {
				// One pod, one attempt. Don't retry-storm against
				// Anthropic's auth endpoint — next cron tick handles
				// retry. Avoids 429 rate-limit feedback loops.
				backoffLimit: 0
				template: spec: {
					serviceAccountName: "claude-oauth-refresher"
					restartPolicy:      "Never"
					containers: [{
						name:  "refresher"
						image: "alpine/k8s:1.31.1@sha256:dfe8c7a06c41d0b6e8757da99531f8f302e9a2687fa0155af4c4087df585c9c8"
						command: ["/bin/sh", "-c", #"""
							set -eu
							apk add --no-cache jq curl >/dev/null

							# Read current OAuth state from the ESO-synced Secret.
							ACCESS=$(  cat /run/oauth/CLAUDE_CODE_OAUTH_TOKEN)
							REFRESH=$( cat /run/oauth/REFRESH_TOKEN)
							EXPIRES=$( cat /run/oauth/EXPIRES_AT_MS)
							CLIENT_ID=$(cat /run/oauth/CLIENT_ID)
							TOKEN_URL=$(cat /run/oauth/TOKEN_URL)

							NOW_MS=$(($(date +%s) * 1000))
							REMAINING_MS=$((EXPIRES - NOW_MS))
							NINETY_MIN_MS=$((90 * 60 * 1000))
							REMAINING_HUMAN=$((REMAINING_MS / 60000))

							echo "access token expires in ${REMAINING_HUMAN} min"

							if [ "$REMAINING_MS" -gt "$NINETY_MIN_MS" ]; then
								echo "still > 90 min of life — skip refresh"
								exit 0
							fi

							echo "refreshing via $TOKEN_URL ..."
							HTTP_CODE=$(curl -sS -o /tmp/resp.json -w "%{http_code}" \
								-X POST "$TOKEN_URL" \
								-H "Content-Type: application/json" \
								-H "Accept: application/json" \
								-d "$(jq -n --arg rt "$REFRESH" --arg cid "$CLIENT_ID" \
									'{grant_type:"refresh_token", refresh_token:$rt, client_id:$cid}')") || {
								echo "curl failed network-level. Leaving tokens; next cron tick retries." >&2
								exit 1
							}
							RESP=$(cat /tmp/resp.json)

							if [ "$HTTP_CODE" != "200" ]; then
								ERR_TYPE=$(  echo "$RESP" | jq -r '.error.type    // .error // "unknown"')
								ERR_MSG=$(   echo "$RESP" | jq -r '.error.message // .error_description // .')
								echo "refresh HTTP $HTTP_CODE: $ERR_TYPE — $ERR_MSG" >&2
								case "$HTTP_CODE" in
									429) echo "rate limited. Existing token still valid for $REMAINING_HUMAN min — next cron tick handles retry." >&2 ;;
									400|401) echo "refresh token rejected. Likely expired or rotated by another client. Re-run ci/scripts/refresh-claude-oauth.sh from a logged-in laptop." >&2 ;;
								esac
								exit 1
							fi

							NEW_ACCESS=$( echo "$RESP" | jq -r '.access_token  // empty')
							NEW_REFRESH=$(echo "$RESP" | jq -r '.refresh_token // empty')
							EXPIRES_IN=$( echo "$RESP" | jq -r '.expires_in    // 28800')

							if [ -z "$NEW_ACCESS" ]; then
								echo "200 OK but no access_token in body: $RESP" >&2
								exit 1
							fi
							[ -z "$NEW_REFRESH" ] && NEW_REFRESH="$REFRESH"

							NEW_EXPIRES_MS=$(( ($(date +%s) + EXPIRES_IN) * 1000 ))
							echo "new token minted, expires_at=$NEW_EXPIRES_MS"

							# Write rotated bundle back to OpenBao. ESO will pick it
							# up on the next sync (5min) and patch the cluster Secret.
							# We force-sync via annotation below so agents see the
							# change within seconds, not minutes.
							export BAO_ADDR="http://openbao.openbao.svc:8200"
							BAO_TOKEN=$(kubectl get secret openbao-keys -n openbao \
								-o jsonpath='{.data.root-token}' | base64 -d)
							export BAO_TOKEN

							# bao CLI not in alpine/k8s; use the HTTP API.
							curl -sfS -X POST -H "X-Vault-Token: $BAO_TOKEN" \
								-H "Content-Type: application/json" \
								-d "$(jq -n \
									--arg at "$NEW_ACCESS" \
									--arg rt "$NEW_REFRESH" \
									--arg ex "$NEW_EXPIRES_MS" \
									--arg ci "$CLIENT_ID" \
									--arg tu "$TOKEN_URL" \
									'{data: {
										CLAUDE_CODE_OAUTH_TOKEN: $at,
										REFRESH_TOKEN:           $rt,
										EXPIRES_AT_MS:           $ex,
										CLIENT_ID:               $ci,
										TOKEN_URL:               $tu
									}}')" \
								"$BAO_ADDR/v1/secret/data/preview/claude-oauth-credentials" >/dev/null
							echo "OpenBao updated"

							# Force ESO to re-read OpenBao now (don't wait the 5min poll).
							NS=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
							kubectl annotate externalsecret claude-code-oauth -n "$NS" \
								"force-sync=$(date +%s)" --overwrite >/dev/null
							echo "ESO force-sync annotated; agents will see new token on next pod start"
							"""#]
						resources: {
							requests: {cpu: "10m", memory: "64Mi"}
							limits: {cpu: "200m", memory: "128Mi"}
						}
						volumeMounts: [{
							name:      "oauth"
							mountPath: "/run/oauth"
							readOnly:  true
						}]
						securityContext: {
							runAsNonRoot:             false
							allowPrivilegeEscalation: false
							capabilities: drop: ["ALL"]
							seccompProfile: type: "RuntimeDefault"
						}
					}]
					volumes: [{
						name: "oauth"
						secret: secretName: "claude-code-oauth"
					}]
				}
			}
		}
	},

	for _x in [
		{xrName: "github-app-token-refresh", ns:                  "kelos-system", saName: "github-app-token-refresh", secretName:                  "github-app-creds", tokenSecretName:                  "github-app-token"},
		{xrName: "github-app-token-refresh-events", ns:           "argo-events", saName:  "github-app-token-refresh-events", secretName:           "github-app-creds-events", tokenSecretName:           "github-app-token"},
		// example-bot installation — same App, different installation_id.
		// Token Secret name suffixed `-example-bot` so it can coexist with
		// the example-org token in the same namespace. kelos-system ns
		// because the panel + lead-dev spawners that consume it live
		// there.
		{xrName: "github-app-token-refresh-example-bot", ns:        "kelos-system", saName: "github-app-token-refresh-example-bot", secretName:        "github-app-creds-example-bot", tokenSecretName:        "github-app-token-example-bot"},
		// Argo Workflows ns — token consumed by build workflow steps
		// (git clone + GHCR push).
		{xrName: "github-app-token-refresh-workflows", ns:        "argo-workflows", saName: "github-app-token-refresh-workflows", secretName:        "github-app-creds-workflows", tokenSecretName:        "github-app-token"},
		// argocd ns — token consumed by the preview-cap-watchdog
		// CronJob (below) so it can call `DELETE …/labels/preview`
		// across example-org preview-onboarded repos when the active
		// preview count exceeds the cap. Re-uses the existing ESO-
		// synced github-app-creds-argocd Secret (already in argocd
		// ns for the ApplicationSet PR generator).
		{xrName: "github-app-token-refresh-argocd", ns:           "argocd",         saName: "github-app-token-refresh-argocd", secretName:           "github-app-creds-argocd", tokenSecretName:           "github-app-token"},
	] {
		{
			name:      _x.xrName
			namespace: _x.ns
			tier:      C.tier
			cluster:   C.name
			owner:     "platform-team"
			config: {
				schedule:                   "*/30 * * * *"
				concurrencyPolicy:          "Forbid"
				successfulJobsHistoryLimit: 1
				failedJobsHistoryLimit:     2
				jobTemplate: spec: template: {
					spec: {
						serviceAccountName: _x.saName
						restartPolicy:      "OnFailure"
						containers: [{
							name:  "refresh"
							image: "alpine/k8s:1.31.1@sha256:dfe8c7a06c41d0b6e8757da99531f8f302e9a2687fa0155af4c4087df585c9c8"
							env: [{
								name:  "TOKEN_SECRET_NAME"
								value: _x.tokenSecretName
							}]
							command: ["/bin/sh", "-c", #"""
								set -eu

								# alpine/k8s ships kubectl + curl but lacks openssl/jq.
								apk add --no-cache openssl jq >/dev/null

								# Read App credentials from the ESO-synced secret.
								APP_ID=$(cat /run/github-app/APP_ID)
								INSTALLATION_ID=$(cat /run/github-app/INSTALLATION_ID)
								cp /run/github-app/PRIVATE_KEY /tmp/key.pem
								chmod 0600 /tmp/key.pem

								# base64url helper: standard base64 with +/= → -_ and stripped padding.
								b64url() { openssl base64 -e -A | tr '+/' '-_' | tr -d '='; }

								NOW=$(date +%s)
								EXP=$((NOW + 540))   # 9 min, under GitHub's 10-min ceiling
								HEADER=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
								PAYLOAD=$(printf '{"iat":%d,"exp":%d,"iss":%s}' "$NOW" "$EXP" "$APP_ID" | b64url)
								SIG=$(printf '%s' "$HEADER.$PAYLOAD" | openssl dgst -sha256 -sign /tmp/key.pem | b64url)
								JWT="$HEADER.$PAYLOAD.$SIG"
								rm -f /tmp/key.pem

								# Exchange JWT for installation access token (valid 1h).
								RESP=$(curl -sfS -X POST \
									-H "Authorization: Bearer $JWT" \
									-H "Accept: application/vnd.github+json" \
									"https://api.github.com/app/installations/$INSTALLATION_ID/access_tokens")
								TOKEN=$(echo "$RESP" | jq -r '.token')
								EXPIRES=$(echo "$RESP" | jq -r '.expires_at')
								if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
									echo "token fetch failed: $RESP" >&2
									exit 1
								fi
								echo "minted token, expires_at=$EXPIRES"

								# Upsert Secret/$TOKEN_SECRET_NAME with three keys:
								#   - token (kept for backward compat with existing
								#     consumers that referenced .data.token)
								#   - expires_at
								#   - GITHUB_TOKEN (NEW — same value as token, named
								#     this way so the Kelos Workspace's auto-env
								#     injection picks it up. Kelos reads
								#     {GITHUB_TOKEN,GH_TOKEN} from the workspace
								#     Secret using the key literally named
								#     `GITHUB_TOKEN`; without this key the auto-inject
								#     was using whatever other Secret the Workspace
								#     pointed at, defeating per-Task secretRef
								#     overrides for GH_TOKEN.)
								# Name is templated per for-loop entry so the example-org
								# and example-bot installations don't clobber each other
								# in the same namespace.
								kubectl create secret generic "$TOKEN_SECRET_NAME" \
									--namespace="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)" \
									--from-literal=token="$TOKEN" \
									--from-literal=GITHUB_TOKEN="$TOKEN" \
									--from-literal=expires_at="$EXPIRES" \
									--dry-run=client -o yaml \
									| kubectl apply -f -
								"""#]
							resources: {
								requests: {cpu: "10m", memory: "64Mi"}
								limits: {cpu: "200m", memory: "128Mi"}
							}
							volumeMounts: [{
								name:      "app-creds"
								mountPath: "/run/github-app"
								readOnly:  true
							}]
							securityContext: {
								// Runs as root in-container so `apk add openssl jq`
								// can install the cryptography deps. No node-level
								// root: capabilities dropped, seccomp on, no
								// privilege escalation. Container-only blast radius.
								runAsNonRoot:             false
								allowPrivilegeEscalation: false
								capabilities: drop: ["ALL"]
								seccompProfile: type: "RuntimeDefault"
								readOnlyRootFilesystem: false // apk + openssl need writable /tmp + /var
							}
						}]
						volumes: [{
							name: "app-creds"
							secret: secretName: _x.secretName
						}]
					}
				}
			}
		}
	},

	// Velero restore drill — weekly automated restore test. Picks the
	// latest completed velero-openbao-hourly backup, restores it into a
	// throwaway `velero-restore-test` namespace via namespace-mappings,
	// asserts the openbao Secret came back, then nukes the test ns.
	// Posts to Discord on failure (success is silent).
	//
	// Why: a backup that's never restored is a backup that probably won't
	// restore. This validates: BSL connectivity, kopia repo integrity,
	// CSI/PVB restore path, RBAC for restore creation.
	//
	// Sunday 05:00 — picks whichever hourly backup is most recent
	// at run time (the openbao-hourly schedule fires every hour at :00).
	{
		name:      "velero-restore-drill"
		namespace: "velero"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			schedule:                   "0 5 * * 0"
			concurrencyPolicy:          "Forbid"
			successfulJobsHistoryLimit: 2
			failedJobsHistoryLimit:     5
			jobTemplate: spec: {
				backoffLimit: 0
				template: spec: {
					serviceAccountName: "velero-restore-drill"
					restartPolicy:      "Never"
					containers: [{
						name: "drill"
						// Bitnami moved versioned tags to paid; only `latest`
						// is on the free hub now. Pin via digest later if
						// drift becomes a concern.
						image: "bitnami/kubectl:latest"
						command: ["/bin/bash", "-c", #"""
							set -eu
							TS=$(date -u +%Y%m%dt%H%M%Sz)
							RESTORE_NS="velero-restore-test"
							RESTORE_NAME="drill-$TS"

							echo "[drill] picking latest openbao backup (Completed or PartiallyFailed)..."
							pick_latest() {
							  kubectl -n velero get backups.velero.io "$@" \
							    -o jsonpath='{range .items[*]}{.metadata.name},{.status.phase},{.status.completionTimestamp}{"\n"}{end}' \
							  | grep -E ',(Completed|PartiallyFailed),' \
							  | sort -t, -k3 \
							  | tail -1 \
							  | cut -d, -f1
							}
							BACKUP=$(pick_latest -l velero.io/schedule-name=velero-openbao-hourly)
							[ -z "$BACKUP" ] && BACKUP=$(pick_latest)
							[ -z "$BACKUP" ] && { echo "[drill] FAIL: no usable backup found"; exit 1; }
							echo "[drill] using backup: $BACKUP"

							echo "[drill] cleanup any previous test ns..."
							kubectl delete ns "$RESTORE_NS" --ignore-not-found --wait=true --timeout=2m || true

							echo "[drill] creating Restore CR $RESTORE_NAME..."
							cat <<EOF | kubectl apply -f -
							apiVersion: velero.io/v1
							kind: Restore
							metadata:
							  name: $RESTORE_NAME
							  namespace: velero
							spec:
							  backupName: $BACKUP
							  includedNamespaces: ["openbao"]
							  namespaceMapping:
							    openbao: $RESTORE_NS
							  restorePVs: true
							EOF

							echo "[drill] waiting for restore to finish..."
							for i in $(seq 1 60); do
							  PHASE=$(kubectl -n velero get restore.velero.io "$RESTORE_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
							  echo "  phase: $PHASE"
							  case "$PHASE" in
							    Completed|PartiallyFailed) break ;;
							    Failed|FailedValidation) echo "[drill] FAIL: $PHASE"; exit 1 ;;
							  esac
							  sleep 10
							done
							[ "$PHASE" != "Completed" ] && [ "$PHASE" != "PartiallyFailed" ] && { echo "[drill] FAIL: timeout"; exit 1; }

							echo "[drill] verifying restored Secret openbao-keys exists..."
							kubectl -n "$RESTORE_NS" get secret openbao-keys >/dev/null
							echo "[drill] PASS"

							echo "[drill] cleanup..."
							kubectl delete ns "$RESTORE_NS" --ignore-not-found --wait=false || true
							kubectl -n velero delete restore.velero.io "$RESTORE_NAME" --ignore-not-found || true
							"""#]
						resources: {
							requests: {cpu: "50m", memory: "128Mi"}
							limits: {cpu: "500m", memory: "512Mi"}
						}
					}]
				}
			}
		}
	},

	// ai-cost-aggregator — every hour, sum cost-usd + token counts from
	// the most recent Kelos Task pod logs (which print a
	// `---KELOS_OUTPUTS_START--- ... cost-usd: ... ---KELOS_OUTPUTS_END---`
	// block on completion), grouped by kelos.dev/role label. Posts a
	// rollup to the existing Discord webhook (preview/discord-webhook-url).
	// Lets the operator track which agent class is the most expensive.
	{
		name:      "ai-cost-aggregator"
		namespace: "kelos-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			schedule:                   "27 * * * *" // :27 each hour, off the :00 mark
			concurrencyPolicy:          "Forbid"
			successfulJobsHistoryLimit: 1
			failedJobsHistoryLimit:     1
			jobTemplate: spec: template: {
				spec: {
					serviceAccountName: "ai-cost-aggregator"
					restartPolicy:      "Never"
					containers: [{
						name:  "aggregator"
						image: "alpine/k8s:1.31.1@sha256:dfe8c7a06c41d0b6e8757da99531f8f302e9a2687fa0155af4c4087df585c9c8"
						command: ["/bin/sh", "-c", #"""
							set -eu
							# alpine/k8s ships busybox `date` which lacks both
							# GNU `-d` and BSD `-v`. Add coreutils for GNU date.
							apk add --no-cache jq bc coreutils >/dev/null

							WEBHOOK="$(cat /run/discord/url)"
							[ -z "$WEBHOOK" ] && { echo "no webhook"; exit 0; }

							# Window: tasks completed within the last 65 minutes
							# (5-minute overlap to avoid edge gaps between cron ticks).
							CUTOFF_RFC=$(date -u -d '-65 minutes' +%Y-%m-%dT%H:%M:%SZ)

							# List Tasks that finished in the window. We use Tasks
							# (not pods) for the timestamp because pods get GC'd
							# faster than Tasks (TTL up to 7200s on most agents).
							TASKS_JSON=$(kubectl -n kelos-system get tasks.kelos.dev -o json)
							ROLES=$(echo "$TASKS_JSON" | jq -r --arg c "$CUTOFF_RFC" '
								[ .items[]
								  | select(.status.phase == "Succeeded" or .status.phase == "Failed")
								  | select((.status.completionTime // "") >= $c)
								  | { role: (.metadata.labels["kelos.dev/role"] // "unknown")
								    , task: .metadata.name
								    }
								]' )

							TOTAL_TASKS=$(echo "$ROLES" | jq 'length')
							if [ "$TOTAL_TASKS" -eq 0 ]; then
								echo "no completed Tasks in last 65min — skip Discord post"
								exit 0
							fi

							# For each Task, read its pod log for cost-usd / input-tokens / output-tokens.
							# Pod logs may be evicted; skip silently when unreadable.
							ROWS_FILE=$(mktemp)
							# Pushgateway URL — same opencost-prometheus
							# helm release, pushgateway subchart now on.
							PGW="http://opencost-prometheus-prometheus-pushgateway.opencost.svc:9091"

							echo "$ROLES" | jq -c '.[]' | while read -r row; do
								ROLE=$(echo "$row" | jq -r '.role')
								TASK=$(echo "$row" | jq -r '.task')
								POD=$(kubectl -n kelos-system get pods -l "kelos.dev/task=$TASK" -o name 2>/dev/null | head -1)
								[ -z "$POD" ] && continue
								LOG=$(kubectl -n kelos-system logs "$POD" --tail=20 2>/dev/null || true)
								COST=$(echo "$LOG" | sed -n 's/^cost-usd: //p' | head -1)
								INTOK=$(echo "$LOG" | sed -n 's/^input-tokens: //p' | head -1)
								OUTTOK=$(echo "$LOG" | sed -n 's/^output-tokens: //p' | head -1)
								[ -z "$COST" ] && continue
								echo "$ROLE	$COST	${INTOK:-0}	${OUTTOK:-0}" >> "$ROWS_FILE"

								# Push per-Task metric to Prometheus. Grouping
								# key (task) makes each Task a separate entry
								# in pushgateway storage; the same task name
								# overwrites on a re-tick which is what we
								# want (idempotent within the 65min window).
								# URL-encode the role since it can contain '-'.
								printf '# TYPE kelos_task_cost_usd gauge\nkelos_task_cost_usd %s\n# TYPE kelos_task_input_tokens gauge\nkelos_task_input_tokens %s\n# TYPE kelos_task_output_tokens gauge\nkelos_task_output_tokens %s\n' \
									"$COST" "${INTOK:-0}" "${OUTTOK:-0}" \
									| curl -sS --max-time 5 \
									      --data-binary @- \
									      "$PGW/metrics/job/kelos_cost/role/$ROLE/task/$TASK" \
									      >/dev/null 2>&1 || \
									      echo "pushgateway push failed for $TASK (non-fatal)"
							done

							if [ ! -s "$ROWS_FILE" ]; then
								echo "no cost data in pod logs — skip"
								exit 0
							fi

							# Aggregate by role. printf %.4f keeps ~tenth-of-a-cent precision.
							SUMMARY=$(awk -F'\t' '
								{
									roles[$1]++
									cost[$1] += $2 + 0
									intok[$1] += $3 + 0
									outtok[$1] += $4 + 0
								}
								END {
									for (r in roles)
										printf "  %-30s %4d task(s)  $%7.4f  in=%6d  out=%6d\n",
										       r, roles[r], cost[r], intok[r], outtok[r]
								}
							' "$ROWS_FILE" | sort)

							TOTAL_COST=$(awk -F'\t' '{s+=$2} END {printf "%.4f", s}' "$ROWS_FILE")
							TOTAL_IN=$( awk -F'\t' '{s+=$3} END {print s+0}' "$ROWS_FILE")
							TOTAL_OUT=$(awk -F'\t' '{s+=$4} END {print s+0}' "$ROWS_FILE")

							# Skip near-zero rounds entirely (under $0.01).
							SKIP=$(awk -v c="$TOTAL_COST" 'BEGIN { print (c < 0.01) ? "yes" : "no" }')
							if [ "$SKIP" = "yes" ]; then
								echo "total $TOTAL_COST < \$0.01 — skip Discord post"
								exit 0
							fi

							BODY=$(printf ':moneybag: AI cost (last 1h): **\\$%s** total — %s in / %s out tokens\n```\n%s```' \
								"$TOTAL_COST" "$TOTAL_IN" "$TOTAL_OUT" "$SUMMARY")
							PAYLOAD=$(jq -n --arg c "$BODY" '{content: $c}')

							curl -sf -X POST -H 'Content-Type: application/json' -d "$PAYLOAD" "$WEBHOOK" >/dev/null \
								&& echo "posted hourly cost summary ($TOTAL_COST USD)" \
								|| echo "discord post failed"
							"""#]
						volumeMounts: [{
							name:      "discord"
							mountPath: "/run/discord"
							readOnly:  true
						}]
						resources: {
							requests: {cpu: "20m", memory: "64Mi"}
							limits: {cpu: "300m", memory: "256Mi"}
						}
						securityContext: {
							runAsNonRoot:             false
							allowPrivilegeEscalation: false
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

	// preview-cap-watchdog — every 15 min, enumerate open PRs labeled
	// `preview` across every example-org preview-onboarded repo, sort by
	// updated_at desc, and DELETE the `preview` label from any PR past
	// _previewCap. Safety net behind each repo's stack-label workflow
	// (the proactive gate that refuses to apply the label when the
	// count is already at cap).
	//
	// Happy path is silent (one log line, exit 0). Only logs detail
	// when actually pruning.
	//
	// Cadence: was */5 (288 Jobs/day) — overkill for a backstop behind
	// an already-proactive stack-label gate. Reduced to */15 on
	// 2026-05-23 alongside the openbao-auto-unseal slowdown.
	{
		name:      "preview-cap-watchdog"
		namespace: "argocd"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			schedule:                   "*/15 * * * *"
			concurrencyPolicy:          "Forbid"
			successfulJobsHistoryLimit: 1
			failedJobsHistoryLimit:     3
			jobTemplate: spec: template: {
				spec: {
					// Default SA in argocd ns — no k8s API access
					// needed, only mounts github-app-token (kubelet
					// resolves the Secret at pod-create time).
					restartPolicy: "OnFailure"
					containers: [{
						name:  "watchdog"
						image: "alpine/k8s:1.31.1@sha256:dfe8c7a06c41d0b6e8757da99531f8f302e9a2687fa0155af4c4087df585c9c8"
						env: [{
							name:  "PREVIEW_CAP"
							value: "\(_previewCap)"
						}, {
							name:  "PREVIEW_REPOS"
							value: _previewRepoList
						}]
						command: ["/bin/sh", "-c", #"""
							set -eu
							apk add --no-cache jq >/dev/null

							TOKEN=$(cat /run/github-token/token)
							if [ -z "$TOKEN" ]; then
							  echo "no github token mounted; exiting" >&2
							  exit 1
							fi

							# Aggregate open `preview`-labeled PRs across repos,
							# sorted globally by updated_at desc.
							all=$(
							  for repo in $PREVIEW_REPOS; do
							    curl -sfS \
							      -H "Authorization: token $TOKEN" \
							      -H "Accept: application/vnd.github+json" \
							      "https://api.github.com/repos/$repo/issues?state=open&labels=preview&per_page=100" \
							    | jq --arg repo "$repo" '[.[] | select(.pull_request) | {repo:$repo, number, updated_at, title}]'
							  done | jq -s '[.[][]] | sort_by(.updated_at) | reverse'
							)

							count=$(echo "$all" | jq 'length')
							echo "watchdog: $count active previews across [$PREVIEW_REPOS], cap=$PREVIEW_CAP"
							if [ "$count" -le "$PREVIEW_CAP" ]; then
							  exit 0
							fi

							echo "watchdog: pruning $((count - PREVIEW_CAP)) preview(s) over cap"
							echo "$all" | jq -r ".[${PREVIEW_CAP}:][] | \"\(.repo) \(.number) \(.title)\"" \
							| while read repo num title; do
							  echo "  removing 'preview' label: $repo PR#$num — $title"
							  if ! curl -sfS -X DELETE \
							      -H "Authorization: token $TOKEN" \
							      -H "Accept: application/vnd.github+json" \
							      "https://api.github.com/repos/$repo/issues/$num/labels/preview" \
							      -o /tmp/resp.json; then
							    rc=$?
							    if grep -q '"Label does not exist"' /tmp/resp.json 2>/dev/null; then
							      echo "    (label already absent — ok)"
							    else
							      echo "    DELETE failed (rc=$rc): $(cat /tmp/resp.json)" >&2
							    fi
							  fi
							done
							"""#]
						resources: {
							requests: {cpu: "10m", memory: "64Mi"}
							limits: {cpu: "200m", memory: "128Mi"}
						}
						volumeMounts: [{
							name:      "github-token"
							mountPath: "/run/github-token"
							readOnly:  true
						}]
						securityContext: {
							runAsNonRoot:             false
							allowPrivilegeEscalation: false
							capabilities: drop: ["ALL"]
							seccompProfile: type: "RuntimeDefault"
							readOnlyRootFilesystem: false
						}
					}]
					volumes: [{
						name: "github-token"
						secret: secretName: "github-app-token"
					}]
				}
			}
		}
	},

	// jarvy-tool-discovery — daily at 09:13 UTC (off-the-:00 to avoid
	// thundering herd against Grafana Cloud). Queries Loki for
	// tool.unsupported events from the past 7d, de-dupes against open
	// Jarvy PRs/issues, and dispatches up to MAX_DISPATCH (default 3)
	// tool-discoverer Kelos Tasks per run to scaffold + PR the
	// missing tools.
	//
	// Activation requires the user to seed grafana-loki-read-token
	// in OpenBao first (see externalsecrets.cue for the bao kv
	// command). Until that secret exists in kelos-system the CronJob
	// pods will CrashLoop on missing env — that is intentional and
	// loud (better than a silent no-op like the original
	// feature-flags gap).
	//
	// Killswitch: same feature-flags ConfigMap. Gates on
	// .data.tool-discovery-enabled == "true". Default is off so
	// landing the CronJob does not immediately start opening PRs;
	// flip when ready.
	{
		name:      "jarvy-tool-discovery"
		namespace: "kelos-system"
		tier:      C.tier
		cluster:   C.name
		owner:     "platform-team"
		config: {
			schedule:                   "13 9 * * *" // 09:13 UTC daily
			concurrencyPolicy:          "Forbid"
			successfulJobsHistoryLimit: 1
			failedJobsHistoryLimit:     3
			jobTemplate: spec: {
				backoffLimit: 0
				template: spec: {
					serviceAccountName: "jarvy-tool-discovery"
					restartPolicy:      "Never"
					containers: [{
						name:  "discovery"
						image: "alpine/k8s:1.31.1@sha256:dfe8c7a06c41d0b6e8757da99531f8f302e9a2687fa0155af4c4087df585c9c8"
						envFrom: [{
							secretRef: name: "grafana-loki-read-token"
						}]
						env: [{
							name: "GH_TOKEN"
							valueFrom: secretKeyRef: {
								name: "github-app-token"
								key:  "token"
							}
						}, {
							name:  "MAX_DISPATCH"
							value: "3"
						}, {
							// 48h look-back matches the daily cron cadence
							// (one tick / 24h) plus a 1-day overlap to catch
							// events that landed during the prior run's
							// processing window. The script de-dupes via
							// the registry / open-PR / open-issue
							// cross-references, so the overlap is harmless.
							name:  "WINDOW_HOURS"
							value: "48"
						}]
						command: ["/bin/sh", "-c", #"""
							set -eu

							# Feature flag — ConfigMap kelos-system/feature-flags
							# data.tool-discovery-enabled must equal "true".
							# Seed CMD lives in bootstrap-home.sh phase 8.6;
							# the flag defaults to "false" so landing this
							# CronJob does not immediately start opening PRs.
							ENABLED=$(kubectl get configmap feature-flags -n kelos-system \
							  -o jsonpath='{.data.tool-discovery-enabled}' 2>/dev/null || true)
							if [ "$ENABLED" != "true" ]; then
							  echo "feature-flags.tool-discovery-enabled=$ENABLED (need 'true'); skipping run"
							  exit 0
							fi

							# Rename Loki creds to the names the script expects.
							# envFrom from grafana-loki-read-token gives us:
							#   url      → LOKI_URL
							#   user_id  → LOKI_USER
							#   token    → LOKI_TOKEN
							# but the script also accepts the rendered names —
							# remapping here keeps the script portable.
							export LOKI_URL="${url:?missing url key in grafana-loki-read-token Secret}"
							export LOKI_USER="${user_id:?missing user_id key in grafana-loki-read-token Secret}"
							export LOKI_TOKEN="${token:?missing token key in grafana-loki-read-token Secret}"

							apk add --no-cache bash git jq curl >/dev/null
							if ! command -v kubectl >/dev/null 2>&1; then
							  echo "kubectl missing from image — abort"
							  exit 1
							fi

							# Pull the discovery script from k8-infra HEAD —
							# matches the autofix-dispatch pattern. Updating
							# the script does not require rebuilding any image.
							git clone --depth 1 https://x-access-token:${GH_TOKEN}@github.com/example-org/k8-infra.git /tmp/infra
							bash /tmp/infra/ci/scripts/jarvy-tool-discovery.sh
							"""#]
						resources: {
							requests: {cpu: "20m", memory: "64Mi"}
							limits: {cpu: "500m", memory: "256Mi"}
						}
						securityContext: {
							allowPrivilegeEscalation: false
							capabilities: drop: ["ALL"]
							seccompProfile: type: "RuntimeDefault"
							readOnlyRootFilesystem: false
						}
					}]
				}
			}
		}
	},
]
