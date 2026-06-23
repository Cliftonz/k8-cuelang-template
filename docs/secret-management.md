# Secret Management

How secrets flow through this platform, who can add them, and how to ask
an AI agent to wire a new one end-to-end.

---

## Mental model

> **Declarative shape lives in this repo. Values live only in OpenBao.**

A secret on this platform has two halves:

1. **Wiring** (PR-reviewable, in CUE): which path, which fields, which
   namespace/Secret it lands in, who consumes it. Lives in
   [composites/preview/externalsecrets.cue](../composites/preview/externalsecrets.cue)
   or [composites/preview/clusterexternalsecrets.cue](../composites/preview/clusterexternalsecrets.cue),
   plus this registry doc.
2. **Value** (not in git): the actual token / password / JSON blob.
   Stored in OpenBao at the path the wiring references. Sync into the
   cluster is automatic via External Secrets Operator (ESO) within 1h.

A team member proposing a new secret writes the wiring (PR). A
cluster admin (today: Admin) writes the value (one-line `bao kv put`).
Code review never sees the value.

---

## Components

| Piece | Role |
|---|---|
| **OpenBao** | KV v2 store at `secret/preview/...`. Source of truth for values. |
| **External Secrets Operator (ESO)** | Watches `ExternalSecret` / `ClusterExternalSecret` CRs and syncs values from OpenBao into Kubernetes Secrets in target namespaces. |
| **`XExternalSecret` / `XClusterExternalSecret` XRDs** | Crossplane wrappers our composites author. Render to ESO CRs at apply time. |
| **OpenBao auth** | How a human (or service) gets to write values. Today: root token. Tomorrow: Google OIDC. |

---

## Today's auth (solo, root-token-only)

Only path to write OpenBao values:

```bash
kubectl port-forward -n openbao svc/openbao 8200:8200 &
export BAO_ADDR=http://localhost:8200
export BAO_TOKEN=$(kubectl get secret openbao-keys -n openbao -o jsonpath='{.data.root-token}' | base64 -d)

bao kv put -mount=secret <path> <field>=<value>
```

Reading the root token requires cluster-admin Kubernetes access. Do not
share. When team grows past 1, switch to OIDC (next section).

---

## Future auth — Google OIDC (recommended for ≥2 people)

Setup is one-time, ~30 min, requires Google Workspace admin:

1. Google Cloud Console → APIs & Services → Credentials → Create OAuth
   2.0 Client ID (Web application). Authorized redirect URI:
   `http://localhost:8250/oidc/callback` plus
   `https://openbao.preview.example.internal/ui/vault/auth/oidc/oidc/callback`.
   Save the Client ID + Client Secret.
2. On the cluster, enable + configure OpenBao OIDC:
   ```bash
   bao auth enable oidc
   bao write auth/oidc/config \
     oidc_discovery_url="https://accounts.google.com" \
     oidc_client_id="<id>" \
     oidc_client_secret="<secret>" \
     default_role="workspace"

   bao policy write preview-admin - <<EOF
   path "secret/data/preview/*"      { capabilities = ["create","read","update","delete","list"] }
   path "secret/metadata/preview/*"  { capabilities = ["list","read","delete"] }
   path "secret/data/preview/app/*"  { capabilities = ["create","read","update","delete","list"] }
   path "secret/metadata/preview/app/*" { capabilities = ["list","read","delete"] }
   EOF

   bao write auth/oidc/role/workspace \
     bound_audiences="<client-id>" \
     allowed_redirect_uris="http://localhost:8250/oidc/callback,https://openbao.preview.example.internal/ui/vault/auth/oidc/oidc/callback" \
     user_claim="email" \
     bound_claims='{"hd":"<your-google-workspace-domain>"}' \
     policies="preview-admin" \
     oidc_scopes="openid,email,profile" \
     ttl=8h
   ```
3. Each team member then:
   ```bash
   bao login -method=oidc role=workspace
   # browser opens → Google sign-in → done. Token good for 8h.
   ```

After this, root token is stashed offline (encrypted backup) and
day-to-day writes happen via the team member's own OIDC session.

---

## The secret registry

Every OpenBao path used by this platform must be listed below. New
secrets land via PR that updates this table at the same time it adds
the ExternalSecret CUE entry.

