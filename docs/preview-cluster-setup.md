# Preview Cluster Setup Guide

Step-by-step instructions to bootstrap the preview environment system from scratch.

## Prerequisites

| Requirement | Notes |
|---|---|
| Kubernetes cluster (1.28+) | Rancher, k3s, kind, or cloud-managed |
| `kubectl` configured | Cluster admin access |
| `cue` CLI v0.16.1 | `go install cuelang.org/go/cmd/cue@v0.16.1` |
| `cloudflared` CLI | `brew install cloudflared` |
| Cloudflare account | Zone for `example.com` |
| GitHub fine-grained PAT | Scopes: `contents:write`, `pull_requests:write`, `issues:write`, `admin:repo_hook` |
| Claude Max/Pro subscription | Run `claude login` locally to get OAuth credentials |
| Crossplane installed on cluster | With provider-kubernetes and provider-helm |

## Phase 1: Render and Apply Platform Resources

The fastest path is the end-to-end script, which handles every dependency
described below (apiserver tuning, Longhorn, metrics-server, CNPG,
Crossplane, render+apply, ArgoCD CI account):

```bash
./ci/scripts/bootstrap-preview.sh
```

The script is idempotent — re-runs skip phases that are already done. It
detects whether the cluster is Talos+Omni and behaves accordingly:

| Cluster type | Control-plane tuning | Pace between heavy installs |
|---|---|---|
| Talos + Omni | Auto-applies BOTH `400-apiserver-tuning-${OMNI_CLUSTER}` AND `400-etcd-tuning-${OMNI_CLUSTER}` ConfigPatches; waits for kube-apiserver static-pods to roll with new memory limit | Off (tuning gives apiserver + etcd enough headroom to handle the burst) |
| Anything else | Skipped — there is no machineconfig path | Auto-enabled (`BOOTSTRAP_PACE=slow`) — `wait_apiserver_calm` between phases instead |

**Addon detection.** The script renders CUE *before* installing the optional
Crossplane providers/functions and CNPG so the install reflects which XRDs the
cluster actually consumes (per `_xrdMap` pruning in `export/all.cue`):

| Detected from rendered manifests | Triggers install of |
|---|---|
| Any `XHarbor*` XRD or composition referencing `harbor.crossplane.io` | provider-harbor |
| Any composition pipeline referencing `crossplane-contrib-function-extra-resources` | function-extra-resources |
| Any database-shaped XRD (`XDatabase`, `XPostgres`, `XCNPG`) or manifest referencing `cnpg.io` | CloudNativePG operator |

Override per-run with `INSTALL_HARBOR=1`, `INSTALL_EXTRA_RES=1`,
`INSTALL_CNPG=1` (or `=0` to force-skip).

If you need to do the render manually instead:

```bash
# Validate all CUE schemas
make validate

# Render the preview cluster manifests
cue export ./export/ -t cluster=preview -e manifests --out yaml > preview-manifests.yaml

# Apply XRDs first, then Compositions, then composites
# (or use the flat manifests list which is already ordered)
kubectl apply -f preview-manifests.yaml
```

> **kube-apiserver tuning is mandatory before this step on any cluster size
> the Talos defaults target.** Without it, installing Crossplane (39 XRDs)
> + Argo CD (~20 CRDs) + Longhorn + CNPG simultaneously will OOMKill the
> apiserver and stall etcd writes (`etcdserver: request timed out`).
> See [`infrastructure/talos/README.md`](../infrastructure/talos/README.md)
> for both the auto-applied Talos+Omni path and the Omni-UI fallback. For
> non-Talos clusters, raise `kube-apiserver` memory limit to ≥ 4 GiB and
> set `--max-requests-inflight=1500` / `--max-mutating-requests-inflight=700`
> through whatever installer your distro uses, OR rely on
> `BOOTSTRAP_PACE=slow` to serialize the install.

This creates all namespaces, HelmReleases, NetworkPolicies, RBAC, etc. via Crossplane.

## Phase 2: Wait for Helm Releases

Crossplane's provider-helm will install the charts. Monitor progress:

```bash
# Watch HelmRelease status
kubectl get releases.helm.crossplane.io -w

# Check specific releases
kubectl get pods -n argo-events
kubectl get pods -n argocd
kubectl get pods -n traefik
kubectl get pods -n openbao
kubectl get pods -n cloudflared
kubectl get pods -n external-secrets
kubectl get pods -n kelos-system
```

Wait until all pods are Running before proceeding.

## Phase 3: Bootstrap OpenBao

