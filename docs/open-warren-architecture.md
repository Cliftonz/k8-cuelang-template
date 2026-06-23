# Architecture Plan: Open-Warren — AI Agent Platform via Crossplane XRDs

## What this is

A set of Crossplane XRDs + Compositions that package the AI agent platform
built in example-org/k8-infra into reusable, composable building blocks.
Users install the XRDs, create claims, and get AI agents + preview
environments — all reconciled by Crossplane. No custom Go controller.

## Design principles

1. **Crossplane-native.** XRDs + Compositions + provider-kubernetes.
   No operator binary to build, ship, or version. Crossplane handles
   reconciliation, drift detection, and GC.

2. **Composable, not monolithic.** Separate CRDs for separate concerns:
   agents, notifications, preview environments. One repo can have 5
   agents; two repos can share a notification channel; preview envs are
   their own design surface. No god-object CRD.

3. **Zero SaaS dependencies.** The entire system runs on local/self-hosted
   infrastructure. No Cloudflare, no GHCR, no hosted DNS required. Users
   bring their own ingress controller, container registry (local Harbor,
   Zot, or distribution), DNS (CoreDNS + ExternalDNS or static), and
   secret backend (Vault, OpenBao, or raw k8s Secrets). A kind/k3d
   cluster with local registry is a first-class deployment target.

4. **Everything from what's proven.** Every template, prompt, and
   workflow comes directly from the working example-org/k8-infra system.
   Nothing speculative.

---

## CRD hierarchy

```
XAgentRepo                        # one per repository
├── references: XAgent[]          # which agents serve this repo
├── references: XNotification[]   # where to send alerts
└── credentials, webhook config

XAgent                            # one per agent capability
├── generates: AgentConfig        # Kelos
├── generates: TaskSpawner or Sensor  # depending on trigger type
└── type-specific config (ciCommands, rateLimit, etc.)

XNotification                     # one per notification channel
├── generates: Secret wiring      # webhook URL / token
└── reusable across repos

XPreviewEnvironment               # one per repo (if preview desired)
├── generates: ApplicationSet     # Argo CD
├── generates: AppProject
├── generates: CronJob (reaper)
├── generates: RBAC
└── (deeper design TBD — see section below)
```

---

## CRD: `XAgentRepo`

The anchor resource. Defines a repository and its connections. Agents
and notifications are separate resources that reference back to the repo
(or the repo references them — either direction works).

```yaml
apiVersion: open-warren.io/v1alpha1
kind: XAgentRepo
metadata:
  name: salessage
spec:
  repository:
    url: https://github.com/example-org/SalesSage.git
    owner: example-org
    name: SalesSage
    slug: salessage

  credentials:
    github:
      secretRef:
        name: github-pat
        key: GITHUB_TOKEN
    agent:
      type: oauth                    # oauth | api-key | none
      secretRef:
        name: claude-code-oauth
        key: CLAUDE_CODE_OAUTH_TOKEN
    imagePullSecret: ghcr-pull-secret

  agentType: claude-code             # claude-code | codex | gemini | cursor

  webhook:
    # Shared EventSource name. Multiple repos can share one EventSource
    # if they're on the same org webhook. The repo filter in Sensors
    # discriminates by owner/name.
    eventSourceRef:
      name: github-webhook
      eventName: pr-events

  # References to XAgent resources serving this repo
  agents:
    - name: salessage-reviewer
    - name: salessage-ci-fixer
    - name: salessage-explainer
    - name: salessage-help

  # References to XNotification resources
  notifications:
    - name: discord-platform

  # Palette config (owned by the repo, not a separate CRD, because
  # it's 1:1 with the repo and tightly coupled to the agent lifecycle)
  palette:
    enabled: true
    postOnPrOpen: true
```

**What the Composition generates:**
- 1 Kelos Workspace (repo + credentials)
- 1 Sensor `{slug}-palette-init` (if palette.enabled)
- 1 AgentConfig `{slug}-palette-updater` (if palette.enabled)
- 1 TaskSpawner `{slug}-palette-updater` (if palette.enabled, maxConcurrency: 1)
- Labels/annotations shared across child resources

