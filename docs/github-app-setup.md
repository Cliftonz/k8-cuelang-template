# GitHub App Setup — Example Org AI

This document walks through registering, configuring, and wiring up
the **Example Org AI** GitHub App. The App replaces the existing PAT
(`github-pat`) authentication for the AI review pipeline so that agents
can write GitHub Check Runs (which the PR header surfaces as native
status indicators).

## Why a GitHub App and not a PAT

The Check Runs API requires `checks: write` permission. Per GitHub's
documented restriction, **only GitHub Apps can create check runs** —
classic and fine-grained PATs receive 403 on `POST /repos/{O/R}/check-runs`.
Without check runs, the panel's progress can't show in the PR header
(only as comments). Other secondary benefits:

- Per-repo install scope (App can be installed/uninstalled per repo or
  org-wide without rotating a PAT)
- Short-lived installation tokens (1 hour) reduce blast radius vs. a
  long-lived PAT
- Native webhook delivery without managing a separate webhook resource

## Phase 1 — Register the App

Open https://github.com/organizations/example-org/settings/apps/new
(must be on org-level settings; personal-account Apps can be installed
on the org but org-level keeps ownership with `example-org`).

### Field values

| Field | Value | Notes |
|---|---|---|
| GitHub App name | `Example Org AI` | Must be globally unique on github.com. If taken, append a suffix. |
| Description | "Internal AI review and implementation pipeline" | Free text, shown to repo admins |
| Homepage URL | `https://github.com/example-org` | Required field; anything resolvable works |
| Identifying and authorizing users | Skip the "Callback URL" / OAuth fields | We're not doing user-facing OAuth, only server-to-server |
| Post installation → Setup URL | leave blank | |
| Webhook → Active | ✓ checked | |
| Webhook URL | `https://events.example.com/github/pr` | Same endpoint the existing argo-events EventSource serves |
| Webhook secret | see [Webhook secret](#webhook-secret) below | |
| SSL verification | Enable (default) | Required for Cloudflare tunnel cert |

### Webhook secret

Reuse the existing one for continuity:

```bash
kubectl port-forward -n openbao svc/openbao 8200:8200 >/dev/null &
export BAO_ADDR=http://localhost:8200
export BAO_TOKEN=$(kubectl get secret openbao-keys -n openbao -o jsonpath='{.data.root-token}' | base64 -d)
bao kv get -mount=secret preview/github-webhook-secret -field=webhook-secret
```

Paste the printed value into the App's "Webhook secret" field.

If you want to rotate to a fresh value:

```bash
NEW_SECRET=$(openssl rand -hex 32)
bao kv put -mount=secret preview/github-webhook-secret webhook-secret="$NEW_SECRET"
echo "$NEW_SECRET"  # paste into GitHub App config
```

### Repository permissions

| Permission | Access | Why |
|---|---|---|
| Actions | Read | Workflow run/status events surfaced to ci-fixer |
| **Checks** | **Read and write** | Primary motivation for the App — agents write check runs |
| Contents | Read and write | Implementer + lead-dev push commits |
| Issues | Read and write | Comments, labels (`ai-feature`, `branch-created`, `ready-to-merge`, etc.) |
| Metadata | Read | Always required by GitHub |
| Pull requests | Read and write | Open PRs, comment, label, edit |

All other repository permissions: leave at "No access".

### Organization permissions

All "No access". The App does not need org-level membership or admin.

### User permissions

All "No access". The App acts as itself, not as users.

### Event subscriptions

Check the boxes for:

- Issue comment
- Issues
- Pull request
- Pull request review
- Pull request review comment
- Push
- Status

Leave everything else unchecked. (Subscribing to fewer events keeps the
EventSource log clean and reduces unnecessary sensor evaluations.)

### Where can this GitHub App be installed

Select **Only on this account**.

### Create

Click **Create GitHub App**. You'll land on the App's settings page.

### Capture immediately

From the top of the App's settings page, capture and store:

| Value | Where it lives | Used by |
|---|---|---|
| **App ID** (numeric, ~6 digits) | OpenBao `preview/github-app` field `APP_ID` | JWT signing for token exchange |
| **Client ID** (`Iv1.xxxxxxxxxxxxxxxx`) | OpenBao `preview/github-app` field `CLIENT_ID` | Reserved — only matters if we add user-OAuth later |

Both are visible in plain text on the page (don't have to "reveal" them).

## Phase 2 — Generate the private key

Still on the App's settings page, scroll down to **Private keys** →
click **Generate a private key**.

Browser downloads `example-app.YYYY-MM-DD.private-key.pem`. This is
the App's master credential — equivalent to a long-lived PAT for the
App itself. Treat accordingly:

- **Do not commit** to any repo
- **Do not paste** into chat/docs/issues
- Move out of `~/Downloads` to a stable location, e.g. `~/.secrets/`
- Will only stay on disk briefly; once seeded into OpenBao you can
  shred the local copy

## Phase 3 — Install on the example-org org

Left sidebar of the App settings page → **Install App** → click
**Install** next to `example-org`.

Choose **All repositories** (not "Only select repositories"). Future
repos under `example-org/*` get covered automatically.

Click **Install**.

After install, your URL bar shows:

```
https://github.com/organizations/example-org/settings/installations/12345678
                                                                  ^^^^^^^^
                                                                  Installation ID
```

Capture the **Installation ID** (numeric, ~8 digits).

## Phase 4 — Seed credentials into OpenBao

Three values go into a single OpenBao path: `preview/github-app`.

```bash
# Port-forward + auth (skip if already done from Phase 1)
kubectl port-forward -n openbao svc/openbao 8200:8200 >/dev/null &
export BAO_ADDR=http://localhost:8200
export BAO_TOKEN=$(kubectl get secret openbao-keys -n openbao -o jsonpath='{.data.root-token}' | base64 -d)

# Seed all three at once
bao kv put -mount=secret preview/github-app \
  APP_ID="123456" \
  INSTALLATION_ID="12345678" \
  CLIENT_ID="Iv1.abc123def456ghij" \
  PRIVATE_KEY=@~/.secrets/example-app.YYYY-MM-DD.private-key.pem
```

Replace the placeholder values with what you captured in Phase 1 + 3
and the path to your downloaded `.pem` file.

### Verify

```bash
# Should print all four field names; do NOT print PRIVATE_KEY value
bao kv get -mount=secret preview/github-app -format=json | jq '.data.data | keys'
# Expected: ["APP_ID", "CLIENT_ID", "INSTALLATION_ID", "PRIVATE_KEY"]
```

### Cleanup local copy

Once verified in OpenBao:

```bash
shred -u ~/.secrets/example-app.*.private-key.pem    # Linux
# OR
rm -P ~/.secrets/example-app.*.private-key.pem       # macOS
```

(Optional but recommended. If you keep a local copy, ensure it's outside
any repo and the parent dir isn't world-readable.)

## Phase 5 — ESO sync into the cluster (CUE work)

Adds an `ExternalSecret/github-app-creds` to both `argo-events` and
`kelos-system` namespaces, sourced from `preview/github-app`.

The agent prompts and Task specs reference the synced k8s Secret rather
than OpenBao directly.

```cue
// composites/home/externalsecrets.cue (excerpt)
{
  name:      "github-app-creds"
  namespace: "kelos-system"     // and argo-events
  secretStoreRef: "openbao-backend"
  refreshInterval: "5m"
  data: [
    {secretKey: "APP_ID",          remoteRef: {key: "preview/github-app", property: "APP_ID"}},
    {secretKey: "INSTALLATION_ID", remoteRef: {key: "preview/github-app", property: "INSTALLATION_ID"}},
    {secretKey: "PRIVATE_KEY",     remoteRef: {key: "preview/github-app", property: "PRIVATE_KEY"}},
  ]
  ...
}
```

After render + apply, verify:

```bash
kubectl get externalsecret github-app-creds -n kelos-system
kubectl get externalsecret github-app-creds -n argo-events
# Both should show STATUS: SecretSynced, READY: True
```

## Phase 6 — Token-exchange mechanism

The App's private key is not directly usable as an API credential.
Every API call needs a short-lived **installation access token**:

```
   PRIVATE_KEY (PEM) + APP_ID
            │
            ▼
   sign JWT (RS256)
   claims: {iat: now, exp: now+10min, iss: APP_ID}
            │
            ▼
   POST /app/installations/{INSTALLATION_ID}/access_tokens
   header: Authorization: Bearer <jwt>
            │
            ▼
   response: { token: "ghs_xxx", expires_at: "2026-04-29T17:00:00Z" }
            │
            ▼
   use as: Authorization: token ghs_xxx   (valid 1 hour)
```

### Delivery to agents

Two patterns depending on Task lifetime:

**A. Init container (Kelos Tasks — short-lived, ≤30 min)**

Each Task pod gets an init container that runs once at start, fetches
a token, writes it to a shared volume mounted at `/var/run/github-app/`.
Main agent container reads `GH_TOKEN=$(cat /var/run/github-app/token)`.

```yaml
# Sketch — actual CUE wrapper added in Phase 7
spec:
  initContainers:
    - name: gh-app-token
      image: ghcr.io/example-org/gh-app-token-fetcher:v0.1.0
      env:
        - {name: APP_ID,          valueFrom: {secretKeyRef: {name: github-app-creds, key: APP_ID}}}
        - {name: INSTALLATION_ID, valueFrom: {secretKeyRef: {name: github-app-creds, key: INSTALLATION_ID}}}
        - {name: PRIVATE_KEY,     valueFrom: {secretKeyRef: {name: github-app-creds, key: PRIVATE_KEY}}}
      volumeMounts:
        - {name: gh-token, mountPath: /var/run/github-app}
  containers:
    - name: claude-code
      env:
        - {name: GH_TOKEN_FILE, value: /var/run/github-app/token}
      volumeMounts:
        - {name: gh-token, mountPath: /var/run/github-app, readOnly: true}
  volumes:
    - {name: gh-token, emptyDir: {medium: Memory}}
```

**B. CronJob refresh (argo-events sensors — long-lived deployments)**

Sensors run continuously. A CronJob in `argo-events` runs every 30 min,
fetches a token, writes/updates `Secret/github-app-token` (key: `token`).
Sensors mount that Secret as env. The 1-hour token validity gives a
30-min slack window for cron-job hiccups.

### `gh-app-token-fetcher` image

Minimal container, no language runtime — just shell + standard tools:

```dockerfile
FROM alpine:3.19
RUN apk add --no-cache openssl curl jq
COPY fetch.sh /usr/local/bin/fetch
ENTRYPOINT ["/usr/local/bin/fetch"]
```

`fetch.sh` (~30 lines): build JWT manually using `openssl dgst -sha256
-sign`, exchange via `curl`, write to `${OUTPUT_PATH:-/var/run/github-app/token}`.

Built and pushed to `ghcr.io/example-org/gh-app-token-fetcher` during
Phase 7.

## Phase 7 — Migration cutover

Phased rollout to minimize blast radius:

1. **Build + push** `gh-app-token-fetcher:v0.1.0` to GHCR
2. **Pilot** on the panel sensor only:
   - Update one panel agent's Task spec (init container + new env)
   - Trigger a fresh PR review
   - Verify check runs appear in PR header under the App's name
   - Verify findings comment posts correctly
3. **Roll out** to remaining panel agents, lead-dev, implementer,
   ideator, code-explain, slash-help
4. **Webhook migration**:
   - The GitHub App's webhook subscription replaces the Crossplane
     `RepositoryWebhook/salessage-events` (App webhook covers all
     installed repos; per-repo Crossplane RepositoryWebhook becomes
     redundant)
   - Delete `RepositoryWebhook/salessage-events` (Crossplane removes
     the GitHub-side webhook)
   - Decommission the `composites/home/githubrepositorywebhooks.cue`
     CUE list (or keep for documentation, but mark deprecated)
5. **Retire `github-pat`**:
   - Verify all sensors and Tasks are using the App-issued token for
     a full pipeline run (panel → lead-dev → merge)
   - After 7 days of stable operation, remove `github-pat` from
     OpenBao + delete `Secret/github-pat` ExternalSecret bindings
   - Keep PAT itself disabled in GitHub but not deleted for ~30 days
     in case rollback is needed

## Permissions and event reference (quick lookup)

### Repository permissions granted

```
actions:        read
checks:         read+write
contents:       read+write
issues:         read+write
metadata:       read
pull_requests:  read+write
```

### Events subscribed

```
issue_comment, issues, pull_request, pull_request_review,
pull_request_review_comment, push, status
```

### OpenBao paths

```
preview/github-app
  ├── APP_ID
  ├── CLIENT_ID
  ├── INSTALLATION_ID
  └── PRIVATE_KEY (PEM)

preview/github-webhook-secret
  └── webhook-secret              # used by EventSource (currently NOT validated — see HMAC validation below)

preview/github-pat                # legacy, retired during Phase 7
  ├── GITHUB_USER
  └── GITHUB_TOKEN
```

### Cluster Secrets (post Phase 5)

| Secret | Namespace | Source |
|---|---|---|
| `github-app-creds` | `kelos-system` | ESO from `preview/github-app` |
| `github-app-creds` | `argo-events` | ESO from `preview/github-app` |
| `github-app-token` | `argo-events` | Refreshed every 30min by CronJob |
| `github-webhook-secret` | `argo-events` | ESO from `preview/github-webhook-secret` |

## HMAC validation (deferred)

The current EventSource uses argo-events' generic `webhook:` type which
does **not** validate `X-Hub-Signature-256`. The App's webhook secret
is configured (and GitHub does sign payloads) but the signature is
ignored on receipt. Mitigation: the endpoint
`events.example.com/github/pr` is only reachable via Cloudflare tunnel,
not public internet.

To add validation later: deploy an openresty/nginx pod in `argo-events`
that verifies HMAC before forwarding to the EventSource on port 12000.
Tracked separately — not required for the App migration.

## Troubleshooting

### `404 Not Found` from `gh api repos/.../check-runs`

Token doesn't have `checks:write` permission on this repo. Causes:

- App not installed on this repo → install via "Install App" page
- App permission stale (added `checks:write` after install) →
  user/admin must accept the updated permissions on the install page
- Wrong token type — confirm you're using App-issued token, not PAT,
  by checking token prefix (`ghs_*` = App, `gho_*`/`ghp_*` = PAT)

### `JWT signing failed` in `gh-app-token-fetcher`

PEM key not loaded correctly. Check:

- `kubectl get secret github-app-creds -n kelos-system -o jsonpath='{.data.PRIVATE_KEY}' | base64 -d | head -1`
  → should print `-----BEGIN RSA PRIVATE KEY-----` or
  `-----BEGIN PRIVATE KEY-----`
- If the first line is anything else (HTML, JSON, garbage), re-seed
  Phase 4 with `@/path/to/file.pem` syntax (not literal value)

### Token expires in middle of a long Task

Default token lifetime: 1 hour. If an agent Task runs >1 hour:

- Switch to sidecar pattern (refresh inline) instead of init container
- OR shorten the Task by splitting it
- OR set `repositories` claim in the access token request to scope it
  more narrowly (does not extend lifetime, but reduces risk)

### Webhook signature 401 (after enabling validation)

Webhook secret on GitHub side != value at OpenBao
`preview/github-webhook-secret`. Re-seed both, ensuring exact match
(no trailing newline, no spaces).

## References

- GitHub Apps API: https://docs.github.com/en/rest/apps
- Check Runs API: https://docs.github.com/en/rest/checks/runs
- Installation tokens: https://docs.github.com/en/rest/apps/apps#create-an-installation-access-token-for-an-app
- argo-events generic webhook EventSource:
  https://argoproj.github.io/argo-events/eventsources/setup/webhook/
