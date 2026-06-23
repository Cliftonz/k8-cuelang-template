# SalesSage Preview Environment — Implementation Prompt

Hand this document to an AI working in the `example-org/SalesSage` repository.
It contains everything needed to build the SalesSage side of the preview
environment pipeline. The platform side (k8-infra) is already wired.

---

## What you are building

When a PR on `example-org/SalesSage` has the GitHub label `preview`, the
platform (Argo CD on a Talos Linux cluster) spins up a full preview
environment in a dedicated Kubernetes namespace. Your job is to create the
artifacts the platform consumes:

1. **A Helm chart** at `chart/` in the repo root.
2. **A Dockerfile** that builds the Next.js app.
3. **A GitHub Actions workflow** that builds the image and pushes to GHCR.
4. **A stack-top detection workflow** that manages the `preview` label on
   stacked PRs.

---

## 1. Helm chart at `chart/`

### Platform contract

The platform's Argo CD ApplicationSet deploys this chart with these
overrides (you do NOT control these — they are injected automatically):

```yaml
# Values injected by the ApplicationSet (DO NOT hardcode)
image:
  repository: ghcr.io/example-org/salessage
  tag: sha-<40-char-commit-sha>
hostBase: salessage-pr-<PR_NUMBER>.example.internal    # chart derives subdomains from this
ingress:
  enabled: true
  className: traefik                                 # LAN-only via MetalLB
fullnameOverride: salessage-<PR_NUMBER>
```

> **Exposure model — internal-only, subdomain-per-service.** Previews
> are LAN-only (not public). The chart MUST create one Ingress per
> service, deriving subdomains from `hostBase`:
>
>   - `app.<hostBase>` — main app
>   - `mailpit.<hostBase>` — mailpit UI
>   - `supabase.<hostBase>` — Supabase Kong (REST + auth)
>   - `studio.<hostBase>` — Supabase Studio (optional)
>   - `<hostBase>` — small index page (nginx + ConfigMap with HTML) that
>     links to all of the above. Acts as the "front door" so devs land
>     somewhere useful when they hit the bare base host.
>
> All Ingresses use `ingressClassName: traefik` (the cluster's default,
> LoadBalancer at MetalLB IP `192.168.2.240`). External-dns-unifi
> writes A records to UniFi's local DNS pointing at that IP — hostnames
> resolve only from inside the LAN (or via Tailscale). Public DNS
> returns NXDOMAIN. No Cloudflare tunnel involvement for previews.
>
> External-dns-unifi runs with `--policy=sync`, so DNS records are
> automatically deleted when Argo CD prunes the Ingresses on PR
> close. No manual cleanup needed.

Your `values.yaml` must define these keys with LOCAL DEFAULTS (so
`helm template` works standalone), and the ApplicationSet overrides them
at deploy time.

### MUST include