| Path | Fields | Consumed by | How to obtain | Rotate when |
|---|---|---|---|---|
| `preview/github-pat` | `GITHUB_USER`, `GITHUB_TOKEN` | argocd ApplicationSet, argo-events sensors, ghcr-pull-secret template, argocd-notifications GitHub webhook | github.com/settings/tokens (fine-grained PAT, scopes: `contents:write`, `pull_requests:write`, `issues:write`, `admin:repo_hook`, `packages:read`, repo access = example-org) | yearly, on team member offboarding, or on suspected compromise |
| `preview/github-webhook-secret` | `webhook-secret` | argo-events github EventSource HMAC validation (currently unverified — see TODO in argoevents.cue), GitHub org webhook config | `openssl rand -hex 32`, save once | rare; only if leaked |
| `preview/argocd-ci-token` | `token` | argo-events sync Job → Argo CD API | `argocd account generate-token --account ci` (after `argocd login`) | yearly |
| `preview/cloudflare-tunnel` | `account_id`, `tunnel_name`, `api_token` | STRRL cloudflare-tunnel-ingress-controller | Cloudflare dash → My Profile → API Tokens, scopes: Zone:Zone:Read + Zone:DNS:Edit + Account:Cloudflare Tunnel:Edit | yearly |
| `preview/discord-webhook-url` | `url` | argocd-notifications on-ai-outage trigger | Discord server → Settings → Integrations → Webhooks → New Webhook | rare |
| `preview/claude-oauth-credentials` | `credentials.json`, `CLAUDE_CODE_OAUTH_TOKEN` | Kelos agent Tasks (CLAUDE_CODE_OAUTH_TOKEN env var) | local `~/.claude/.credentials.json` after `claude login`; extract token via `jq -r '.claudeAiOauth.accessToken'` | every ~30 days (Claude OAuth expiry) |
| `preview/unifi` | `host`, `api_key`, `external` | external-dns-unifi-webhook (when `UNIFI=true` flag is set) | UniFi Network → Settings → Admins → Add Admin (API Key only) | yearly |
| `preview/app/nextauth-secret` | `NEXTAUTH_SECRET` | every preview app via app-shared-secrets ClusterExternalSecret | `openssl rand -hex 32` | rare |
| `preview/app/vercel-ai-gateway-key` | `VERCEL_AI_GATEWAY_KEY` | every preview app | Vercel dashboard → AI Gateway → API Keys | per Vercel team policy |
| `preview/app/stripe-secret-key` | `STRIPE_SECRET_KEY` | every preview app | Stripe dash → Developers → API keys (TEST mode only — never live) | per Stripe rotation |
| `preview/app/stripe-webhook-secret` | `STRIPE_WEBHOOK_SECRET` | every preview app | Stripe dash → Developers → Webhooks → Signing secret | per Stripe rotation |

Add new rows as you add new secrets. Keep alphabetical within each
section if you care.

---

## Adding a new secret — manual workflow

End-to-end for a brand new secret. Example: adding a Postmark API key
for transactional email.

### 1. Decide the OpenBao path + field names

Convention:
- Cluster-shared: `preview/<short-name>` (single component)
- Per-app shared (synced to every preview namespace): `preview/app/<short-name>`
- Per-environment in the future: `preview/<env>/...`

Field names match the env var name the consumer expects, uppercase
snake_case. For multi-field paths, group related fields under one path
(see `preview/github-pat` with `GITHUB_USER` + `GITHUB_TOKEN`).

For Postmark: path `preview/app/postmark-api-key`, field `POSTMARK_API_KEY`.

### 2. Open a PR that does these three things atomically

**a. Add a row to this registry** so future humans know it exists.

**b. Add the ExternalSecret CUE entry.** Per-namespace goes in
[composites/preview/externalsecrets.cue](../composites/preview/externalsecrets.cue);
shared-into-all-previews goes in
[composites/preview/clusterexternalsecrets.cue](../composites/preview/clusterexternalsecrets.cue).

For our Postmark example, append to the `app-shared-secrets` data
block in `clusterexternalsecrets.cue`:

```cue
{secretKey: "POSTMARK_API_KEY", remoteRef: {key: "preview/app/postmark-api-key", property: "POSTMARK_API_KEY"}},
```

**c. Wire the consumer** to read it. If the preview app's chart already
mounts `app-shared-secrets` via `envFrom: secretRef`, the new env var
appears automatically. If it's a one-off pod, edit the relevant CUE
or Helm values to add the env mapping.