---

## CRD: `XAgent`

One per agent capability. Links to a specific repo via `repoRef`.
An agent without a `repoRef` is "org-wide" — serves all repos on the
shared webhook (e.g., `/help` and `/explain` can be org-wide or
repo-scoped).

### Type: reviewer

```yaml
apiVersion: open-warren.io/v1alpha1
kind: XAgent
metadata:
  name: salessage-reviewer
spec:
  repoRef:
    name: salessage                  # links to specific XAgentRepo
  type: reviewer
  trigger:
    command: /review
    mechanism: polling               # polling | event-driven
    polling:
      interval: 1m
      maxConcurrency: 2
  customInstructions: ""             # appended to default agentsMD
```

### Type: ci-fixer

```yaml
apiVersion: open-warren.io/v1alpha1
kind: XAgent
metadata:
  name: salessage-ci-fixer
spec:
  repoRef:
    name: salessage                  # linked to SalesSage repo
  type: ci-fixer
  trigger:
    command: /fix-ci
    mechanism: polling
    polling:
      interval: 1m
      maxConcurrency: 1
  ciFixer:
    maxAttempts: 3
    # Commands the agent runs locally to verify fixes BEFORE pushing.
    # Must match what the repo's CI runs. Agent iterates until all pass.
    ciCommands:
      - pnpm install --frozen-lockfile
      - pnpm typecheck
      - pnpm lint
      - pnpm test
    dispatcherWorkflows: [CI, Build, Test, Lint]
```

### Type: explainer (org-wide example — no repoRef)

```yaml
apiVersion: open-warren.io/v1alpha1
kind: XAgent
metadata:
  name: org-explainer
spec:
  # No repoRef — serves ALL repos on this org's webhook.
  # Sensor filter uses the org name from the webhook payload.
  type: explainer
  trigger:
    command: /explain
    mechanism: event-driven
    eventDriven:
      rateLimit:
        requestsPerMinute: 3
  # Org-wide agents work without a Workspace. They read files via
  # gh api and post replies via gh api. No clone needed.
```

### Type: help (org-wide)

```yaml
apiVersion: open-warren.io/v1alpha1
kind: XAgent
metadata:
  name: org-help
spec:
  # No repoRef — org-wide. Static reply Job, no LLM.
  type: help
  trigger:
    command: /help
    mechanism: event-driven
  # The reply content is auto-generated from all XAgent resources in
  # the namespace — scans for sibling XAgents, builds a command table.
```

### Repo-scoped vs org-wide behavior

| Field | Repo-scoped (repoRef set) | Org-wide (no repoRef) |
|---|---|---|
| Sensor filter | `body.repository.full_name == owner/name` | `body.repository.full_name =~ ^org/` |
| TaskSpawner repo | Derived from Workspace | N/A (no TaskSpawner) |
| Workspace | Required (clone for code access) | Not used (gh api only) |
| AgentConfig | Repo-specific instructions | Generic instructions |

**What each XAgent Composition generates:**

| Type | AgentConfig | TaskSpawner | Sensor | Notes |
|---|---|---|---|---|
| reviewer | Yes | Yes (polling) | No | commentPolicy trigger |
| ci-fixer | Yes | Yes (polling) | No | commentPolicy trigger + runs full CI locally |
| explainer | Yes | No | Yes (event-driven) | review-comment filter, rateLimit |
| help | No | No | Yes (event-driven) | static Job reply, no LLM |
| palette-updater | Yes | Yes (maxConc:1) | No | generated by XAgentRepo, not XAgent |

---

## CRD: `XNotification`

Two engines, one CRD. Exposes the full power of each underlying system.

### Engine 1: Argo CD Notifications (app lifecycle)

For events tied to Argo CD Applications — deploy success, health
degraded, sync failed, out-of-sync. Exposes the raw Argo CD
notification engine: triggers, templates, and services.