| Template | What | Notes |
|---|---|---|
| `deployment.yaml` | Main app Deployment | `image.repository` + `image.tag` from values. `envFrom: [{secretRef: {name: app-shared-secrets}}]`. `imagePullSecrets: [{name: ghcr-pull-secret}]`. |
| `service.yaml` | ClusterIP Service | Targets the Deployment pods on the app port (e.g. 3000). |
| `ingresses/app.yaml` | App Ingress @ `app.{{ .Values.hostBase }}` | `className: {{ .Values.ingress.className }}`. Backend: app Service. |
| `ingresses/mailpit.yaml` | Mailpit Ingress @ `mailpit.{{ .Values.hostBase }}` | Same className. Backend: mailpit Service, port 8025 (UI). |
| `ingresses/supabase-kong.yaml` | Supabase Ingress @ `supabase.{{ .Values.hostBase }}` | Same className. Backend: `{{ .Release.Name }}-supabase-kong` Service. The app's `NEXT_PUBLIC_SUPABASE_URL` should be `https://supabase.{{ .Values.hostBase }}` (HTTP — internal LAN, no TLS). |
| `ingresses/studio.yaml` | Supabase Studio Ingress @ `studio.{{ .Values.hostBase }}` | Same className. Backend: `{{ .Release.Name }}-supabase-studio` Service. Useful for debugging schema in-browser. |
| `ingresses/index.yaml` + `index-cm.yaml` + `index-deploy.yaml` + `index-svc.yaml` | Bare-host Ingress @ `{{ .Values.hostBase }}` | Tiny nginx Deployment serving an HTML index from a ConfigMap. The HTML lists each sub-service URL as a clickable link. Acts as the dev's landing page. |
| **Supabase subchart dependency** | Full Supabase OSS stack | Declare `supabase-community/supabase-kubernetes` as a Helm subchart dependency in `Chart.yaml` and configure via `values.yaml`'s `supabase:` block. Provisions postgres (with all required extensions baked in), kong (API gateway), gotrue (auth), postgrest, realtime, storage-api, imgproxy, postgres-meta, studio, functions — one full per-preview Supabase. See [§Supabase contract](#supabase-contract) below. |
| `jwt-init-job.yaml` | Per-preview JWT secret derivation | Argo CD sync-wave `-20`. Reads `JWT_MASTER_KEY` from `app-shared-secrets`, HMACs against `{{ .Release.Name }}` → deterministic `{jwt_secret, anon_key, service_role_key}`. Writes `{{ .Release.Name }}-supabase-jwt` + `{{ .Release.Name }}-supabase-db` Secrets the subchart and app reference. Same secrets across rebuilds, distinct across previews. |
| `migration-job.yaml` | Schema migrations | Argo CD sync-wave `5` (after Supabase up, before app starts). Runs your app's Supabase migrations against the in-cluster Postgres. |
| `configmap.yaml` | Non-secret env vars | `NODE_ENV=production`, `NEXT_PUBLIC_APP_URL=https://app.{{ .Values.hostBase }}`, `NEXT_PUBLIC_SUPABASE_URL=https://supabase.{{ .Values.hostBase }}`, `SMTP_HOST={{ .Release.Name }}-mailpit`, `SMTP_PORT=1025`. **Do NOT** put `DATABASE_URL` or any Supabase key here — those live in Secrets (per `jwt-init-job.yaml`). |
| `values.yaml` | Default values | Sane standalone defaults. See "values.yaml shape" below. |

### SHOULD include