### 3. After PR merges

A cluster admin seeds the value:

```bash
bao kv put -mount=secret preview/app/postmark-api-key \
  POSTMARK_API_KEY="<paste from postmarkapp.com>"
```

ESO picks it up within 5 min (default `refreshInterval: 5m`). To force
immediate sync without waiting, bump the `force-sync` annotation on the
target ExternalSecret — surgical and triggers reconcile within seconds:

```bash
kubectl annotate externalsecret <name> -n <ns> \
  force-sync="$(date +%s)" --overwrite
```

(For per-app-shared secrets the target is the `ClusterExternalSecret`
named `app-shared-secrets` in argocd; same annotation works.)

### 4. Verify

```bash
kubectl get externalsecret -A | grep postmark
# Status should be SecretSynced=True
```

---

## SaaS credentials with no local emulation

Stripe live mode, OAuth client secrets, third-party API keys — same
exact path as above for the **cluster** side. The "no local emulation"
constraint only affects developer machines (each dev needs the value
in their `.env.local` to run the app outside the cluster). That's a
**developer secret distribution** problem, not a cluster secret
problem. Options for that:

| Approach | When to use |
|---|---|
| Use a vendor's sandbox / test mode | preferred — Stripe test, SendGrid sandbox, etc. |
| Per-dev account on the SaaS | when sandbox isn't enough; each dev gets their own creds |
| Shared 1Password / Bitwarden vault, devs `op read` into `.env.local` | last resort; everyone shares one set of creds |
| `bao kv get` in a dev script that talks to OpenBao via OIDC | only after Google OIDC is set up |

The cluster never sees `.env.local`. The local dev never has cluster
admin. Two parallel stores, two parallel rotation stories.

---

## How to ask an AI agent to add a secret end-to-end

The whole workflow above is mechanical and pattern-driven, which makes
it ideal for AI delegation. Drop this prompt into Claude Code, an MCP
agent, or a Kelos TaskSpawner and it will produce the PR for you.

### Prompt template

````markdown
You are adding a new secret to the k8-infra preview platform. Repo root
is the working directory. Follow docs/secret-management.md exactly.

Inputs:
  SECRET_NAME: <short-name, e.g. postmark-api-key>
  SCOPE: <"cluster-shared" | "per-app-shared" | "per-namespace:<ns>">
  FIELDS: <comma-separated UPPER_SNAKE field names, e.g. POSTMARK_API_KEY>
  CONSUMER: <which workload reads it, e.g. "preview app via app-shared-secrets">
  HOW_TO_OBTAIN: <one line, e.g. "postmarkapp.com → API Tokens">
  ROTATE_WHEN: <one line, e.g. "per Postmark policy">

Do these things in a single PR:

1. Add a row to the registry table in docs/secret-management.md. Place
   it alphabetically within its section. Use the exact path convention:
     - cluster-shared    → secret/preview/<SECRET_NAME>
     - per-app-shared    → secret/preview/app/<SECRET_NAME>
     - per-namespace:<n> → secret/preview/<SECRET_NAME>  (with namespace noted)

2. Add the ExternalSecret CUE entry:
     - per-namespace:<n>  → composites/preview/externalsecrets.cue, new entry
                            in the existing list, namespace=<n>
     - cluster-shared     → composites/preview/externalsecrets.cue, new entry
                            in the existing list, namespace=<the one consumer ns>
     - per-app-shared     → composites/preview/clusterexternalsecrets.cue,
                            extend the data: [...] block of the
                            "app-shared-secrets" entry

   Always include `property: "<FIELD_NAME>"` on every remoteRef so ESO
   extracts the field instead of the whole JSON.

3. Run `make validate` and confirm no CUE errors.

4. Run `make export-cluster CLUSTER=preview UNIFI=true` and confirm
   the rendered manifest under clusters/preview/ contains the new
   ExternalSecret with the correct path and property fields.

5. Open a PR titled "secrets: add <SECRET_NAME> for <CONSUMER>". In
   the PR body, paste the exact `bao kv put` command the cluster admin
   needs to run to seed the value, with field placeholders only — no
   actual secret values:

     bao kv put -mount=secret preview/<path> \
       <FIELD>="<paste-value-here>"

6. Do NOT commit any actual secret values. Do NOT commit the rendered
   clusters/preview/ output unless the repo's CI requires it (check
   .gitignore — clusters/ is normally ignored).