```yaml
apiVersion: open-warren.io/v1alpha1
kind: XNotification
metadata:
  name: argocd-discord
spec:
  engine: argocd

  # Raw Argo CD notification service definition.
  # This is the full Argo CD notifications service config — the XRD
  # passes it through to argocd-notifications-cm ConfigMap.
  services:
    discord-platform:
      webhook:
        url: $discord-webhook-url    # references a k8s Secret key

  # Raw Argo CD notification templates.
  templates:
    on-deployed: |
      message: |
        :white_check_mark: **{{.app.metadata.name}}** deployed successfully.
        {{if .app.status.operationState.syncResult}}
        Revision: {{.app.status.operationState.syncResult.revision}}
        {{end}}
    on-health-degraded: |
      message: |
        :warning: **{{.app.metadata.name}}** health degraded.
        {{range .app.status.conditions}}
        - {{.type}}: {{.message}}
        {{end}}
    on-sync-failed: |
      message: |
        :x: **{{.app.metadata.name}}** sync failed.
        {{.app.status.operationState.message}}

  # Raw Argo CD notification triggers.
  triggers:
    on-deployed:
      - when: app.status.operationState.phase in ['Succeeded']
        send: [on-deployed]
    on-health-degraded:
      - when: app.status.health.status == 'Degraded'
        send: [on-health-degraded]
    on-sync-failed:
      - when: app.status.operationState.phase in ['Error', 'Failed']
        send: [on-sync-failed]

  # Which service to route each trigger to.
  subscriptions:
    - trigger: on-deployed
      service: discord-platform
    - trigger: on-health-degraded
      service: discord-platform
    - trigger: on-sync-failed
      service: discord-platform
```

**Composition generates:**
- Patches to `argocd-notifications-cm` ConfigMap (services, templates, triggers)
- Patches to `argocd-notifications-secret` Secret (webhook URLs, tokens)
- Annotation templates for Applications to subscribe to triggers

### Engine 2: Agent Lifecycle (standalone, not Argo CD)

For events NOT tied to Argo CD — OAuth expiry, Kelos Task auth failures,
agent errors, watchdog alerts. Runs as a CronJob that checks k8s state
and posts to notification channels directly.

```yaml
apiVersion: open-warren.io/v1alpha1
kind: XNotification
metadata:
  name: agent-watchdog
spec:
  engine: agent-lifecycle

  channel:
    type: discord                    # discord | slack | webhook
    discord:
      webhookSecretRef:
        name: discord-webhook
        key: url
    # Slack example:
    # slack:
    #   tokenSecretRef: {name: slack-token, key: token}
    #   channel: "#platform-alerts"
    # Generic webhook example:
    # webhook:
    #   url: https://hooks.example.com/notify
    #   headers:
    #     Authorization: "Bearer {{secretRef:webhook-token:token}}"

  # What to watch for
  checks:
    oauthExpiry:
      enabled: true
      alertDays: 5
      secretRef:
        name: claude-code-oauth
        namespace: kelos-system
        annotationKey: kelos.dev/oauth-expires-at
    taskAuthFailure:
      enabled: true
      namespace: kelos-system
      # Patterns to match in Task .status.message
      patterns: ["401", "Unauthorized", "invalid_token", "auth"]

  schedule: "0 */6 * * *"
```

**Composition generates:**
- 1 CronJob (checks each enabled condition, posts to channel)
- 1 ServiceAccount + ClusterRole + ClusterRoleBinding
- Secret volume mounts for the channel credentials

---

## CRD: `XPreviewEnvironment`

### Trigger mode: label-gated vs any-PR

