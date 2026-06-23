# hermes-agent

Vendored copy of the unofficial [ultraworkers/hermes-agent-helm-chart](https://github.com/ultraworkers/hermes-agent-helm-chart)
for [Nous Research's Hermes Agent](https://github.com/nousresearch/hermes-agent).

## Why vendored

The upstream chart isn't published to a Helm repo or OCI registry, so we vendor
it. ArgoCD reads it directly from `infrastructure/hermes-agent/chart/` in this
repo (see the ArgoCD Application in `composites/home/argocd.cue` — no OCI push
needed).

## Vendored commit

- **Upstream**: `ultraworkers/hermes-agent-helm-chart`
- **Commit**: `e3b685d4d0288668a37216435742cd0a659ebc6c`
- **Chart version**: `0.1.0`
- **App version**: `0.8.0`

## Refreshing the vendored copy

```bash
cd infrastructure/hermes-agent
rm -rf chart
git clone --depth=1 https://github.com/ultraworkers/hermes-agent-helm-chart.git chart
NEW_SHA=$(cd chart && git rev-parse HEAD)
rm -rf chart/.git
# Update the SHA in this README
sed -i.bak "s/^- \*\*Commit\*\*:.*/- **Commit**: \`$NEW_SHA\`/" README.md && rm README.md.bak
# Commit + push. ArgoCD picks up the new chart on next reconcile.
```

If the chart version field in `chart/Chart.yaml` changes, also update the
vendored-commit block above so the version is discoverable from the README.

## Seeding secrets (one-time)

The chart's `secrets.existingSecret` points at `hermes-secrets` which ESO
syncs from `secret/home/hermes` in OpenBao (see
`composites/home/externalsecrets.cue`). Only `AI_GATEWAY_API_KEY` is required
for the default Vercel AI Gateway config; the others are pre-wired placeholders
so individual provider keys can be added without re-rendering CUE.

> [!IMPORTANT]
> The ExternalSecret references all three keys (`AI_GATEWAY_API_KEY`,
> `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`). If any of them is missing from
> the OpenBao path the whole sync fails. Use the multi-key form below (with
> empty strings for the ones you don't use) on first seed.

```bash
# Read the root token straight from the cluster
ROOT=$(kubectl -n openbao get secret openbao-keys -o jsonpath='{.data.root-token}' | base64 -d)

# Generate an API_SERVER_KEY (Hermes refuses to bind apiServer on 0.0.0.0
# without one). Save locally so you can hit the API with `Authorization:
# Bearer <key>`.
mkdir -p /tmp/hermes-api
openssl rand -hex 32 > /tmp/hermes-api/API_SERVER_KEY
chmod 600 /tmp/hermes-api/API_SERVER_KEY

# Set all four keys in one shot. Empty strings are fine for ANTHROPIC and
# OPENROUTER; the ExternalSecret requires all four to be present in OpenBao
# or the sync fails. Hermes only uses keys it actually needs at runtime.
API_KEY=$(cat /tmp/hermes-api/API_SERVER_KEY)
kubectl -n openbao exec openbao-0 -- env BAO_TOKEN="$ROOT" \
  bao kv put secret/home/hermes \
  AI_GATEWAY_API_KEY='<paste-your-vercel-ai-gateway-key>' \
  ANTHROPIC_API_KEY='' \
  OPENROUTER_API_KEY='' \
  API_SERVER_KEY="$API_KEY"

# Verify the data made it in
kubectl -n openbao exec openbao-0 -- env BAO_TOKEN="$ROOT" \
  bao kv get -format=json secret/home/hermes | jq '.data.data | keys'

# Force ESO to re-sync immediately (rather than waiting up to 1h)
kubectl -n hermes annotate externalsecret hermes-secrets force-sync=$(date +%s) --overwrite

# Restart the pod so it picks up the new env vars
kubectl -n hermes rollout restart deploy hermes-hermes-agent
```

### Hitting the API

```bash
API_KEY=$(cat /tmp/hermes-api/API_SERVER_KEY)

# LAN ingress (HTTPS, with -k because the cert is OpenBao-PKI-signed and
# clients without the OpenBao Root CA installed will warn).
curl -k -H "Authorization: Bearer $API_KEY" https://hermes.example.internal/health

# Or via port-forward straight to the pod (no auth header still required)
kubectl -n hermes port-forward svc/hermes-hermes-agent 8642:8642 &
curl -H "Authorization: Bearer $API_KEY" http://localhost:8642/health
```

### TUI access (interactive CLI)

The chart runs `hermes gateway run` (background daemon). To open the
interactive Hermes TUI inside the running pod:

```bash
kubectl -n hermes exec -it deploy/hermes-hermes-agent -- hermes
```

After this, the Hermes Deployment pod should pick up the env on next pod start
(or `kubectl -n hermes rollout restart deployment hermes-agent`).

## Access

- LAN-only Ingress: `https://hermes.example.internal/`
- Backed by Traefik internal LB (192.168.1.235)
- TLS issued by the OpenBao PKI ClusterIssuer
- No auth gating yet — LAN-only is the access boundary. Wrap behind
  oauth2-proxy via the `_authMiddleware` annotation in
  `composites/home/ingresses.cue` if Hermes ever needs to be public.

## State

- 50 GiB Longhorn PVC at `/opt/data` (HERMES_HOME) — single replica required;
  the chart enforces `replicaCount: 1` + `strategy.type: Recreate` when
  persistence is enabled.
- Conversation history, learned skills, FTS5 session DB all live here. Treat
  as durable single-writer state.