After the PR is merged, the cluster admin (today: Admin) runs the
bao kv put command from the PR body. ESO syncs within 1h.
````

### Step-by-step the AI must follow

Drop these instructions into a system prompt or a Kelos AgentConfig.
The AI executes them in order; each step has an explicit success
criterion before moving on.

1. **Validate inputs.** Confirm `SECRET_NAME` matches `^[a-z][a-z0-9-]*$`,
   `SCOPE` is one of the three allowed values, `FIELDS` is a non-empty
   comma-separated list of UPPER_SNAKE_CASE identifiers. If any input
   is malformed, refuse and ask for correction. **Stop if invalid.**

2. **Resolve the OpenBao path.**
   - `cluster-shared`    → `secret/preview/<SECRET_NAME>`
   - `per-app-shared`    → `secret/preview/app/<SECRET_NAME>`
   - `per-namespace:<n>` → `secret/preview/<SECRET_NAME>` (with namespace)

   Record the resulting path string for use in steps 4 and 7.

3. **Read the registry section** of `docs/secret-management.md`. Locate
   the table under "## The secret registry". Determine the alphabetical
   insertion point for the new row.

4. **Edit `docs/secret-management.md`** — insert one new row at the
   identified spot:

   ```
   | `<path-from-step-2>` | `<FIELDS>` | <CONSUMER> | <HOW_TO_OBTAIN> | <ROTATE_WHEN> |
   ```

   Use the literal pipe-separated format. Backtick the path and field
   names. **Success: the file diff shows exactly one added row.**

5. **Determine the CUE file to edit.**
   - `per-namespace:<n>` → `composites/preview/externalsecrets.cue`,
     append a new entry to the top-level `externalSecrets: [...]` list
   - `cluster-shared`    → `composites/preview/externalsecrets.cue`,
     append a new entry, set `namespace:` to the consumer namespace
   - `per-app-shared`    → `composites/preview/clusterexternalsecrets.cue`,
     extend the `data: [...]` block of the entry whose
     `name: "app-shared-secrets"`

6. **Write the CUE entry.** For per-namespace and cluster-shared, copy
   this template, replacing the bracketed values:

   ```cue
   {
       name:            "<secret-name-as-k8s-secret>"
       namespace:       "<target-namespace>"
       secretStoreRef:  "openbao-backend"
       refreshInterval: "1h"
       tier:            C.tier
       cluster:         C.name
       owner:           "platform-team"
       data: [
           {secretKey: "<FIELD_1>", remoteRef: {key: "<openbao-path>", property: "<FIELD_1>"}},
           // one entry per FIELD
       ]
   },
   ```

   For per-app-shared, copy this single line per field into the
   existing `app-shared-secrets` data block:

   ```cue
   {secretKey: "<FIELD>", remoteRef: {key: "<openbao-path>", property: "<FIELD>"}},
   ```

   **Always include `property:`** on every remoteRef. Skipping it makes
   ESO write the whole JSON blob into the secret instead of the field.
   **Success: file diff shows the new entry, no other entries modified.**

7. **Validate CUE.** Run `make validate`. If it errors, read the error,
   fix the CUE syntax, re-run. **Stop and ask for help if you cannot
   produce a clean `cue vet`.**

8. **Render the cluster.** Run `make export-cluster CLUSTER=preview UNIFI=true`.
   Confirm the rendered manifest contains the new ExternalSecret:

   ```bash
   grep -l "<openbao-path>" clusters/preview/
   ```

   The grep must return at least one file. **Success: at least one
   match. Stop if grep is empty — the wiring did not flow through.**

9. **Check the gitignore.** If `clusters/` is listed in `.gitignore`,
   do NOT commit the rendered output. If it is tracked, include the
   regenerated files in the PR. Verify with:

   ```bash
   git check-ignore clusters/preview/dummy 2>/dev/null && echo IGNORED || echo TRACKED
   ```