```yaml
apiVersion: open-warren.io/v1alpha1
kind: XPreviewEnvironment
metadata:
  name: salessage-preview
spec:
  repoRef:
    name: salessage

  # ── Trigger ──────────────────────────────────────────────
  # Which PRs get a preview environment.
  trigger:
    mode: label                      # label | all-prs
    label: preview                   # only when mode: label
    # mode: all-prs creates a preview for every open PR.
    # Use with limits.maxConcurrent to avoid resource exhaustion.

  # ── Chart Sources ────────────────────────────────────────
  # One or more Helm charts to deploy per preview namespace.
  # Each source becomes its own Argo CD Application, all sharing
  # the same namespace. This supports multi-service previews
  # (e.g., frontend + backend + worker from different paths or repos).
  sources:
    - name: app                      # unique within this claim
      # Option A: chart in the PR's own repo (most common)
      repoURL: https://github.com/example-org/SalesSage.git
      path: chart                    # chart directory in the repo
      targetRevision: "{{.head_sha}}"  # tracks the PR's head commit
      # Helm values injected by the ApplicationSet.
      # Uses Go template with access to PR metadata:
      #   {{.number}}, {{.head_sha}}, {{.branch}}, {{.slug}}
      valuesTemplate:
        image:
          repository: "ghcr.io/example-org/salessage"
          tag: "sha-{{.head_sha}}"
        ingress:
          enabled: true
          className: "{{.ingressClass}}"
          hosts:
            - host: "{{.slug}}-{{.number}}.{{.domain}}"
              paths:
                - path: /
                  pathType: Prefix
        fullnameOverride: "{{.slug}}-{{.number}}"

    # Option B: chart from a DIFFERENT repo (e.g., shared infra chart)
    - name: monitoring
      repoURL: https://github.com/example-org/shared-charts.git
      path: charts/preview-monitoring
      targetRevision: main           # pinned to main, not PR SHA
      valuesTemplate:
        namespace: "preview-{{.slug}}-{{.number}}"

    # Option C: chart from a Helm registry
    - name: redis
      repoURL: https://charts.bitnami.com/bitnami
      chart: redis                   # Helm chart name (not path)
      targetRevision: "18.x"
      valuesTemplate:
        auth:
          enabled: false
        master:
          resources:
            requests: {cpu: 50m, memory: 64Mi}

  # ── Namespace ────────────────────────────────────────────
  namespace:
    # Naming: {prefix}-{slug}-{N}
    prefix: preview
    # Labels applied to the auto-created namespace.
    # ClusterExternalSecrets match on these to fan in secrets.
    labels:
      preview: "true"
    # Additional annotations (e.g., for Linkerd injection, Istio sidecar)
    annotations: {}

  # ── Networking ───────────────────────────────────────────
  domain: preview.example.com      # wildcard DNS must be configured
  ingressClass: cloudflare-tunnel    # the chart's Ingress uses this
  # For internal/LAN access (separate from external):
  internalDomain: preview.example.internal  # optional
  internalIngressClass: traefik             # optional

  # ── Secrets ──────────────────────────────────────────────
  # Preview environments assume the Helm chart handles ALL secret
  # consumption. The chart declares which Secrets it mounts (envFrom,
  # volumeMounts, imagePullSecrets) and the user's secret manager
  # (ESO, Vault CSI, SOPS, raw k8s Secrets) provisions them into
  # the namespace. The XRD does NOT manage secrets — it only labels
  # the namespace so ClusterExternalSecrets (or equivalent) can match.
  #
  # Common pattern: a ClusterExternalSecret with
  #   namespaceSelector.matchLabels: {preview: "true"}
  # fans shared secrets into every preview namespace. The chart
  # references them by name (e.g., envFrom: [{secretRef: {name: app-shared-secrets}}]).
  secrets:
    namespaceLabels:
      preview: "true"              # labels the namespace; secret manager matches on these
    # Document which Secrets the chart expects to find in the namespace.
    # This is informational — the XRD does not create these Secrets.
    expectedSecrets:
      - name: app-shared-secrets
        description: "Shared env vars (API keys, auth tokens). Provisioned by ClusterExternalSecret."
      - name: ghcr-pull-secret
        description: "Container registry pull credentials. Provisioned by ClusterExternalSecret."

  # ── Image ────────────────────────────────────────────────
  image:
    # Tag template with access to PR metadata.
    # Default: sha-{{.head_sha}}
    tagTemplate: "sha-{{.head_sha}}"
    # Registry prefix. Used in the default valuesTemplate.
    registryPrefix: "ghcr.io"

  # ── CI Gate ──────────────────────────────────────────────
  ciGate:
    enabled: true
    # When enabled, the Composition generates an Argo Events Sensor
    # that waits for ci-success + image-ready before force-syncing
    # the Application. Without this, Argo CD auto-syncs on poll
    # (may hit ImagePullBackOff until the build finishes).
    commitStatusContext: ci/preview-build
    registryPushEndpoint: /registry/push

  # ── Reaper ───────────────────────────────────────────────
  reaper:
    enabled: true
    schedule: "*/15 * * * *"

  # ── Limits ───────────────────────────────────────────────
  limits:
    maxConcurrent: 5                 # max preview namespaces per repo
    maxAgeDays: 7                    # reaper deletes after N days
                                     # even if PR is still open

  # ── Argo CD AppProject scope ─────────────────────────────
  appProject:
    allowedNamespacePattern: "preview-*"
    # Cluster-scoped resources the chart is NOT allowed to create.
    # Default blacklist: ResourceQuota, NetworkPolicy, RBAC.
    namespaceResourceBlacklist:
      - {group: "", kind: ResourceQuota}
      - {group: "networking.k8s.io", kind: NetworkPolicy}
      - {group: "rbac.authorization.k8s.io", kind: "*"}
```