The `openbao-bootstrap` Job runs automatically after OpenBao is ready. It:
1. Initializes OpenBao (single unseal key)
2. Stores the unseal key + root token in `openbao-keys` Secret
3. Unseals OpenBao
4. Enables KV v2 secrets engine at `secret/`
5. Enables kubernetes auth method
6. Creates `eso-preview-read` policy
7. Binds the `external-secrets` service account to that policy

Monitor the bootstrap:

```bash
# Watch the Job
kubectl get jobs -n openbao -w

# Check logs
kubectl logs -n openbao -l app.kubernetes.io/name=openbao-bootstrap -f

# Verify OpenBao is initialized and unsealed
kubectl exec -n openbao openbao-0 -- bao status
```

### Back up the unseal keys

**CRITICAL:** The `openbao-keys` Secret contains the only copy of the unseal key and root token. If this Secret is lost (e.g., namespace deletion, etcd failure), all secrets in OpenBao become permanently inaccessible.

```bash
# Save to a secure offline location
kubectl get secret openbao-keys -n openbao -o yaml > openbao-keys-backup.yaml

# Encrypt it (e.g., with age, gpg, or your org's key management)
age -r age1... openbao-keys-backup.yaml > openbao-keys-backup.yaml.age
rm openbao-keys-backup.yaml
```

### If OpenBao restarts (sealed state)

OpenBao seals itself on restart. The bootstrap Job handles auto-unseal on re-run, but if the Job has already completed (TTL expired), unseal manually:

```bash
UNSEAL_KEY=$(kubectl get secret openbao-keys -n openbao -o jsonpath='{.data.unseal-key}' | base64 -d)
kubectl exec -n openbao openbao-0 -- bao operator unseal "$UNSEAL_KEY"
```

## Phase 4: Seed Secrets in OpenBao

Port-forward to OpenBao and write all required secrets:

```bash
kubectl port-forward svc/openbao 8200:8200 -n openbao &

export BAO_ADDR=http://localhost:8200
export BAO_TOKEN=$(kubectl get secret openbao-keys -n openbao \
  -o jsonpath='{.data.root-token}' | base64 -d)
```

### 4a. Claude Code OAuth credentials (for AI agents)

The system uses your Claude Max/Pro subscription via OAuth — not per-token API
billing. This requires extracting the OAuth credentials from a machine where
you've already logged in with `claude`.

```bash
# On your LOCAL machine (not the cluster), log in to Claude Code if you haven't:
claude login

# The credentials file is at:
#   macOS/Linux: ~/.claude/.credentials.json
#   The file contains your OAuth access/refresh tokens.

# Store it in OpenBao:
bao kv put -mount=secret preview/claude-oauth-credentials \
  credentials.json=@"$HOME/.claude/.credentials.json"
```

**Security notes:**
- The OAuth token grants full access to your Claude account. Treat it like a password.
- The token has a refresh mechanism — Kelos agent pods will auto-refresh via the
  OAuth flow. If the token expires and refresh fails, re-run `claude login` locally
  and update OpenBao.
- Consider creating a dedicated Claude Max seat for CI/agent use rather than
  using your personal credentials.

### 4b. GitHub PAT

Used by: Argo CD ApplicationSet, Argo Events webhooks, Kelos agent git operations, Argo CD notifications.

Create a fine-grained PAT at https://github.com/settings/tokens with:
- Repository access: your-org/your-app
- Permissions: `contents:write`, `pull_requests:write`, `issues:write`, `admin:repo_hook`

```bash
bao kv put -mount=secret preview/github-pat \
  GITHUB_TOKEN="ghp_YOUR_GITHUB_PAT"
```

### 4c. GitHub webhook HMAC secret

Generate a random secret for webhook signature verification:

```bash
WEBHOOK_SECRET=$(openssl rand -hex 32)
bao kv put -mount=secret preview/github-webhook-secret \
  webhook-secret="$WEBHOOK_SECRET"

# Save this — you'll need it when configuring the GitHub webhook
echo "Webhook secret: $WEBHOOK_SECRET"
```

### 4d. Argo CD CI token

Generate an Argo CD API token for the Argo Events sync Jobs:

```bash
# Create a local Argo CD account for CI
kubectl -n argocd patch cm argocd-cm --type merge -p '{"data":{"accounts.ci":"apiKey"}}'

# Generate a token (requires argocd CLI or API)
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
argocd login localhost:8080 --username admin --password "$ARGOCD_PASSWORD" --insecure --grpc-web
ARGOCD_TOKEN=$(argocd account generate-token --account ci)

bao kv put -mount=secret preview/argocd-ci-token \
  token="$ARGOCD_TOKEN"
```

