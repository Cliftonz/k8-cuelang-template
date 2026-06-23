#!/usr/bin/env bash
# Wire OpenBao's OIDC auth method to the in-cluster Dex installation,
# create admin + readonly policies, and bind each policy to the matching
# Workspace group via Dex group claims.
#
# Run this ONCE after the Dex helm release is up and the OIDC clients
# are reachable via Dex's discovery endpoint
# (https://dex.example.com/.well-known/openid-configuration).
#
# Prereqs:
#   - bao CLI installed and BAO_TOKEN env var set to a token with sudo
#     (root token or an admin policy token).
#   - bao CLI port-forwarded or reachable at $BAO_ADDR
#     (default: https://openbao.example.internal).
#   - Dex secret for openbao client in OpenBao at
#     secret/home/dex/clients (property: openbao).
#
# Idempotent: every command uses bao primitives that are safe to re-run.

set -euo pipefail

BAO_ADDR="${BAO_ADDR:-https://openbao.example.internal}"
export VAULT_ADDR="$BAO_ADDR"

log() { printf '[dex-oidc] %s\n' "$*"; }

if ! command -v bao >/dev/null 2>&1; then
  echo "bao CLI not on PATH — brew install openbao" >&2
  exit 1
fi
if [[ -z "${BAO_TOKEN:-${VAULT_TOKEN:-}}" ]]; then
  echo "BAO_TOKEN (or VAULT_TOKEN) env var required" >&2
  exit 1
fi

# Pull the OpenBao OIDC client secret out of secret/home/dex/clients so
# we don't have to copy-paste it. If the kv put step from the migration
# session put it elsewhere, override OIDC_CLIENT_SECRET in the env.
if [[ -z "${OIDC_CLIENT_SECRET:-}" ]]; then
  OIDC_CLIENT_SECRET="$(bao kv get -field=openbao secret/home/dex/clients 2>/dev/null || true)"
fi
if [[ -z "$OIDC_CLIENT_SECRET" ]]; then
  echo "ERROR: OIDC_CLIENT_SECRET empty — secret/home/dex/clients property=openbao missing." >&2
  echo "  Seed it first:" >&2
  echo "    bao kv patch secret/home/dex/clients openbao=\$(openssl rand -hex 32)" >&2
  exit 1
fi
if [[ ${#OIDC_CLIENT_SECRET} -lt 16 ]]; then
  echo "ERROR: OIDC_CLIENT_SECRET too short (${#OIDC_CLIENT_SECRET} chars). Likely a misconfig." >&2
  exit 1
fi

log "1. enable oidc auth method (no-op if already enabled)..."
bao auth list -format=json | grep -q '"oidc/"' \
  || bao auth enable oidc

log "2. configure oidc method to point at Dex..."
# oidc_response_mode defaults to "query" — Dex returns code+state as URL
# query params on a GET redirect, which the OpenBao UI's React router
# catches at /ui/vault/auth/oidc/oidc/callback. The UI then calls
# /v1/auth/oidc/oidc/callback via fetch (server-to-server) to exchange
# the code and stores the resulting token.
#
# Do NOT set form_post here — that mode is specifically for Azure +
# id_token response_type, and it forces the redirect to the /v1/
# server endpoint, which renders the token JSON directly in the user's
# URL bar instead of letting the UI handle the callback. We hit this
# bug on 2026-05-16; previously this script wrote oidc_response_mode=
# form_post which broke browser sign-in completely.
bao write auth/oidc/config \
  oidc_discovery_url="https://dex.example.com" \
  oidc_client_id="openbao" \
  oidc_client_secret="$OIDC_CLIENT_SECRET" \
  default_role="readonly"

log "3. write admin + readonly policies..."
bao policy write admin - <<'POLICY'
# Admin — full access everywhere (excluding system internals already
# protected by Vault's built-in barriers). For day-to-day operator
# work, prefer using the root token directly only for break-glass.
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
POLICY

bao policy write readonly - <<'POLICY'
# Read-only — list + read across all KV mounts. No mutation,
# no sudo. Use this for sharing access with a teammate who needs
# to inspect cluster secrets but not change them.
path "secret/*" {
  capabilities = ["read", "list"]
}
path "kv/*" {
  capabilities = ["read", "list"]
}
path "sys/policies/acl" {
  capabilities = ["list"]
}
POLICY

log "4. bind admin role to eng-admin@example.com group..."
# bound_claims is a map, not a string — pass as JSON via stdin.
# oidc_scopes drives which scopes OpenBao requests from Dex; default is
# just "openid" which doesn't return email/groups claims. Without
# email+groups, user_claim=email + groups_claim=groups won't match.
bao write auth/oidc/role/admin - <<'EOF'
{
  "bound_audiences": "openbao",
  "user_claim": "email",
  "groups_claim": "groups",
  "bound_claims_type": "glob",
  "bound_claims": {"groups": "eng-admin@example.com"},
  "oidc_scopes": ["openid", "email", "profile", "groups"],
  "allowed_redirect_uris": "https://openbao.example.internal/ui/vault/auth/oidc/oidc/callback,https://openbao.example.internal/v1/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback",
  "policies": "admin",
  "ttl": "1h"
}
EOF

log "5. bind readonly role to eng-readonly@example.com group..."
bao write auth/oidc/role/readonly - <<'EOF'
{
  "bound_audiences": "openbao",
  "user_claim": "email",
  "groups_claim": "groups",
  "bound_claims_type": "glob",
  "bound_claims": {"groups": "eng-readonly@example.com"},
  "oidc_scopes": ["openid", "email", "profile", "groups"],
  "allowed_redirect_uris": "https://openbao.example.internal/ui/vault/auth/oidc/oidc/callback,https://openbao.example.internal/v1/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback",
  "policies": "readonly",
  "ttl": "1h"
}
EOF

log "done. Verify by opening https://openbao.example.internal/ in a"
log "browser → sign in via OIDC → Google account in a group should land"
log "with the matching policy. CLI test:"
log "  bao login -method=oidc role=admin"