**What the Composition generates per XPreviewEnvironment:**
- 1 AppProject `{slug}-previews`
- 1 ApplicationSet with `matrix(list × pullRequest)` generator
  - N Applications per open PR (one per `sources[]` entry, all in the
    same namespace)
- 1 CronJob `{slug}-reaper` (label-based orphan cleanup + age check)
- 1 Sensor `{slug}-preview-deploy` (if `ciGate.enabled`)
- RBAC (ServiceAccount + ClusterRole + ClusterRoleBinding for reaper)

### Chart source documentation requirements

Each chart listed in `sources[]` must document:

| Requirement | How the XRD enforces it |
|---|---|
| Chart location (path or chart name) | `sources[].path` or `sources[].chart` — user specifies |
| Repo URL | `sources[].repoURL` — user specifies |
| Target revision | `sources[].targetRevision` — user specifies (`{{.head_sha}}` for PR tracking, branch/tag for pinned deps) |
| Values contract | `sources[].valuesTemplate` — user defines exactly which values the ApplicationSet overrides |
| What the chart MUST NOT create | `appProject.namespaceResourceBlacklist` enforces at Argo CD level |

The chart source is fully user-defined — no convention enforcement
beyond what the AppProject blacklists. Users can deploy any chart
from any repo with any values structure.

### Multi-chart namespace sharing