### 4e. GHCR pull credentials (container registry)

```bash
# Create a dockerconfigjson for GHCR
DOCKER_CONFIG=$(echo -n '{"auths":{"ghcr.io":{"auth":"'$(echo -n "YOUR_GITHUB_USERNAME:ghp_YOUR_PAT" | base64)'"}}}')

bao kv put -mount=secret preview/ghcr-credentials \
  dockerconfigjson="$DOCKER_CONFIG"
```

### 4f. Cloudflare tunnel credentials

Created in Phase 5 below — come back to this step after creating the tunnel.

### 4g. Shared app secrets (for preview environments)

These are env vars that every preview environment needs with the **same value**.
They are distributed automatically into every `preview-pr-{N}` namespace by the
`app-shared-secrets` ClusterExternalSecret.

```bash
# Auth — shared signing key for all previews
bao kv put -mount=secret preview/app/nextauth-secret \
  NEXTAUTH_SECRET="$(openssl rand -hex 32)"

# AI / LLM gateway
bao kv put -mount=secret preview/app/vercel-ai-gateway-url \
  VERCEL_AI_GATEWAY_URL="https://gateway.vercel.ai/v1"
bao kv put -mount=secret preview/app/vercel-ai-gateway-key \
  VERCEL_AI_GATEWAY_KEY="your-gateway-key"

# Email
bao kv put -mount=secret preview/app/sendgrid-api-key \
  SENDGRID_API_KEY="SG.your-test-key"

# Payments (use Stripe TEST keys, never production)
bao kv put -mount=secret preview/app/stripe-secret-key \
  STRIPE_SECRET_KEY="sk_test_..."
bao kv put -mount=secret preview/app/stripe-webhook-secret \
  STRIPE_WEBHOOK_SECRET="whsec_..."

# Per-preview Supabase JWT master key — HMAC seed that each preview
# chart's jwt-init Job uses to derive deterministic per-PR JWT secrets
# + anon/service-role JWTs. One key per cluster, rotate by overwriting
# this entry and re-running the jwt-init Job in every preview namespace.
bao kv put -mount=secret preview/app/supabase-jwt-master \
  JWT_MASTER_KEY="$(openssl rand -hex 32)"
```

**Adding new shared secrets later:**
1. Write the value to OpenBao at `preview/app/<key-name>`
2. Add a `data` entry in `composites/preview/clusterexternalsecrets.cue`
3. Re-render and apply: `make validate && cue export ./export/ ...`
4. ESO syncs the new key into all existing preview namespaces within 1h

**Per-preview secrets (DATABASE_URL, REDIS_URL, etc.):**
These are generated at deploy time by the preview Helm chart, not stored in
OpenBao. When you replace hello-world-app with your real chart, the templates
will construct them from the PR number:

```yaml
# deploy/preview/templates/app-deployment.yaml (in the app repo)
env:
  - name: DATABASE_URL
    value: "postgresql://app:$(DB_PASSWORD)@postgres-pr-{{ .Values.prNumber }}.preview-pr-{{ .Values.prNumber }}.svc:5432/app"
  - name: REDIS_URL
    value: "redis://redis.preview-pr-{{ .Values.prNumber }}.svc:6379/0"
  - name: NEXTAUTH_URL
    value: "https://{{ .Values.appSlug }}-pr-{{ .Values.prNumber }}.example.com"
    # Or in deep mode: "https://{{ .Values.appSlug }}-{{ .Values.prNumber }}.preview.example.com"
envFrom:
  - secretRef:
      name: app-shared-secrets  # ← all shared keys injected here
```

### Verify secrets are written

```bash
bao kv list -mount=secret preview/
# Expected: claude-oauth-credentials, github-pat, github-webhook-secret,
#           argocd-ci-token, ghcr-credentials, cloudflared-credentials

bao kv list -mount=secret preview/app/
# Expected: nextauth-secret, vercel-ai-gateway-url, vercel-ai-gateway-key,
#           sendgrid-api-key, stripe-secret-key, stripe-webhook-secret
```

## Phase 5: Create Cloudflare Tunnel

### 5a. Authenticate cloudflared

```bash
cloudflared tunnel login
# Opens browser — authorize for the example.com zone
```

### 5b. Create the tunnel

```bash
cloudflared tunnel create preview
# Output: Created tunnel preview with id xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
# Credentials file written to: ~/.cloudflared/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.json
```

