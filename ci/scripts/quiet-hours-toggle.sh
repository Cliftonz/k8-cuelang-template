#!/usr/bin/env bash
# quiet-hours-toggle.sh — pauses / resumes LLM-consuming agents to avoid
# burning Claude Pro/Max session quota during the operator's active work hours.
#
# Invoked by two CronJobs:
#   quiet-hours-enter  (8am ET weekdays) → MODE=enter
#   quiet-hours-exit   (2pm ET weekdays) → MODE=exit
#
# Mechanism:
#   - Patches every TaskSpawner in kelos-system: spec.suspend = true/false
#     UNLESS annotated `open-warren.io/always-on=true`.
#   - Patches Sensors in argo-events from LLM_SENSORS allowlist below:
#     spec.replicas = 0/1. (These are the Sensors that create Kelos
#     Tasks; lightweight Jobs like branch-create + /help + palette-init
#     stay running.)
#
# Global override:
#   If ConfigMap `open-warren-quiet-hours` (namespace: kelos-system) has
#   field `disabled: "true"`, this script exits 0 with no action.
#
# Manual bypass for a specific resource during quiet hours:
#   kubectl annotate taskspawner <name> -n kelos-system \
#     open-warren.io/always-on=true --overwrite
#   kubectl patch taskspawner <name> -n kelos-system \
#     --type merge -p '{"spec":{"suspend":false}}'
#
# Required env:
#   MODE  — enter | exit
#
# Script is idempotent: safe to re-run, safe if already in the target state.

set -euo pipefail

: "${MODE:?MODE env var required (enter | exit)}"
[ "$MODE" = "enter" ] || [ "$MODE" = "exit" ] || {
  echo "MODE must be 'enter' or 'exit', got: $MODE" >&2
  exit 1
}

log() { echo "[quiet-hours-$MODE] $*" >&2; }

# ─── Global override check ───────────────────────────────────────────────
DISABLED=$(kubectl get configmap open-warren-quiet-hours -n kelos-system \
  -o jsonpath='{.data.disabled}' 2>/dev/null || echo "")
if [ "$DISABLED" = "true" ]; then
  log "global override: disabled=true — no action"
  exit 0
fi

# ─── Determine target states ─────────────────────────────────────────────
if [ "$MODE" = "enter" ]; then
  SUSPEND="true"
  REPLICAS="0"
else
  SUSPEND="false"
  REPLICAS="1"
fi

log "target: suspend=$SUSPEND replicas=$REPLICAS"

# ─── Suspend / resume TaskSpawners ──────────────────────────────────────
TASKSPAWNERS=$(kubectl get taskspawner -n kelos-system -o json 2>/dev/null \
  | jq -r '.items[] |
           select(.metadata.annotations["open-warren.io/always-on"] != "true") |
           .metadata.name')

TS_COUNT=0
for ts in $TASKSPAWNERS; do
  CURRENT=$(kubectl get taskspawner "$ts" -n kelos-system \
    -o jsonpath='{.spec.suspend}' 2>/dev/null || echo "false")
  if [ "$CURRENT" = "$SUSPEND" ]; then
    log "  taskspawner/$ts already suspend=$SUSPEND — skip"
    continue
  fi
  log "  taskspawner/$ts: suspend=$CURRENT → $SUSPEND"
  kubectl patch taskspawner "$ts" -n kelos-system --type merge \
    -p "{\"spec\":{\"suspend\":${SUSPEND}}}" >/dev/null
  TS_COUNT=$((TS_COUNT + 1))
done
log "patched $TS_COUNT TaskSpawners"

# ─── Scale Sensors (LLM-sensors only) ───────────────────────────────────
# Argo Events Sensors have `spec.replicas`. Setting it scales the underlying
# Deployment managed by the Argo Events controller.
# Allowlist: Sensors that create Kelos Tasks (i.e., consume LLM quota).
# Does NOT include lightweight Job-producing Sensors (branch-create,
# human-resume, palette-init, slash-help, preview-deploy).
LLM_SENSORS=(
  feature-ideator
  feature-implementer
  feature-review-tier1
  feature-review-orchestrator
  code-explain
)
SENSORS="${LLM_SENSORS[*]}"

SEN_COUNT=0
for s in $SENSORS; do
  CURRENT=$(kubectl get sensor "$s" -n argo-events \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
  if [ "$CURRENT" = "$REPLICAS" ]; then
    log "  sensor/$s already replicas=$REPLICAS — skip"
    continue
  fi
  log "  sensor/$s: replicas=$CURRENT → $REPLICAS"
  kubectl patch sensor "$s" -n argo-events --type merge \
    -p "{\"spec\":{\"replicas\":${REPLICAS}}}" >/dev/null
  SEN_COUNT=$((SEN_COUNT + 1))
done
log "patched $SEN_COUNT Sensors"

log "done: $MODE complete"