When `sources[]` has N entries, the Composition generates N Argo CD
Applications, all targeting the same namespace
(`{prefix}-{slug}-{number}`). Argo CD reconciles them independently
but they share:
- The namespace (created by the first Application's `CreateNamespace=true`)
- `managedNamespaceMetadata` labels (applied by whichever syncs first)
- Secrets (fanned in by ClusterExternalSecrets based on labels)

Ordering between charts (e.g., "database before app") is handled by
Argo CD sync-waves within each chart, NOT by the XRD. The XRD is
order-agnostic.

### Zero SaaS requirement

The entire preview system runs without external services:

| Concern | SaaS option | Self-hosted option |
|---|---|---|
| Container registry | GHCR | Zot, distribution, Harbor |
| DNS | Cloudflare | CoreDNS + ExternalDNS (k8s-internal) |
| Ingress | Cloudflare tunnel | Traefik, Nginx, Istio gateway |
| TLS | Cloudflare origin cert | cert-manager + Let's Encrypt / self-signed |
| Secrets | Vault Cloud | OpenBao, Vault OSS, raw k8s Secrets |
| CI | GitHub Actions | Tekton, Drone, Woodpecker, Jenkins |

A kind/k3d dev cluster with a local registry (`localhost:5000`) is a
first-class deployment target. The `getting-started.md` doc includes
a local-only quickstart.

---

## Dependency map

```
XAgentRepo "salessage"
  │
  ├── generates: Kelos Workspace
  ├── palette (inline, if enabled)
  │     ├── generates: Sensor (palette-init)
  │     ├── generates: AgentConfig (palette-updater)
  │     └── generates: TaskSpawner (palette-updater, maxConc:1)
  │
  ├── references:
  │     XAgent "salessage-reviewer"     (repoRef → salessage)
  │     XAgent "salessage-ci-fixer"     (repoRef → salessage)
  │     XAgent "org-explainer"          (no repoRef, org-wide)
  │     XAgent "org-help"               (no repoRef, org-wide)
  │
  └── references:
        XNotification "argocd-discord"       (engine: argocd)
        XNotification "agent-watchdog"       (engine: agent-lifecycle)

XAgent "salessage-reviewer"
  ├── generates: Kelos AgentConfig
  └── generates: Kelos TaskSpawner (polling)

XAgent "salessage-ci-fixer"
  ├── generates: Kelos AgentConfig
  └── generates: Kelos TaskSpawner (polling)

XAgent "org-explainer"
  ├── generates: Kelos AgentConfig
  └── generates: Argo Events Sensor (event-driven, rateLimit)

XAgent "org-help"
  └── generates: Argo Events Sensor → Job (static reply, no LLM)

XNotification "argocd-discord"
  └── generates: patches to argocd-notifications-cm + secret

XNotification "agent-watchdog"
  ├── generates: CronJob (checks OAuth expiry + Task auth failures)
  └── generates: RBAC (SA + ClusterRole + Binding)

XPreviewEnvironment "salessage-preview"
  ├── generates: Argo CD AppProject
  ├── generates: Argo CD ApplicationSet (N Applications per source per PR)
  ├── generates: CronJob (reaper)
  ├── generates: Sensor (preview-deploy, if ciGate.enabled)
  └── generates: RBAC
```

All resources created by Compositions use provider-kubernetes Objects.
Deleting the XR claim cascades to all owned Objects.

---

## What ships in the open-source package

```
open-warren/
├── platform/
│   ├── xrd/
│   │   ├── agentrepo.cue                # XAgentRepo XRD
│   │   ├── agent.cue                    # XAgent XRD
│   │   ├── notification.cue             # XNotification XRD
│   │   └── previewenvironment.cue       # XPreviewEnvironment XRD
│   ├── compositions/
│   │   ├── agentrepo.cue                # Workspace + palette
│   │   ├── agent-reviewer.cue           # reviewer AgentConfig + TaskSpawner
│   │   ├── agent-cifixer.cue            # ci-fixer AgentConfig + TaskSpawner
│   │   ├── agent-explainer.cue          # explainer AgentConfig + Sensor
│   │   ├── agent-help.cue              # help Sensor (static reply Job)
│   │   ├── notification-argocd.cue      # Argo CD notification config patches
│   │   ├── notification-lifecycle.cue   # agent lifecycle watchdog CronJob
│   │   └── previewenvironment.cue       # ApplicationSet + AppProject + reaper
│   └── templates/
│       ├── reviewer.md                  # default reviewer agentsMD
│       ├── ci-fixer.md                  # default ci-fixer agentsMD
│       ├── explainer.md                 # default explainer agentsMD
│       ├── palette-updater.md           # default palette-updater agentsMD
│       ├── help-reply.md               # static /help reply template
│       └── palette-initial.md           # initial palette comment template
├── ci/
│   ├── github/
│   │   ├── autofix-dispatcher.yaml      # GH Actions (user copies to repo)
│   │   ├── autofix-dispatch.sh
│   │   ├── preview-build.yaml           # image build workflow template
│   │   └── stack-label.yaml             # stacked PR label manager
│   └── tekton/                          # future: Tekton equivalents
├── docs/
│   ├── getting-started.md               # includes local-only kind quickstart
│   ├── crd-reference.md
│   ├── repo-setup-guide.md              # what to add to your app repo
│   ├── architecture.md
│   ├── preview-env-design.md
│   └── local-development.md             # kind + local registry + self-signed TLS
├── examples/
│   ├── full/                            # all features enabled
│   │   ├── repo.yaml                    # XAgentRepo
│   │   ├── agents.yaml                  # 4 XAgent claims (2 repo-scoped, 2 org-wide)
│   │   ├── notifications.yaml           # 2 XNotifications (argocd + lifecycle)
│   │   └── preview.yaml                 # XPreviewEnvironment (multi-source)
│   ├── minimal/                         # just /review + /explain, no preview
│   │   ├── repo.yaml
│   │   └── agents.yaml
│   └── local-kind/                      # runs entirely in kind + local registry
│       ├── kind-config.yaml
│       ├── setup.sh                     # installs Crossplane, Kelos, Argo stack
│       ├── repo.yaml
│       └── agents.yaml
├── install/
│   ├── crds.yaml                        # all XRDs rendered
│   ├── compositions.yaml                # all Compositions rendered
│   └── prerequisites.md
└── README.md
```

---

## Installation flows

### Production (self-hosted cluster)

```bash
# 1. Prerequisites
kelos install
helm install argo-events argo/argo-events -n argo-events
helm install argocd argo/argo-cd -n argocd
# Crossplane + provider-kubernetes assumed already present

# 2. Install open-warren XRDs + Compositions
kubectl apply -f https://github.com/example-org/open-warren/releases/latest/download/crds.yaml
kubectl apply -f https://github.com/example-org/open-warren/releases/latest/download/compositions.yaml

# 3. Create secrets
kubectl create secret generic github-pat -n open-warren-system ...
kubectl create secret generic claude-code-oauth -n open-warren-system ...

# 4. Apply claims
kubectl apply -f examples/full/

# 5. Copy CI workflows to your app repo
cp ci/github/* <your-repo>/.github/workflows/
cp ci/github/autofix-dispatch.sh <your-repo>/ci/scripts/

# 6. Configure org webhook → EventSource endpoint

# 7. Post /review on a PR.
```

### Local development (kind + zero SaaS)

```bash
# One-shot setup — installs kind, Crossplane, Kelos, Argo stack,
# local registry at localhost:5000, self-signed TLS.
cd examples/local-kind
./setup.sh

# Apply the local example (uses localhost registry, traefik ingress,
# no Cloudflare, no GHCR, nip.io DNS for *.127.0.0.1.nip.io).
kubectl apply -f repo.yaml -f agents.yaml

# Test: push to a local gitea/forgejo instance (installed by setup.sh),
# post /review on a PR, watch the agent respond.
```

---

## What's extracted from example-org/k8-infra vs new

| Component | Source | Parameterize |
|---|---|---|
| Agent prompt templates | `composites/preview/kelos.cue` agentsMD blocks | repo/slug, ciCommands, trigger phrases |
| Sensor filters + triggers | `composites/preview/argoevents.cue` | org filter, repo name, endpoint, rateLimit |
| ApplicationSet template | `composites/preview/argocd.cue` | domain, ingressClass, chartPath, sources[], valuesTemplate |
| Reaper script | `composites/preview/cronjobs.cue` | Already generic (label-based) |
| Watchdog script | `composites/preview/cronjobs.cue` | notification channel type, secretRef |
| Autofix dispatcher | `.github/workflows/` + `ci/scripts/` | Already generic ($REPO, $SHA, $PR) |
| XRD patterns | `platform/xrd/*.cue` | Follow existing conventions |
| Composition patterns | `platform/compositions/*.cue` | Follow patch-and-transform pipeline |
| Notification engine | `composites/preview/helmreleases.cue` (argocd config) | Services, templates, triggers — user-defined |

## Quiet hours (LLM quota protection)

The k8-infra implementation includes a quiet-hours mechanism to pause
LLM-consuming agents during the operator's active work hours (weekday
8am-2pm ET, configurable). Claude Pro/Max session quota is shared across
interactive and automated usage, so letting agents run during interactive
work burns through the quota fast.