### 5c. Store tunnel credentials in OpenBao

```bash
TUNNEL_ID=$(cloudflared tunnel list -o json | jq -r '.[] | select(.name=="preview") | .id')
CREDS_FILE="$HOME/.cloudflared/${TUNNEL_ID}.json"

bao kv put -mount=secret preview/cloudflared-credentials \
  credentials.json=@"$CREDS_FILE"
```

### 5d. Create DNS records

In **flat hostname mode** (default — `{slug}-pr-{number}.example.com`),
each preview app's Ingress with `ingressClassName: cloudflare-tunnel` is
registered individually in the tunnel by the strrl controller, and a
matching DNS record is auto-provisioned. You only need a manual route for
the Argo Events webhook host:

```bash
cloudflared tunnel route dns preview "events.example.com"
```

In **deep hostname mode** (`{slug}-{number}.preview.example.com`,
requires Cloudflare ACM ~$10/mo), you additionally need a wildcard route
+ DNS record so Cloudflare can answer arbitrary subdomains under
`preview.example.com`:

```bash
# Only run this in deep mode (after ACM is enabled for *.preview.example.com)
cloudflared tunnel route dns preview "*.preview.example.com"
```

### 5e. Verify DNS propagation

```bash
dig +short CNAME events.example.com
# Expected: <tunnel-id>.cfargotunnel.com.

# In deep mode only:
dig +short CNAME "*.preview.example.com"
# Expected: <tunnel-id>.cfargotunnel.com.
```

### 5f. Cloudflare edge TLS — required reading

Cloudflare's free Universal SSL covers `example.com` and `*.example.com`
(a single wildcard level under the apex). It does **not** cover multi-level
wildcards like `*.preview.example.com`.

- **Flat mode** (default): hostnames like `salessage-pr-179.example.com`
  are covered automatically by Universal SSL. Nothing to do.
- **Deep mode**: requires Cloudflare Advanced Certificate Manager (~$10/mo).
  In the Cloudflare dashboard go to SSL/TLS → Edge Certificates → Order
  Advanced Certificate, list hostnames `preview.example.com` and
  `*.preview.example.com`, then flip `_previewHostnameMode` in
  `composites/home/argocd.cue` to `"deep"`, re-render, re-apply.

Confirmation probe (any browser-load that ends in `ERR_SSL_VERSION_OR_CIPHER_MISMATCH`
or `handshake_failure` from openssl means the edge has no cert for that hostname):

```bash
curl -ksI --max-time 6 https://<hostname>/ -o /dev/null \
  -w "HTTP %{http_code} | err: %{errormsg}\n"
```

## Phase 6: Verify External Secrets Sync

After seeding OpenBao, ESO should sync secrets into their target namespaces. Force immediate sync by restarting ESO:

```bash
kubectl rollout restart deployment -n external-secrets external-secrets

# Check ExternalSecret status
kubectl get externalsecrets -A
# All should show STATUS: SecretSynced

# Check ClusterExternalSecret
kubectl get clusterexternalsecrets
# ghcr-pull-secret should show SecretSynced

# Verify specific secrets exist
kubectl get secret cloudflared-tunnel-credentials -n cloudflared
kubectl get secret github-webhook-secret -n argo-events
kubectl get secret argocd-ci-token -n argo-events
kubectl get secret github-token -n argocd
kubectl get secret argocd-notifications-secret -n argocd
kubectl get secret github-pat -n kelos-system
kubectl get secret claude-oauth-credentials -n kelos-system
```

If any show `SecretSyncedError`, check:

```bash
kubectl describe externalsecret <name> -n <namespace>
# Look at Events and Status.Conditions for error details

# Common issues:
# - ClusterSecretStore not ready → OpenBao sealed or auth not configured
# - Secret not found in OpenBao → path typo or secret not written yet
# - Permission denied → ESO role policy too narrow
```

## Phase 7: Configure GitHub Webhook

Register the webhook so GitHub sends PR events to Argo Events:

1. Go to https://github.com/your-org/your-app/settings/hooks
2. Click "Add webhook"
3. Settings:
   - **Payload URL:** `https://events.example.com/github/pr`
   - **Content type:** `application/json`
   - **Secret:** (the webhook secret from Phase 4c)
   - **Events:** Select individual events:
     - Pull requests
     - Issue comments
     - Statuses
4. Click "Add webhook"

Verify it works:

```bash
# Check the webhook delivery in GitHub (Recent Deliveries tab)
# Should show 2xx response

# Check Argo Events EventSource logs
kubectl logs -n argo-events -l eventsource-name=github-webhook --tail=20
```

## Phase 8: Smoke Test

### Test 1: Preview environment creation

1. Create a test PR on your-org/your-app with the label `preview`
2. Watch the ApplicationSet create an Application:
   ```bash
   kubectl get applications -n argocd -w
   ```
3. Check the preview namespace:
   ```bash
   kubectl get pods -n preview-<SLUG>-<NUMBER>
   ```
4. Visit `https://<SLUG>-pr-<NUMBER>.example.com` (flat mode, default)
   or `https://<SLUG>-<NUMBER>.preview.example.com` (deep mode, ACM only)

### Test 2: AI agent pipeline

1. Add the `ai-review` label to the PR
2. Watch the plan-create TaskSpawner trigger:
   ```bash
   kubectl get tasks -n kelos-system -w
   ```
3. Check the PR for the "Implementation Plan" comment
4. Watch reviewers spawn:
   ```bash
   kubectl get tasks -n kelos-system -w
   ```
5. After all reviews pass, check for "Plan approved" comment
6. Watch the fixer agent implement:
   ```bash
   kelos logs <task-name> -f
   ```

### Test 3: On-demand agent

1. Comment `@agent review` on the PR
2. Watch for the dev-reviewer Task
3. Check the PR for the structured code review comment

### Test 4: Fix request

1. Comment `@agent fix investigate the preview and check for issues`
2. Watch the planner create a plan
3. Watch reviewers approve
4. Watch the fixer implement

## Troubleshooting

### OpenBao sealed after pod restart

```bash
UNSEAL_KEY=$(kubectl get secret openbao-keys -n openbao -o jsonpath='{.data.unseal-key}' | base64 -d)
kubectl exec -n openbao openbao-0 -- bao operator unseal "$UNSEAL_KEY"
```

### ExternalSecrets stuck in error state

```bash
# Check ClusterSecretStore health
kubectl get clustersecretstores openbao-backend -o yaml

# If NotReady, OpenBao is likely sealed or auth is misconfigured
# Re-run the bootstrap Job:
kubectl delete job openbao-bootstrap -n openbao
# Crossplane will recreate it
```

### Cloudflared tunnel not connecting

```bash
kubectl logs -n cloudflared -l app.kubernetes.io/name=cloudflared --tail=50

# Common issues:
# - "failed to connect" → credentials.json wrong or expired
# - "no such host" → DNS not propagated yet
# - tunnel not found → tunnel was deleted in Cloudflare dashboard
```

### Argo Events not receiving webhooks

```bash
# Check EventSource pods are running
kubectl get pods -n argo-events

# Check EventSource logs for webhook hits
kubectl logs -n argo-events -l eventsource-name=github-webhook --tail=50

# Verify NetworkPolicy allows cloudflared → argo-events:12000/13000
kubectl get networkpolicies -n argo-events -o yaml
```

### Kelos agent stuck or failing

```bash
# List all tasks
kubectl get tasks -n kelos-system

# Stream agent logs
kelos logs <task-name> -f

# Kill a stuck agent
kubectl delete task <task-name> -n kelos-system

# Emergency: suspend all agents
kelos suspend taskspawner --all
```

### Preview namespace not cleaning up

```bash
# Check if Argo CD Application still exists
kubectl get applications -n argocd -l pr-number=<N>

# If Application exists but PR is closed, check ApplicationSet controller
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller --tail=50

# Manual cleanup
kubectl delete namespace preview-pr-<N>
```

## Credential Rotation

| Credential | How to Rotate |
|---|---|
| Claude OAuth token | Run `claude login` locally, then `bao kv put -mount=secret preview/claude-oauth-credentials credentials.json=@~/.claude/.credentials.json` → ESO auto-syncs within 1h |
| GitHub PAT | `bao kv put -mount=secret preview/github-pat GITHUB_TOKEN="ghp_NEW"` → ESO auto-syncs; restart ApplicationSet controller |
| GitHub webhook secret | Update in OpenBao AND in GitHub webhook settings simultaneously |
| Argo CD CI token | Regenerate via `argocd account generate-token --account ci`, update in OpenBao |
| Cloudflare tunnel | `cloudflared tunnel delete preview && cloudflared tunnel create preview`, update creds in OpenBao, recreate DNS routes |
| OpenBao unseal key | Cannot be rotated — requires full re-init (data loss). Back up the key. |