| Template | What | Notes |
|---|---|---|
| `mailpit-deployment.yaml` | Mailpit for email testing | Image: `axllent/mailpit:latest`. Ports: 1025 (SMTP), 8025 (UI). Set `SMTP_HOST` + `SMTP_PORT` in the app's ConfigMap to point at `{{ .Release.Name }}-mailpit:1025`. |
| `mailpit-service.yaml` | ClusterIP for mailpit | Ports 1025 + 8025. |
| _(no separate mailpit-ingress)_ | Mailpit Ingress is now in `ingresses/mailpit.yaml` above and shipped by default with className=traefik. |
| Resource limits | On ALL containers | App: requests 128m/256Mi, limits 500m/512Mi. Supabase services: rely on subchart defaults, override per-service in `values.yaml` if needed. Mailpit: requests 10m/32Mi, limits 100m/64Mi. Be mindful: full Supabase stack adds ~2.5 GiB per preview, and the cluster caps total active previews at 6 (see [§Preview cap](#preview-cap)). |
| Probes | Liveness + readiness | On the main app container. `httpGet` on `/api/health` or `/` with appropriate `initialDelaySeconds` (Next.js cold start can take 10-30s). |

### MUST NOT include

These will cause failures or conflicts with the platform:

| Resource | Why |
|---|---|
| `Namespace` | Argo CD creates the namespace. A Namespace resource in the chart will conflict with `CreateNamespace=true` + `managedNamespaceMetadata`. |
| `ResourceQuota` | Blacklisted in the Argo CD AppProject. Platform manages quotas. |
| `NetworkPolicy` | Blacklisted in the Argo CD AppProject. |
| `ClusterRole`, `ClusterRoleBinding` | Blacklisted (only `Namespace` is whitelisted as a cluster-scoped resource the chart may create). Charts using subcharts that ship cluster RBAC by default (e.g. Supabase's storage / postgres-meta `ClusterRole` + `ClusterRoleBinding`) must disable them via the subchart's `serviceAccount.create=false` / `rbac.create=false` toggles. Namespace-scoped `Role` + `RoleBinding` ARE allowed inside the preview namespace — needed for the jwt-init Job and the Supabase SAs. |
| `Secret` with actual values | ALL secrets come from the platform's ClusterExternalSecret operator. The chart REFERENCES secrets by name (`app-shared-secrets`, `ghcr-pull-secret`) but does NOT create them. Never embed API keys, tokens, or credentials in the chart. |
| `Ingress` with `className: cloudflare-tunnel` | Previews are LAN-only. ALL Ingresses use `className: traefik`. The `cloudflare-tunnel` IngressClass exists in the cluster but is reserved for long-lived public-facing services, not previews. |
| `PersistentVolumeClaim` | Let the Supabase subchart's postgres StatefulSet manage its own PVCs. Do not create PVCs directly. |
| Hardcoded `DATABASE_URL` / `NEXT_PUBLIC_SUPABASE_URL` / anon keys in ConfigMap or values | These are derived per-preview by the `jwt-init-job.yaml` Job. Hardcoding will fail auth handshakes (the chart's previous `app:app` literal cost us a 30h-degraded preview during PR #182's bring-up). |
| Helm `pre-install` hooks depending on secrets | Secrets arrive via ClusterExternalSecret and may take up to 5 minutes after namespace creation. Use init containers with retry logic or Argo CD sync-wave ordering instead. |
| Resources in other namespaces | Everything must target the release namespace only. |

### values.yaml shape

```yaml
# -- Image configuration. Overridden by ApplicationSet at deploy time.
image:
  repository: ghcr.io/example-org/salessage
  tag: latest
  pullPolicy: IfNotPresent

# -- Replica count. 1 for preview environments.
replicaCount: 1

# -- Base host the chart derives per-service subdomains from.
# Platform overrides this with `salessage-pr-<N>.example.internal`. Local
# default lets `helm template` work without injection.
hostBase: salessage-local.example.internal

# -- Ingress class (LAN-only traefik for previews).
ingress:
  enabled: true
  className: traefik
  annotations: {}
  # The chart derives per-service Ingresses from hostBase — there's no
  # single ingress.hosts[] list to populate here. Each Ingress template
  # (app.yaml, mailpit.yaml, supabase-kong.yaml, studio.yaml, index.yaml)
  # uses its own subdomain.

# -- Override the full resource name prefix (platform sets this).
fullnameOverride: ""

# -- Supabase backend per preview.
# Defaults are tuned for the preview environment. Production should
# disable this (supabase.enabled=false) and point at managed Supabase.
# The Helm subchart at github.com/supabase-community/supabase-kubernetes
# provides the full stack (postgres, kong, gotrue, postgrest, realtime,
# storage-api, imgproxy, postgres-meta, studio, functions).
supabase:
  enabled: true

  # Secret refs the subchart consumes. All three Secrets are created by
  # the chart's jwt-init Job at sync-wave -20.
  secret:
    jwt:
      secretRef: salessage-supabase-jwt
      anonKeyRefKey: anonKey
      serviceKeyRefKey: serviceKey
      secretRefKey: secret
    smtp:
      secretRef: salessage-supabase-smtp
      usernameRefKey: username
      passwordRefKey: password
    db:
      secretRef: salessage-supabase-db
      usernameRefKey: username
      passwordRefKey: password
      databaseRefKey: database

  db:
    image:
      tag: "15.1.1.78"  # pin — ships pgjwt, pgsodium, pg_graphql, pg_net, supabase_vault
    persistence:
      enabled: true
      size: 1Gi          # ephemeral preview; keep small (cluster Longhorn storage is tight)
      storageClassName: longhorn

  auth:
    environment:
      GOTRUE_SMTP_HOST: '{{ .Release.Name }}-mailpit'
      GOTRUE_SMTP_PORT: "1025"
      GOTRUE_SMTP_USER: ''
      GOTRUE_SMTP_PASS: ''
      GOTRUE_SMTP_ADMIN_EMAIL: 'admin@preview.local'
      GOTRUE_SMTP_SENDER_NAME: 'Preview'
      GOTRUE_MAILER_AUTOCONFIRM: "false"
      GOTRUE_EXTERNAL_EMAIL_ENABLED: "true"

  kong:
    ingress:
      enabled: true
      className: cloudflare-tunnel    # platform overrides at ApplicationSet level
      hosts:
        - host: supabase-pr-PLACEHOLDER.example.internal
          paths:
            - path: /
              pathType: Prefix
      tls: []   # cloudflare-tunnel terminates TLS at the edge

# -- CNPG cluster. DISABLED in favor of Supabase's bundled postgres
# (which has the required extensions baked in). Kept for parity with
# production charts that may run CNPG separately.
postgresql:
  enabled: false

# -- Mailpit local email testing.
mailpit:
  enabled: true
  ingress:
    enabled: false            # enable for LAN access to mailpit UI
    className: traefik
    host: ""                  # platform can override

# -- App environment (non-secret). Rendered into a ConfigMap.
env:
  NODE_ENV: production
  # NEXT_PUBLIC_APP_URL is auto-derived from ingress host in the template.

# -- imagePullSecrets — platform provisions this Secret via ClusterExternalSecret.
imagePullSecrets:
  - name: ghcr-pull-secret

# -- App shared secrets — platform provisions this Secret via ClusterExternalSecret.
# The Deployment mounts it as envFrom. Do NOT create this Secret in the chart.
appSharedSecretName: app-shared-secrets

# -- App container resources.
resources:
  requests:
    cpu: 128m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi

# -- Probes.
livenessProbe:
  httpGet:
    path: /api/health
    port: http
  initialDelaySeconds: 30
  periodSeconds: 10
readinessProbe:
  httpGet:
    path: /api/health
    port: http
  initialDelaySeconds: 10
  periodSeconds: 5
```

---

## 2. Dockerfile

Create a multi-stage `Dockerfile` in the repo root:

```
Stage 1: deps     — install pnpm + dependencies (cached layer)
Stage 2: build    — pnpm build (Next.js production build)
Stage 3: runner   — minimal Node.js runtime image, copy build output
```

Requirements:
- Base image: `node:20-alpine` (or whatever the project uses).
- Use `pnpm` (the project's package manager).
- Final image should run as non-root user.
- Expose port 3000 (or the app's configured port).
- `CMD ["node", "server.js"]` or `CMD ["pnpm", "start"]` depending on
  Next.js output mode (standalone vs default).
- If using Next.js standalone output (`output: 'standalone'` in
  `next.config.js`), copy `.next/standalone` + `.next/static` + `public`.

---

## 3. GitHub Actions workflow: `.github/workflows/preview-build.yaml`

```yaml
name: Preview Build

on:
  pull_request:
    types: [labeled, synchronize, opened, reopened]

jobs:
  build:
    # Only run if the PR has the 'preview' label.
    if: contains(github.event.pull_request.labels.*.name, 'preview')
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      statuses: write
    env:
      REGISTRY: ghcr.io
      IMAGE_NAME: ${{ github.repository }}
    steps:
      - uses: actions/checkout@v4

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:sha-${{ github.event.pull_request.head.sha }}
            ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:pr-${{ github.event.pull_request.number }}

      - name: Set commit status
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh api repos/${{ github.repository }}/statuses/${{ github.event.pull_request.head.sha }} \
            -f state=success \
            -f context=ci/preview-build \
            -f description="Preview image pushed" \
            -f target_url="${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"

      - name: Notify platform (image ready)
        run: |
          curl -sf -X POST https://events.example.com/registry/push \
            -H 'Content-Type: application/json' \
            -d '{
              "repository": "${{ github.repository }}",
              "tag": "sha-${{ github.event.pull_request.head.sha }}",
              "pr_number": ${{ github.event.pull_request.number }}
            }'
```

Key conventions the platform depends on:
- **Image tag**: `sha-<full-40-char-sha>` — must match exactly.
- **Commit status context**: `ci/preview-build` with state `success` —
  the platform's Argo Events Sensor gates on this.
- **Registry push notification**: POST to
  `https://events.example.com/registry/push` — the platform's Sensor
  uses this to force-sync the Argo CD Application immediately (instead
  of waiting for the 3-minute poll).

### CI-fixer convention: run full CI locally before pushing

The platform includes a `/fix-ci` agent that auto-fixes CI failures on
PRs. When fixing SalesSage, the agent runs the FULL CI command set
locally inside the Kelos Task pod before pushing — to avoid burning
paid GitHub Actions minutes on broken fixes:

```bash
pnpm install --frozen-lockfile
pnpm typecheck
pnpm lint
pnpm test
```

All four must pass before the agent commits and pushes. This means the
SalesSage repo's CI commands must be runnable inside a standard Node.js
container without external dependencies (no browser tests, no E2E
requiring a running database — those are CI-only and the agent skips
them if they can't run locally).

---

## 4. Stack-top detection: `.github/workflows/stack-label.yaml`

This workflow manages the `preview` label on stacked PRs. It ensures only
the TOP of a manually-chained branch stack gets the label.

A PR is "top of stack" if no other open PR uses its HEAD branch as a BASE.

```yaml
name: Stack Label

on:
  pull_request:
    types: [opened, edited, synchronize, closed, reopened]

permissions:
  pull-requests: write

jobs:
  label:
    runs-on: ubuntu-latest
    steps:
      - name: Manage preview label
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          PR_NUMBER: ${{ github.event.pull_request.number }}
          HEAD_BRANCH: ${{ github.event.pull_request.head.ref }}
          BASE_BRANCH: ${{ github.event.pull_request.base.ref }}
          REPO: ${{ github.repository }}
          ACTION: ${{ github.event.action }}
        run: |
          set -euo pipefail

          # If PR was closed, remove the label (if present) and
          # re-evaluate the stack below this PR.
          if [ "$ACTION" = "closed" ]; then
            gh pr edit "$PR_NUMBER" --repo "$REPO" --remove-label preview 2>/dev/null || true
          fi

          # Find all open PRs in this repo with their updated_at timestamps.
          prs=$(gh pr list --repo "$REPO" --state open --json number,headRefName,baseRefName,updatedAt --limit 200)

          # Compute top-of-stack PRs (no other PR uses our HEAD as its BASE),
          # sorted by updatedAt desc so freshest stack-tops win ties.
          top_of_stack=$(
            echo "$prs" | jq --argjson all "$prs" '
              [ .[]
                | . as $pr
                | select( ($all | map(select(.baseRefName == $pr.headRefName)) | length) == 0 )
              ] | sort_by(.updatedAt) | reverse
            '
          )

          # CAP — Across all example-org preview-onboarded repos, only the
          # 6 most-recently-updated top-of-stack PRs get the `preview`
          # label. The platform's preview-cap-watchdog CronJob enforces
          # the same cap as a safety net.
          #
          # Aggregate top-of-stack PRs across all example-org preview
          # repos, sort globally by updatedAt desc, take top 6.
          PREVIEW_CAP=6
          OTHER_REPOS="example-org/SalesSage"  # extend as repos onboard
          all_global=$(
            for repo in $OTHER_REPOS; do
              [ "$repo" = "$REPO" ] && continue
              gh api "repos/$repo/issues?state=open&labels=preview&per_page=100" \
                --jq "[.[] | select(.pull_request) | {repo:\"$repo\", number, updatedAt: .updated_at}]"
            done | jq -s '[.[][]]'
          )
          this_repo_top=$(echo "$top_of_stack" | jq --arg r "$REPO" '[.[] | {repo:$r, number, updatedAt}]')
          eligible=$(
            echo "$all_global $this_repo_top" \
              | jq -s '[.[][]] | sort_by(.updatedAt) | reverse | .[0:'"$PREVIEW_CAP"']'
          )

          # For each open PR in THIS repo, decide whether it should have `preview`.
          # Add if: (top-of-stack) AND (in the global top-6 eligible set).
          # Remove otherwise.
          echo "$prs" | jq -c '.[]' | while read -r pr; do
            num=$(echo "$pr" | jq -r '.number')
            head=$(echo "$pr" | jq -r '.headRefName')

            is_top=$(echo "$top_of_stack" | jq --argjson n "$num" '[.[] | select(.number == $n)] | length')
            is_eligible=$(echo "$eligible" | jq --arg r "$REPO" --argjson n "$num" '[.[] | select(.repo == $r and .number == $n)] | length')

            if [ "$is_top" -gt 0 ] && [ "$is_eligible" -gt 0 ]; then
              gh pr edit "$num" --repo "$REPO" --add-label preview 2>/dev/null || true
            else
              gh pr edit "$num" --repo "$REPO" --remove-label preview 2>/dev/null || true
            fi
          done
```

This runs on every PR event and re-evaluates the entire stack. When PR #1
(main <- feature-a) and PR #2 (feature-a <- feature-b) are both open,
only PR #2 gets the `preview` label because PR #1's head branch
(`feature-a`) is used as PR #2's base.

The 6-PR global cap means that on a busy day with 7 open top-of-stack
PRs across repos, the LEAST-recently-updated one loses its preview.
Pushing a commit or commenting on it bumps its `updatedAt` and pulls it
back into the top 6 (kicking whichever PR is now 7th).

---

## Environment variables available to the app at runtime

| Variable | Source | How it arrives |
|---|---|---|
| `DATABASE_URL` | `{{ .Release.Name }}-supabase-db` Secret (key `connection_url`) | Created by chart's `jwt-init-job.yaml` at sync-wave -20. Wire via `valueFrom: secretKeyRef` in the app's Deployment. **NEVER** put this in a ConfigMap or hardcode `app:app`. |
| `NEXT_PUBLIC_SUPABASE_URL` | Chart's Deployment env | Templated value of `https://{{ (index .Values.supabase.kong.ingress.hosts 0).host }}`. The Kong Ingress per preview. |
| `NEXT_PUBLIC_SUPABASE_PUBLIC_KEY` | `{{ .Release.Name }}-supabase-jwt` Secret (key `anonKey`) | Generated by `jwt-init-job.yaml` deterministically from `JWT_MASTER_KEY` + release name. |
| `SUPABASE_SECRET_KEY` (service-role JWT) | `{{ .Release.Name }}-supabase-jwt` Secret (key `serviceKey`) | Same source. Used by server-side code only. |
| `SUPABASE_JWT_SECRET` | `{{ .Release.Name }}-supabase-jwt` Secret (key `secret`) | The HMAC seed used to sign per-preview JWTs. |
| `NEXTAUTH_SECRET` | `app-shared-secrets` Secret | Provisioned by platform's ClusterExternalSecret. Mounted via `envFrom`. |
| `STRIPE_SECRET_KEY` | `app-shared-secrets` Secret | Same. |
| `STRIPE_WEBHOOK_SECRET` | `app-shared-secrets` Secret | Same. |
| `VERCEL_AI_GATEWAY_KEY` | `app-shared-secrets` Secret | Same. |
| `JWT_MASTER_KEY` | `app-shared-secrets` Secret | The platform-side HMAC master. Read by the `jwt-init-job` Pod ONLY — the main app does not need direct access. |
| `NODE_ENV` | Chart's ConfigMap | Set to `production`. |
| `NEXT_PUBLIC_APP_URL` | Chart's ConfigMap | `https://app.{{ .Values.hostBase }}` — LAN-only, no TLS. |
| `NEXT_PUBLIC_SUPABASE_URL` | Chart's ConfigMap | `https://supabase.{{ .Values.hostBase }}` — Kong subdomain, browser-reachable from LAN. Overrides the placeholder value in `app-shared-secrets` for previews. |
| `SMTP_HOST` | Chart's ConfigMap | Points at mailpit: `{{ .Release.Name }}-mailpit`. |
| `SMTP_PORT` | Chart's ConfigMap | `1025`. |

Any new shared secrets are added in the k8-infra repo's
`composites/home/clusterexternalsecrets.cue` under the
`app-shared-secrets` entry (and `composites/preview/` equivalent) — the
app team does NOT need to change anything in SalesSage when a new shared
secret is added.

---

## Supabase contract <a name="supabase-contract"></a>

The chart MUST ship the full Supabase OSS stack per preview via the
`supabase-community/supabase-kubernetes` subchart. Background:

- SalesSage uses Supabase for auth (GoTrue) + REST API (PostgREST) +
  Postgres. Every PR needs an isolated Supabase so reviewers can sign
  up, exercise flows, and verify changes without state collision.
- Supabase's bundled Postgres image ships the extensions the platform
  needs (`pgjwt`, `pgsodium`, `pg_graphql`, `pg_net`, `supabase_vault`).
  Stock CNPG does NOT. The chart's `cnpg-cluster.yaml` is left in the
  tree with `postgresql.enabled=false` as default, in case production
  charts want CNPG separately.
- Per-preview JWT secrets are deterministic: `HMAC(JWT_MASTER_KEY,
  release_name)`. Same `secret + anonKey + serviceKey` across rebuilds
  of the same preview (auth tokens survive a pod restart), isolated
  across previews (one PR's anon token doesn't open another PR's API).
- The Kong API gateway is exposed via its own per-preview Ingress at
  `supabase-pr-<N>.example.internal`, alongside the main app Ingress at
  `salessage-pr-<N>.example.internal`. Browsers hit Kong directly (not
  proxied through the Next.js server) because the app's
  `getSupabaseBrowserClient` needs a browser-reachable URL.

See `composites/home/clusterexternalsecrets.cue` for the `JWT_MASTER_KEY`
projection. Operator runbook (one-time per cluster):

```bash
bao kv put -mount=secret preview/app/supabase-jwt-master \
  JWT_MASTER_KEY="$(openssl rand -hex 32)"
```

---

## Preview cap <a name="preview-cap"></a>

The platform caps concurrent active previews at **6** across all
example-org preview-onboarded repos. At ~2.5 GiB per preview with the
full Supabase stack, 6 ≈ 15 GiB — roughly half of the 4-node cluster's
~30 GiB allocatable, leaving headroom for platform workloads.

The cap is enforced at two layers:

1. **Per-repo `.github/workflows/stack-label.yaml`** (proactive gate).
   When applying the `preview` label to a PR, the workflow first counts
   open `preview`-labeled PRs across the repo (and queries other
   example-org preview repos via gh API) — if the global count is
   already at-or-over 6, it refuses to add the label. The "youngest"
   stack-top PRs go in, oldest get bumped.

2. **Platform-side `preview-cap-watchdog` CronJob** (reactive safety
   net, runs every 5 min in `argocd` ns on the home cluster). Enumerates
   open `preview`-labeled PRs across the same set of repos, sorts by
   `updated_at` desc, and DELETEs the `preview` label on any PR past
   position 6. Catches races, manual label-add, and any repo whose
   workflow lags behind.

Closing or pushing a new commit on an old PR resets its `updated_at`
and re-promotes it past whichever PR was 6th. So "stale loses
preview" is the implicit behavior — fine for normal review cycles.

If you genuinely need 7+ active previews, raise `_previewCap` in
`composites/home/cronjobs.cue` and update the workflow's per-repo
count. Reconsider the resource budget first.

---

## What NOT to do

- Do NOT create Kubernetes Secrets with real values in the chart.
- Do NOT hardcode the image tag — it comes from values.
- Do NOT add `className: cloudflare-tunnel` to any Ingress other than
  the main app. Internal services use `className: traefik` or no Ingress.
- Do NOT create a `Namespace` resource in the chart.
- Do NOT add `ResourceQuota`, `NetworkPolicy`, or RBAC resources.
- Do NOT use Helm `pre-install` hooks that depend on Secrets (they may
  not exist yet when the hook runs).
- Do NOT create PVCs directly — the Supabase subchart's postgres
  StatefulSet manages its own storage.
- Do NOT hardcode Supabase URL / anon key / service-role key / DB
  password anywhere in the chart. They are derived per-preview by
  `jwt-init-job.yaml`.

---

## Testing locally

```bash
# Render templates without deploying (sanity check):
helm template my-preview chart/ \
  --set image.tag=sha-abc1234 \
  --set ingress.hosts[0].host=salessage-pr-99.example.internal

# Lint:
helm lint chart/

# If you have a local kind/k3s cluster with CNPG installed:
helm install test-preview chart/ --namespace test-preview --create-namespace
```

---

## Summary checklist

- [ ] `Dockerfile` in repo root (multi-stage, non-root, port 3000)
- [ ] `chart/Chart.yaml` + `chart/values.yaml`
- [ ] `chart/templates/deployment.yaml` (envFrom: app-shared-secrets, imagePullSecrets: ghcr-pull-secret)
- [ ] `chart/templates/service.yaml`
- [ ] `chart/templates/ingress.yaml` (className from values)
- [ ] `chart/Chart.yaml` declares `supabase-community/supabase-kubernetes` as a subchart dependency
- [ ] `chart/templates/jwt-init-job.yaml` (sync-wave -20, derives per-preview JWT secrets)
- [ ] `chart/templates/migration-job.yaml` (sync-wave 5, runs Supabase migrations)
- [ ] `chart/templates/cnpg-cluster.yaml` exists but `postgresql.enabled=false` by default
- [ ] `chart/templates/configmap.yaml` has ONLY non-secret keys (`NEXT_PUBLIC_APP_URL`, `SMTP_*`, `NODE_ENV`) — NO `DATABASE_URL`, NO Supabase URLs/keys
- [ ] `chart/templates/mailpit-deployment.yaml` + `mailpit-service.yaml`
- [ ] `chart/templates/deployment.yaml` wires `DATABASE_URL` + Supabase env from per-preview Secrets via `valueFrom: secretKeyRef`, NOT envFrom-configMap
- [ ] `.github/workflows/preview-build.yaml` (build + push + status + notify)
- [ ] `.github/workflows/stack-label.yaml` (manages preview label on stacked PRs AND enforces the 6-preview cap)
- [ ] `helm lint chart/` passes
- [ ] `helm template` renders without errors