**Mechanism** (simple, scale-based):
- 2 CronJobs with `spec.timeZone: America/New_York` (K8s 1.25+):
  `quiet-hours-enter` at 8am, `quiet-hours-exit` at 2pm, weekdays
- Each CronJob runs a script that:
  - Patches LLM-related TaskSpawners (`spec.suspend: true/false`),
    skipping any annotated `open-warren.io/always-on=true`
  - Patches LLM-creating Sensors (`spec.replicas: 0/1`) by name allowlist
- Global override via ConfigMap `open-warren-quiet-hours` (set
  `data.disabled=true` to disable the feature)

**Covered resources:**
- TaskSpawners that create LLM Tasks (all of them except those marked
  always-on)
- Sensors whose triggers create Kelos Tasks (feature-ideator,
  feature-implementer, feature-review-tier1, feature-review-orchestrator,
  code-explain)

**NOT covered** (don't burn LLM quota, stay running):
- Sensors that create Jobs (branch-create, human-resume, palette-init,
  slash-help, preview-deploy)
- Watchdog + reaper CronJobs

### As an XRD: `XQuietHours` (v2 spec)

```yaml
apiVersion: open-warren.io/v1alpha1
kind: XQuietHours
metadata:
  name: platform-quiet-hours
spec:
  schedule:
    timeZone: America/New_York
    enterCron: "0 8 * * 1-5"          # 8am weekdays
    exitCron:  "0 14 * * 1-5"         # 2pm weekdays
  targets:
    taskSpawners:
      namespaces: [kelos-system]
      # All in namespace unless annotated always-on.
    sensors:
      namespace: argo-events
      names:                          # explicit allowlist
        - feature-ideator
        - feature-implementer
        - feature-review-tier1
        - feature-review-orchestrator
        - code-explain
  bypass:
    # Annotation on any target resource excludes it from suspension.
    alwaysOnAnnotation: open-warren.io/always-on
    # ConfigMap for global disable. When data.disabled="true",
    # CronJobs exit early with no action.
    globalDisableConfigMap:
      name: open-warren-quiet-hours
      namespace: kelos-system
```

**Composition generates:** 2 CronJobs, 1 ServiceAccount, 1 ClusterRole
(taskspawner+sensor patch + configmap get), 1 ClusterRoleBinding, 1
initial ConfigMap with `disabled: "false"`.

**Known limitation:** per-PR bypass (e.g., `urgent` label) not supported
with scale-to-0 mechanism — scaled Sensor can't evaluate events at all.
Workarounds: manual kubectl unsuspend, or global disable ConfigMap.

## v1.0 scope

**In scope:**
- 4 XRDs: XAgentRepo, XAgent, XNotification, XPreviewEnvironment
- 5 agent types: reviewer, ci-fixer, explainer, help, palette-updater
- 2 notification engines: Argo CD + standalone lifecycle watchdog
- Multi-source preview environments with label or all-PR trigger
- CI workflow templates (GitHub Actions; Tekton in v2)
- Local kind quickstart (zero SaaS)
- Docs: getting-started, CRD reference, repo setup guide, architecture

**In scope for k8-infra (example-org) deployment, not yet XRD-ized:**
- Quiet hours — currently implemented as raw CronJobs + script in
  k8-infra. XQuietHours XRD is v2.

**Out of scope for v1.0:**
- GitLab CI / Bitbucket Pipelines dispatcher templates
- Tekton pipeline equivalents of the GH Actions dispatcher
- Custom agent types beyond the built-in 5
- Web UI / dashboard
- Multi-cluster (hub-spoke) preview routing
- Automatic GitHub/Gitea webhook configuration
- SonarQube / Semgrep as built-in agent types
- XQuietHours XRD (v2)
- Per-PR `urgent` label bypass during quiet hours (requires Kyverno
  admission policy OR dual-Sensor setup; deferred to v2)