10. **Commit + open PR.** Title: `secrets: add <SECRET_NAME> for <CONSUMER>`.
    Body must include this exact block, with `<paste-value-here>`
    untouched (the cluster admin fills it):

    ```
    ## Wiring
    Path: `<openbao-path>`
    Fields: `<FIELDS>`
    Consumer: <CONSUMER>

    ## Seed command (cluster admin runs after merge)
    ```bash
    kubectl port-forward -n openbao svc/openbao 8200:8200 &
    export BAO_ADDR=http://localhost:8200
    export BAO_TOKEN=$(kubectl get secret openbao-keys -n openbao -o jsonpath='{.data.root-token}' | base64 -d)

    bao kv put -mount=secret <openbao-path> \
      <FIELD_1>="<paste-value-here>" \
      [additional fields...]
    ```

    ## Force-sync ESO so the value lands immediately
    ```bash
    kubectl annotate externalsecret <secret-name> -n <target-ns> \
      force-sync="$(date +%s)" --overwrite
    ```

    ## Verify after seed
    ```bash
    kubectl get externalsecret -A | grep <secret-name>
    # expect SecretSynced=True
    kubectl get secret <secret-name> -n <target-ns> -o jsonpath='{.data}' | jq
    # confirm fields are present and non-empty
    ```
    ```

11. **Stop.** Do not run the seed command. Do not push the value.
    Do not modify any other files in the repo. Hand off to the human.

### Worked example

Input:
```
SECRET_NAME: postmark-api-key
SCOPE: per-app-shared
FIELDS: POSTMARK_API_KEY
CONSUMER: every preview app via app-shared-secrets ClusterExternalSecret
HOW_TO_OBTAIN: postmarkapp.com → API Tokens → Server API token
ROTATE_WHEN: per Postmark policy
```

AI produces:

- New row in the registry table:
  `| \`preview/app/postmark-api-key\` | \`POSTMARK_API_KEY\` | every preview app via app-shared-secrets | postmarkapp.com → API Tokens → Server API token | per Postmark policy |`

- One added line in `composites/preview/clusterexternalsecrets.cue`,
  inside the `app-shared-secrets` data block:
  ```cue
  {secretKey: "POSTMARK_API_KEY", remoteRef: {key: "preview/app/postmark-api-key", property: "POSTMARK_API_KEY"}},
  ```

- `make validate` passes; `make export-cluster CLUSTER=preview UNIFI=true`
  shows `POSTMARK_API_KEY` in `clusters/preview/xclusterexternalsecret-app-shared-secrets.yaml`.

- PR opened with the seed command in the body, value placeholder.

That's the whole job. ~30 lines of diff, fully reviewable, zero
secrets in the repo.

### As a Kelos AgentConfig (long-running automation)

For unattended runs (e.g. an issue-triggered TaskSpawner where someone
files `request: secret <name>` issues), use this AgentConfig:

```yaml
apiVersion: kelos.dev/v1alpha1
kind: AgentConfig
metadata:
  name: secret-wiring
  namespace: kelos-system
spec:
  agentsMD: |
    You are the secret-wiring agent for the k8-infra preview platform.

    Read docs/secret-management.md fully. Follow the "Step-by-step the
    AI must follow" section literally. Each step has an explicit
    success criterion; do not skip ahead.

    You are NOT authorized to seed values, push directly to main, or
    modify files outside the ones listed in the steps. Open a PR and
    stop.
  plugins: []
  mcpServers: {}
```

Then a TaskSpawner watching a "secret-request" issue label can spawn
this agent against any incoming request.

### Why this works

Every step has a deterministic pattern in this repo:
- Path naming: 3 fixed shapes
- ExternalSecret entry: 6 fields, one of them always set
- Render verification: `make` is the source of truth
- PR body holds the seed command so the human handoff is one copy/paste

The AI doesn't need access to OpenBao or the value itself — it only
authors the wiring. Any secret an AI proposes can be reviewed in the
PR; nothing is leaked.

### What the AI cannot do (and shouldn't)

- Seed the value. That requires `bao kv put`, which requires either the
  root token (cluster admin) or an OIDC login (a real human in
  Workspace). Neither should be available to an unattended agent.
- Bypass the registry doc. If a secret isn't in the table, no one will
  remember it exists. AI must always update both the CUE and the doc
  in the same PR.
- Decide rotation cadence. Document what the vendor says; humans set
  policy.
- Commit rendered output unless `.gitignore` says otherwise. The CUE
  source is canonical; rendered YAML is a byproduct.

---

## Claude OAuth rotation + smoke test

Claude Code OAuth tokens expire every ~30 days. The `kelos-oauth-watchdog`
CronJob posts to Discord when expiry is within 5 days. When alerted:

### 1. Re-seed from macOS Keychain

