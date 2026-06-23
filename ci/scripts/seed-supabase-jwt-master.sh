#!/usr/bin/env bash
#
# Seed secret/preview/app/supabase-jwt-master in the home cluster's
# OpenBao. Run from your laptop. Idempotent — re-running prints OK
# without rotating unless you pass --rotate.
#
# This value is the HMAC seed every preview chart's jwt-init Job uses
# to derive deterministic per-PR JWT secrets + anon/service-role JWTs.
# Same secret across rebuilds of the same preview (auth tokens survive
# a pod restart), isolated across previews. Rotating it forces every
# preview to sign every user out.
#
# Prereqs:
#   - `bao` CLI installed (brew install openbao or download from
#     https://github.com/openbao/openbao/releases)
#   - kubectl context already pointed at talos-home
#   - You're already logged in to OpenBao via the BAO_TOKEN env var
#     OR have run `bao login` against the same host before
#   - openssl + jq + curl (macOS ships all three)

set -euo pipefail

KV_PATH="secret/preview/app/supabase-jwt-master"
KEY_NAME="JWT_MASTER_KEY"
ROTATE="${1:-}"

# ── 0. Sanity ──────────────────────────────────────────────────────
for bin in bao kubectl openssl jq; do
  command -v "$bin" >/dev/null || { echo "✗ '$bin' not on PATH"; exit 1; }
done

ctx=$(kubectl config current-context)
[ "$ctx" = "talos-home" ] || {
  echo "✗ kubectl context is '$ctx' — switch to talos-home first"
  exit 1
}

# ── 1. Port-forward OpenBao in the background ──────────────────────
PORT=18200    # local port; avoid 8200 in case bao already bound to it
trap 'kill $PF_PID 2>/dev/null || true; wait $PF_PID 2>/dev/null || true' EXIT

echo "▶ port-forwarding openbao :$PORT → openbao-0:8200 …"
kubectl port-forward -n openbao svc/openbao "$PORT":8200 \
  >/tmp/bao-pf.log 2>&1 &
PF_PID=$!

# Wait up to 10s for the forward to be ready.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sf "http://127.0.0.1:$PORT/v1/sys/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -sf "http://127.0.0.1:$PORT/v1/sys/health" >/dev/null 2>&1 || {
  echo "✗ port-forward never came up — last 10 lines of log:"
  tail -10 /tmp/bao-pf.log
  exit 1
}

export BAO_ADDR="http://127.0.0.1:$PORT"
echo "✓ BAO_ADDR=$BAO_ADDR"

# ── 2. Confirm OpenBao is unsealed + token works ───────────────────
# Hit the raw seal-status endpoint (works without auth, unlike `bao status`
# which can be picky about token state on some OpenBao versions).
# jq's `//` operator treats `false` as triggering the fallback (same as
# null/missing), so the obvious `.sealed // "unknown"` returns "unknown"
# when OpenBao is actually unsealed. Use an explicit has() check.
sealed=$(curl -sf "http://127.0.0.1:$PORT/v1/sys/seal-status" 2>/dev/null \
  | jq -r 'if has("sealed") then (.sealed | tostring) else "unknown" end')
[ "$sealed" = "false" ] || { echo "✗ OpenBao reports sealed=$sealed — unseal first"; exit 1; }
echo "✓ OpenBao unsealed"

if ! bao token lookup -format=json >/dev/null 2>&1; then
  echo "✗ no valid bao token in env. Either:"
  echo "    export BAO_TOKEN=<root-or-app-token>"
  echo "  or"
  echo "    bao login    # interactive (uses BAO_ADDR=$BAO_ADDR)"
  exit 1
fi
echo "✓ token authenticated"

# ── 3. Idempotency guard ───────────────────────────────────────────
existing=$(bao kv get -format=json "$KV_PATH" 2>/dev/null \
  | jq -r ".data.data.${KEY_NAME} // \"\"")
if [ -n "$existing" ]; then
  echo "✓ $KV_PATH already has ${KEY_NAME} (${#existing} chars)."
  if [ "$ROTATE" != "--rotate" ]; then
    echo "  Pass --rotate to overwrite. Exiting cleanly."
    exit 0
  fi
  echo "⚠ --rotate given. Every preview will be signed out after its"
  echo "  jwt-init Job re-runs and per-namespace Secrets are recreated."
  read -r -p "  Continue? [y/N] " ans
  [ "${ans:-N}" = "y" ] || { echo "aborted"; exit 1; }
fi

# ── 4. Generate + write ────────────────────────────────────────────
NEW_KEY=$(openssl rand -hex 32)
echo "▶ writing $KV_PATH (${#NEW_KEY} hex chars) …"
bao kv put -mount=secret preview/app/supabase-jwt-master \
  "${KEY_NAME}=${NEW_KEY}" >/dev/null
echo "✓ wrote $KV_PATH"

# ── 5. Read back ───────────────────────────────────────────────────
got=$(bao kv get -format=json "$KV_PATH" \
  | jq -r ".data.data.${KEY_NAME}")
[ "$got" = "$NEW_KEY" ] || { echo "✗ read-back mismatch"; exit 1; }
echo "✓ read-back confirms 64-char value"

# ── 6. Nudge ESO so every preview namespace picks up JWT_MASTER_KEY ─
echo "▶ annotating ClusterExternalSecret/app-shared-secrets to force re-sync …"
kubectl annotate clusterexternalsecret app-shared-secrets \
  force-sync="$(date +%s)" --overwrite >/dev/null
# Also annotate any already-existing per-namespace ExternalSecret
# (saves waiting up to the 5-min refresh interval).
for ns in $(kubectl get ns -l preview=true -o jsonpath='{.items[*].metadata.name}'); do
  kubectl annotate externalsecret app-shared-secrets -n "$ns" \
    force-sync="$(date +%s)" --overwrite >/dev/null 2>&1 || true
done
echo "✓ ESO force-sync triggered"

echo
echo "All done. Spot-check a preview ns within ~10s:"
echo "  kubectl get secret app-shared-secrets -n preview-salessage-182 -o json \\"
echo "    | jq -r '.data.JWT_MASTER_KEY' | base64 -d | head -c 16; echo …"
