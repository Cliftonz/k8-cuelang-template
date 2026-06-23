#!/usr/bin/env bash
#
# Seed secret/preview/cloudflare-provider-token in the home cluster's
# OpenBao. Run from your laptop after you've minted a scoped Cloudflare
# API token in Cloudflare UI → My Profile → API Tokens → Create Token.
#
# Required scopes on the token:
#   Zone → Zone → Read              (look up example.com zone ID)
#   Zone → Zone WAF → Edit          (custom WAF rules)
#   Zone → Zone Settings → Edit     (Bot Fight Mode toggle)
#   Account → Rulesets → Edit       (rate-limit rules)
# Zone Resources: Include → Specific zone → example.com
#
# Idempotent — re-running prints OK without rotating unless you pass
# --rotate. Rotating triggers all Crossplane-managed Cloudflare
# resources to re-reconcile under the new token on next ESO sync.
#
# Prereqs:
#   - `bao` CLI installed
#   - kubectl context pointed at talos-home
#   - BAO_TOKEN env var set OR `bao login` already done
#   - jq + curl (macOS ships both)

set -euo pipefail

KV_PATH="secret/preview/cloudflare-provider-token"
KEY_NAME="CLOUDFLARE_API_TOKEN"
ROTATE="${1:-}"

# ── 0. Sanity ──────────────────────────────────────────────────────
for bin in bao kubectl jq curl; do
  command -v "$bin" >/dev/null || { echo "✗ '$bin' not on PATH"; exit 1; }
done

ctx=$(kubectl config current-context)
[ "$ctx" = "talos-home" ] || {
  echo "✗ kubectl context is '$ctx' — switch to talos-home first"
  exit 1
}

# ── 1. Port-forward OpenBao ────────────────────────────────────────
PORT=18200
trap 'kill $PF_PID 2>/dev/null || true; wait $PF_PID 2>/dev/null || true' EXIT

echo "▶ port-forwarding openbao :$PORT → openbao-0:8200 …"
kubectl port-forward -n openbao svc/openbao "$PORT":8200 \
  >/tmp/bao-pf.log 2>&1 &
PF_PID=$!

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

# ── 2. Confirm unsealed + token ────────────────────────────────────
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
  echo "    bao login    # interactive"
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
  echo "⚠ --rotate given. Existing Crossplane-managed Cloudflare resources"
  echo "  will re-reconcile under the new token on next ESO sync."
  read -r -p "  Continue? [y/N] " ans
  [ "${ans:-N}" = "y" ] || { echo "aborted"; exit 1; }
fi

# ── 4. Prompt for token + validate ─────────────────────────────────
echo
echo "Paste the Cloudflare API token (input is hidden):"
read -rs TOKEN
echo
[ -n "$TOKEN" ] || { echo "✗ empty token"; exit 1; }

echo "▶ validating token against Cloudflare API …"
verify=$(curl -sS -H "Authorization: Bearer $TOKEN" \
  https://api.cloudflare.com/client/v4/user/tokens/verify 2>&1)
status=$(echo "$verify" | jq -r '.success // false')
if [ "$status" != "true" ]; then
  echo "✗ Cloudflare rejected the token:"
  echo "$verify" | jq -r '.errors[]? | "  - \(.message)"' 2>&1 | head -3
  exit 1
fi
echo "✓ token valid: $(echo "$verify" | jq -r '.result.status')"

# ── 5. Write + verify ──────────────────────────────────────────────
echo "▶ writing $KV_PATH …"
bao kv put -mount=secret preview/cloudflare-provider-token \
  "${KEY_NAME}=${TOKEN}" >/dev/null
echo "✓ wrote $KV_PATH"

got=$(bao kv get -format=json "$KV_PATH" | jq -r ".data.data.${KEY_NAME}")
[ "$got" = "$TOKEN" ] || { echo "✗ read-back mismatch"; exit 1; }
echo "✓ read-back confirms"

# ── 6. Nudge ESO ───────────────────────────────────────────────────
echo "▶ annotating ExternalSecret to force re-sync …"
kubectl annotate externalsecret cloudflare-provider-creds \
  -n crossplane-system \
  force-sync="$(date +%s)" --overwrite 2>/dev/null \
  && echo "✓ ESO force-sync triggered" \
  || echo "  (ExternalSecret not yet applied — that's fine, it'll sync on first reconcile)"

echo
echo "Done. Next: apply infrastructure/crossplane/providers/cloudflare/"
echo "  kubectl apply -f infrastructure/crossplane/providers/cloudflare/provider.yaml"
echo "  # wait ~30s for CRDs to install"
echo "  kubectl apply -f infrastructure/crossplane/providers/cloudflare/providerconfig.yaml"
