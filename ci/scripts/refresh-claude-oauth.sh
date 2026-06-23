#!/usr/bin/env bash
# Refresh the Claude OAuth credentials in OpenBao and force an ESO sync.
#
# Seeds the FULL OAuth bundle (access + refresh + expiry + client config)
# so the cluster's claude-oauth-refresher CronJob can auto-renew the
# access token using the refresh token, without your laptop in the loop.
#
# Re-run this script when:
#   - you log in to a new machine
#   - the refresh token itself expires (~30 days, or whenever you log out)
#   - the watchdog Discord-pings you to re-seed
#
# Run after `claude /login`. macOS only (reads keychain).
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "this script reads from macOS keychain — adapt for linux if needed" >&2
  exit 1
fi

for bin in jq bao kubectl security; do
  command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 1; }
done

echo ">> reading credentials from macOS keychain..."
RAW=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)
if [[ -z "$RAW" ]]; then
  echo "keychain entry 'Claude Code-credentials' not found — run \`claude /login\` first" >&2
  exit 1
fi

ACCESS_TOKEN=$(jq -r '.claudeAiOauth.accessToken'  <<<"$RAW")
REFRESH_TOKEN=$(jq -r '.claudeAiOauth.refreshToken' <<<"$RAW")
EXPIRES=$(jq      -r '.claudeAiOauth.expiresAt'    <<<"$RAW")
if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "null" ]]; then
  echo "no accessToken in keychain — re-run \`claude /login\`" >&2
  exit 1
fi
if [[ -z "$REFRESH_TOKEN" || "$REFRESH_TOKEN" == "null" ]]; then
  echo "no refreshToken in keychain — re-run \`claude /login\` (or this version of claude doesn't store one)" >&2
  exit 1
fi

# Public OAuth client_id baked into the claude-code CLI. If Anthropic
# rotates this, override with: CLAUDE_OAUTH_CLIENT_ID=... ./this-script
CLIENT_ID="${CLAUDE_OAUTH_CLIENT_ID:-9d1c250a-e61b-44d9-88ed-5944d1962f5e}"
TOKEN_URL="${CLAUDE_OAUTH_TOKEN_URL:-https://console.anthropic.com/v1/oauth/token}"

EXPIRES_HUMAN=$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp($EXPIRES/1000))")
echo ">> access:  ${ACCESS_TOKEN:0:20}...  expires: $EXPIRES_HUMAN"
echo ">> refresh: ${REFRESH_TOKEN:0:20}...  (used by cluster watchdog to auto-renew)"

echo ">> starting OpenBao port-forward..."
kubectl port-forward -n openbao svc/openbao 8200:8200 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 3

export BAO_ADDR=http://localhost:8200
BAO_TOKEN=$(kubectl get secret openbao-keys -n openbao -o jsonpath='{.data.root-token}' | base64 -d)
export BAO_TOKEN

echo ">> writing all 5 fields to preview/claude-oauth-credentials..."
bao kv put -mount=secret preview/claude-oauth-credentials \
  CLAUDE_CODE_OAUTH_TOKEN="$ACCESS_TOKEN" \
  REFRESH_TOKEN="$REFRESH_TOKEN" \
  EXPIRES_AT_MS="$EXPIRES" \
  CLIENT_ID="$CLIENT_ID" \
  TOKEN_URL="$TOKEN_URL" >/dev/null

echo ">> forcing ESO sync..."
kubectl annotate externalsecret claude-code-oauth -n kelos-system \
  force-sync="$(date +%s)" --overwrite >/dev/null

echo ">> waiting for ESO refresh..."
for i in {1..30}; do
  COND=$(kubectl get externalsecret claude-code-oauth -n kelos-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [[ "$COND" == "True" ]]; then
    REFRESH_TIME=$(kubectl get externalsecret claude-code-oauth -n kelos-system \
      -o jsonpath='{.status.refreshTime}')
    echo "   refreshed at: $REFRESH_TIME"
    break
  fi
  sleep 2
done

ANNOT=$(kubectl get secret claude-code-oauth -n kelos-system \
  -o jsonpath='{.metadata.annotations.kelos\.dev/oauth-expires-at}' 2>/dev/null || true)
if [[ -n "$ANNOT" ]]; then
  echo ">> Secret expiry annotation: $(python3 -c "import datetime; print(datetime.datetime.fromtimestamp($ANNOT/1000))")"
fi

echo
echo ">> seeded. The claude-oauth-refresher CronJob in kelos-system will"
echo "   now auto-renew the access token every 30min using the refresh"
echo "   token. You should not need to run this script again until the"
echo "   refresh token itself expires (~30 days), at which point the"
echo "   watchdog will Discord-alert you."
echo
echo ">> smoke-test (optional):"
cat <<'EOF'
  cat <<'YAML' | kubectl create -f -
  apiVersion: kelos.dev/v1alpha1
  kind: Task
  metadata:
    generateName: oauth-smoketest-
    namespace: kelos-system
  spec:
    type: claude-code
    credentials: {type: oauth, secretRef: {name: claude-code-oauth}}
    prompt: "Print the single word OK and stop."
    ttlSecondsAfterFinished: 60
  YAML
EOF
