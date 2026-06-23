#!/usr/bin/env bash
# Toggle the feature-review pipeline kill switch.
#
# When enabled, the panel-spawner + spawn-lead-dev sensor Jobs see the
# `feature-review-killswitch` ConfigMap with data.disabled=true and exit
# 0 immediately — sensors still fire on webhooks but no Kelos Tasks
# spawn, no GitHub Check Runs are created, no agents run.
#
# This is faster + safer than scaling sensors to 0 (which doesn't
# always honor) or pausing the XR (which requires re-render to resume).
#
# Usage:
#   feature-review-killswitch.sh on    # halt panel + lead-dev
#   feature-review-killswitch.sh off   # resume
#   feature-review-killswitch.sh status
set -euo pipefail

NS="kelos-system"
CM="feature-review-killswitch"

case "${1:-status}" in
  on|enable|kill|halt)
    if kubectl -n "$NS" get configmap "$CM" >/dev/null 2>&1; then
      kubectl -n "$NS" patch configmap "$CM" -p '{"data":{"disabled":"true"}}'
    else
      kubectl -n "$NS" create configmap "$CM" --from-literal=disabled=true
    fi
    echo "✓ feature-review pipeline halted (panel + lead-dev spawners no-op)"
    ;;

  off|disable|resume)
    if kubectl -n "$NS" get configmap "$CM" >/dev/null 2>&1; then
      kubectl -n "$NS" delete configmap "$CM"
      echo "✓ feature-review pipeline resumed"
    else
      echo "feature-review pipeline already enabled (no kill-switch CM present)"
    fi
    ;;

  status)
    if VAL=$(kubectl -n "$NS" get configmap "$CM" -o jsonpath='{.data.disabled}' 2>/dev/null); then
      if [[ "$VAL" == "true" ]]; then
        echo "HALTED — kill switch is ON. Run \`$0 off\` to resume."
      else
        echo "ENABLED — kill-switch CM exists but disabled=\"$VAL\" (not \"true\")"
      fi
    else
      echo "ENABLED — no kill-switch CM present"
    fi
    ;;

  *)
    echo "usage: $0 {on|off|status}" >&2
    exit 2
    ;;
esac