```bash
# Refresh local Keychain first (opens browser)
claude login

# Extract token + expiry
RAW=$(security find-generic-password -s "Claude Code-credentials" -w)
TOKEN=$(echo "$RAW" | jq -r '.claudeAiOauth.accessToken')
EXPIRES=$(echo "$RAW" | jq -r '.claudeAiOauth.expiresAt')
[ -z "$TOKEN" ] || [ "$TOKEN" = "null" ] && { echo "no token — re-run claude login"; exit 1; }

# Port-forward OpenBao + seed
kubectl port-forward -n openbao svc/openbao 8200:8200 >/dev/null 2>&1 &
sleep 3
export BAO_ADDR=http://localhost:8200
export BAO_TOKEN=$(kubectl get secret openbao-keys -n openbao -o jsonpath='{.data.root-token}' | base64 -d)

bao kv put -mount=secret preview/claude-oauth-credentials \
  CLAUDE_CODE_OAUTH_TOKEN="$TOKEN" \
  EXPIRES_AT_MS="$EXPIRES"

# Force ESO sync
kubectl annotate externalsecret claude-code-oauth -n kelos-system \
  force-sync="$(date +%s)" --overwrite
```

### 2. Verify Secret synced

```bash
# Token value (should start with sk-ant-oat01-...)
kubectl get secret claude-code-oauth -n kelos-system \
  -o jsonpath='{.data.CLAUDE_CODE_OAUTH_TOKEN}' | base64 -d | head -c 25; echo

# Expiry annotation (should be ~30 days out)
EXPIRES=$(kubectl get secret claude-code-oauth -n kelos-system \
  -o jsonpath='{.metadata.annotations.kelos\.dev/oauth-expires-at}')
python3 -c "import datetime; print(datetime.datetime.fromtimestamp($EXPIRES/1000))"
```

### 3. Smoke test — spawn a real Task

Proves the agent can actually authenticate end-to-end, not just that
the Secret exists.

```bash
cat <<'EOF' | kubectl create -f -
apiVersion: kelos.dev/v1alpha1
kind: Task
metadata:
  generateName: oauth-smoketest-
  namespace: kelos-system
spec:
  type: claude-code
  credentials:
    type: oauth
    secretRef:
      name: claude-code-oauth
  prompt: "Print the single word OK and stop. No other output."
  ttlSecondsAfterFinished: 60
EOF

# Watch it run
kubectl get task -n kelos-system -w | grep oauth-smoketest
```

Expect: `Pending` → `Running` → `Succeeded` in ~30-60s. NOT `Failed`
with `401` / `Unauthorized` / `invalid_token` in `.status.message`.

Check agent logs if needed:
```bash
TASK=$(kubectl get task -n kelos-system -o name | grep oauth-smoketest | tail -1)
kubectl logs -n kelos-system -l "kelos.dev/task=$(basename $TASK)" -c agent
```

TTL 60s auto-cleans the Task.

---

## Failure modes + recovery

| Symptom | Likely cause | Fix |
|---|---|---|
| `kubectl get externalsecret` shows `SecretSyncedError` | Secret not yet seeded in OpenBao at expected path/field | Verify with `bao kv get`; re-seed if missing |
| Secret value is empty / `null` after sync | `property:` field name mismatch (case-sensitive) | Compare ESO entry `property:` with `bao kv get` output, fix one side |
| `kubectl get clustersecretstores openbao-backend` shows NotReady | OpenBao sealed or auth misconfigured | `kubectl exec -n openbao openbao-0 -- bao status` — if sealed, re-unseal |
| Token works but app still fails auth | Pods cached old Secret value | `kubectl rollout restart deployment <name> -n <ns>` |
| Lost root token AND no OIDC | Truly recoverable only via OpenBao re-init = data loss | Back up `openbao-keys` Secret offline; set up OIDC before this happens |

---

## Related

- Wiring lives in: [composites/preview/externalsecrets.cue](../composites/preview/externalsecrets.cue), [composites/preview/clusterexternalsecrets.cue](../composites/preview/clusterexternalsecrets.cue)
- ESO operator: [HelmRelease in helmreleases.cue](../composites/preview/helmreleases.cue)
- ClusterSecretStore: [composites/preview/clustersecretstores.cue](../composites/preview/clustersecretstores.cue) (assumes one named `openbao-backend`)
- Cluster setup walks the OpenBao bootstrap path: [docs/preview-cluster-setup.md](preview-cluster-setup.md)
