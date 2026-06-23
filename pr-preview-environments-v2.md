# PR Preview Environments with AI-Driven Code Agents

## Architecture: Argo CD + Argo Events + Kelos on Kubernetes

**Version 2.0** — Updated April 2026

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture Diagram](#architecture-diagram)
3. [CRD Inventory](#crd-inventory)
4. [Prerequisites](#prerequisites)
5. [Component 1: Argo Events — Event Bridge](#component-1-argo-events--event-bridge)
   - [EventBus](#eventbus)
   - [EventSource: GitHub Webhooks](#eventsource-github-webhooks)
   - [EventSource: Container Registry](#eventsource-container-registry)
   - [Sensor: CI Complete + Image Ready → Sync Preview](#sensor-ci-complete--image-ready--sync-preview)
   - [Sensor: Preview Healthy → Spawn Agent](#sensor-preview-healthy--spawn-agent)
6. [Component 2: CI Pipeline](#component-2-ci-pipeline)
   - [GitHub Actions Workflow](#github-actions-workflow)
   - [Container Registry Authentication](#container-registry-authentication)
7. [Component 3: Argo CD Preview Lifecycle](#component-3-argo-cd-preview-lifecycle)
   - [AppProject](#appproject)
   - [ApplicationSet](#applicationset)
   - [Preview Helm Chart Structure](#preview-helm-chart-structure)
   - [Sync Waves](#sync-waves)
   - [Health Probes](#health-probes)
   - [Migration Job Configuration](#migration-job-configuration)
   - [Wildcard DNS and TLS](#wildcard-dns-and-tls)
   - [Namespace Cleanup](#namespace-cleanup)
8. [Component 4: Kelos AI Agent Layer](#component-4-kelos-ai-agent-layer)
   - [Installation](#installation)
   - [Workspace](#workspace)
   - [AgentConfig: Fixer Agent](#agentconfig-fixer-agent)
   - [AgentConfig: Security Reviewer](#agentconfig-security-reviewer)
   - [AgentConfig: QA Reviewer](#agentconfig-qa-reviewer)
   - [AgentConfig: Dev Reviewer](#agentconfig-dev-reviewer)
   - [TaskSpawner: Auto-Trigger on PR](#taskspawner-auto-trigger-on-pr)
   - [TaskSpawner: On-Demand Fixer](#taskspawner-on-demand-fixer)
   - [TaskSpawner: Security Review](#taskspawner-security-review)
   - [TaskSpawner: QA Review](#taskspawner-qa-review)
   - [TaskSpawner: Dev Review](#taskspawner-dev-review)
   - [Per-PR Task Deduplication](#per-pr-task-deduplication)
9. [RBAC and Security](#rbac-and-security)
   - [Argo CD AppProject Restrictions](#argo-cd-appproject-restrictions)
   - [Preview Namespace RBAC for AI Agent](#preview-namespace-rbac-for-ai-agent)
   - [NetworkPolicy for Agent Pods](#networkpolicy-for-agent-pods)
   - [NetworkPolicy for Preview Namespaces](#networkpolicy-for-preview-namespaces)
10. [Resource Governance](#resource-governance)
    - [Per-Namespace Quotas](#per-namespace-quotas)
    - [Cluster-Level Namespace Cap](#cluster-level-namespace-cap)
    - [AI Agent Cost Controls](#ai-agent-cost-controls)
11. [Observability](#observability)
12. [Argo CD Notifications](#argo-cd-notifications)
13. [Secrets Management](#secrets-management)
14. [Operations Runbook](#operations-runbook)
15. [Known Gotchas](#known-gotchas)
16. [Implementation Order](#implementation-order)
17. [Appendix: Full Manifest Reference](#appendix-full-manifest-reference)

---

## Overview

This document describes a system for automatically creating isolated, per-PR preview environments in Kubernetes, with multiple AI coding agents that watch for PR activity, inspect the running preview, fix issues autonomously, and perform security, QA, and code reviews on demand.

The system is composed of three planes, all defined as Kubernetes CRDs:

| Plane | Tools | Responsibility |
|---|---|---|
| **Event Plane** | Argo Events | Webhook reception, event correlation, sequencing CI→CD→Agent |
| **Runtime Plane** | Argo CD ApplicationSet | Namespace lifecycle, app deployment, infrastructure provisioning, drift reconciliation, teardown |
| **AI Plane** | Kelos | Spawns ephemeral Claude Code agent pods per PR, multiple agent personas (fixer, security, QA, dev review) |

### Design Principles

- **Everything is a CRD.** No custom controllers, no imperative scripts, no GitHub Actions as the orchestrator. All configuration is declarative YAML in Git.
- **Webhook-driven, not polling.** Argo Events receives GitHub webhooks and container registry events, eliminating the image race condition and reducing latency from minutes to seconds.
- **Per-preview infrastructure.** Each PR gets its own PostgreSQL, Redis, and app deployment — full isolation.
- **Multi-agent personas.** Separate AgentConfigs for fixing, security review, QA review, and code review. Triggered by `@agent <type>` comments.
- **Per-PR deduplication.** Label-based locking prevents multiple agents from running simultaneously on the same PR.

### What Changed from v1

| Problem | v1 (Argo CD + Kelos only) | v2 (+ Argo Events) |
|---|---|---|
| Image race condition | Argo CD syncs before CI builds image → ImagePullBackOff | Argo Events waits for both CI success AND image push before triggering sync |
| Namespace race | Kelos spawns agent before namespace exists | Argo Events chains: preview healthy → then spawn agent |
| CI/CD disconnect | Polling-only, no event bridge | Webhook-driven end-to-end |
| Single agent persona | One AgentConfig for all tasks | Four personas: fixer, security, QA, dev review |
| No CI pipeline defined | Image tag referenced but no build workflow | Full GitHub Actions workflow included |
| No health probes | Argo CD health assessment unreliable | Readiness, liveness, and startup probes defined |
| No migration failure handling | Broken migrations block preview with no recovery | Hook-delete-policy + agent prompt guidance |
| No registry auth | ImagePullBackOff from missing pull secrets | External Secrets for pull secret distribution |
| No operations runbook | No documented emergency procedures | Full runbook section |

### What This System Does NOT Include

- End-to-end testing automation
- vCluster-based isolation
- Branch deploys for non-PR branches
- Seed data provisioning

---

## Architecture Diagram

```
Developer pushes to PR branch
    │
    ▼
GitHub Webhook ──────────────────────────────────────────────────┐
    │                                                             │
    ├──► GitHub Actions (CI)                                      │
    │     ├── Build container image                               │
    │     ├── Push to GHCR: pr-{n}-{sha}                         │
    │     └── POST webhook to Argo Events ◄── image pushed        │
    │                                                             │
    ▼                                                             │
Argo Events                                                       │
    │                                                             │
    ├── EventSource: github-webhook (PR events)                   │
    ├── EventSource: container-registry (image push)              │
    │                                                             │
    ├── Sensor: "ci-success AND image-exists"                     │
    │     └── Trigger: argocd app sync preview-pr-{n}             │
    │           │                                                 │
    │           ▼                                                 │
    │     Argo CD ApplicationSet                                  │
    │       ├── Creates preview-pr-{n} namespace                  │
    │       ├── Wave 1: PostgreSQL + Redis + RBAC                 │
    │       ├── Wave 2: Migration Job                             │
    │       └── Wave 3: App Deployment + Ingress                  │
    │           │                                                 │
    │           ▼                                                 │
    │     Preview live at pr-{n}.preview.yourdomain.com           │
    │                                                             │
    └── Sensor: "argocd-app-healthy"                              │
          └── Trigger: kubectl apply Kelos Task                   │
                │                                                 │
                ▼                                                 │
          Kelos TaskSpawner                                       │
            ├── Auto-trigger: review + fix                        │
            ├── @agent fix ...  → Fixer agent                     │
            ├── @agent security → Security reviewer               │
            ├── @agent qa       → QA reviewer                     │
            └── @agent review   → Dev reviewer                    │
                │                                                 │
                ▼                                                 │
          Claude Code in ephemeral Pod                             │
            ├── Reads code + diff                                 │
            ├── kubectl get pods/logs (preview ns)                │
            ├── Runs tests, fixes issues                          │
            ├── git commit + push                                 │
            └── gh pr comment ──────────────────────────────────┘
                                                    (triggers new cycle)
```

---

## CRD Inventory

Every component in this system is a Kubernetes CRD. Zero imperative scripts.

| CRD | Count | Tool | Purpose |
|---|---|---|---|
| `EventBus` | 1 | Argo Events | NATS-backed event transport |
| `EventSource` | 2 | Argo Events | GitHub webhook + container registry receiver |
| `Sensor` | 2 | Argo Events | Multi-event conditions + triggers |
| `AppProject` | 1 | Argo CD | Scoped project for previews |
| `ApplicationSet` | 1 | Argo CD | PR → Application generator |
| `Workspace` | 1 | Kelos | Repo + GitHub credentials |
| `AgentConfig` | 4 | Kelos | Fixer, Security, QA, Dev review personas |
| `TaskSpawner` | 5 | Kelos | Auto-trigger + 4 comment-triggered spawners |
| `ClusterPolicy` | 1 | Kyverno | Namespace cap |
| `Certificate` | 1 | cert-manager | Wildcard TLS |
| `ClusterSecretStore` | 1 | External Secrets | Vault/SSM backend |
| **Total** | **20** | | **All declarative, all in Git** |

---

## Prerequisites

| Requirement | Minimum Version | Notes |
|---|---|---|
| Kubernetes cluster | 1.28+ | |
| Argo CD | 2.9+ | ApplicationSet controller included |
| Argo Events | 1.9+ | EventSource, Sensor, EventBus CRDs |
| Kelos | 0.19+ | `githubPullRequests` TaskSpawner source |
| cert-manager | 1.13+ | For wildcard TLS |
| CloudNativePG | 1.22+ | Per-preview PostgreSQL |
| Ingress controller | Any (NGINX, Traefik) | Must support wildcard hosts |
| Kyverno | 1.11+ | Namespace cap policy |
| External Secrets Operator | 0.9+ | Registry pull secrets + app secrets |
| GitHub fine-grained PAT | — | Scoped: `contents:write`, `pull_requests:write`, `issues:write` |
| Anthropic API key | — | For Claude Code agent |
| Container registry | GHCR, ECR, etc. | Must support webhook notifications |
| StorageClass | — | `reclaimPolicy: Delete` for preview PVCs |

---

## Component 1: Argo Events — Event Bridge

Argo Events eliminates polling by receiving GitHub webhooks and container registry events, correlating them, and triggering downstream actions only when all preconditions are met.

### EventBus

The transport layer for event delivery. NATS is the default and recommended backend.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventBus
metadata:
  name: default
  namespace: argo-events
spec:
  nats:
    native:
      replicas: 3
      auth: token
```

### EventSource: GitHub Webhooks

Receives PR events and CI status updates directly from GitHub.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: github-webhook
  namespace: argo-events
spec:
  service:
    ports:
      - port: 12000
        targetPort: 12000
  github:
    pr-events:
      repositories:
        - owner: your-org
          names:
            - your-app
      webhook:
        endpoint: /github/pr
        port: "12000"
        method: POST
        url: https://events.yourdomain.com
      events:
        - pull_request
        - issue_comment
        - status
      apiToken:
        name: github-webhook-secret
        key: token
      webhookSecret:
        name: github-webhook-secret
        key: webhook-secret
      insecure: false
      active: true
      contentType: json
```

### EventSource: Container Registry

Receives push events from your container registry (GHCR, Harbor, etc.).

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: container-registry
  namespace: argo-events
spec:
  webhook:
    image-push:
      endpoint: /registry/push
      port: "13000"
      method: POST
```

**Note:** GHCR does not natively support webhooks. Two options:

1. **CI-driven:** GitHub Actions POSTs to this webhook endpoint after `docker push` succeeds (recommended, simplest).
2. **Harbor/custom registry:** Native webhook support for push events.

### Sensor: CI Complete + Image Ready → Sync Preview

This is the core fix for the image race condition. The Sensor requires BOTH CI completion AND image availability before triggering an Argo CD sync.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: preview-deploy
  namespace: argo-events
spec:
  dependencies:
    - name: ci-success
      eventSourceName: github-webhook
      eventName: pr-events
      filters:
        data:
          # Only trigger on successful CI status checks
          - path: body.state
            type: string
            value:
              - "success"
          - path: body.context
            type: string
            value:
              - "ci/preview-build"
    - name: image-ready
      eventSourceName: container-registry
      eventName: image-push
      filters:
        data:
          - path: body.repository
            type: string
            value:
              - "your-org/your-app"

  triggers:
    - template:
        conditions: "ci-success && image-ready"
        name: sync-preview
        k8s:
          operation: create
          source:
            resource:
              apiVersion: batch/v1
              kind: Job
              metadata:
                generateName: sync-preview-
                namespace: argo-events
              spec:
                template:
                  spec:
                    serviceAccountName: argo-events-sa
                    containers:
                      - name: sync
                        image: quay.io/argoproj/argocd:v2.13.2
                        command:
                          - /bin/sh
                          - -c
                          - |
                            PR_NUMBER=$(echo '${{.Input.body}}' | jq -r '.number // .pull_request.number // empty')
                            if [ -n "$PR_NUMBER" ]; then
                              argocd login $ARGOCD_SERVER --auth-token $ARGOCD_TOKEN --grpc-web
                              APP_NAME=$(argocd app list -o name | grep "pr-${PR_NUMBER}" | head -1)
                              if [ -n "$APP_NAME" ]; then
                                argocd app sync "$APP_NAME" --force --async
                              fi
                            fi
                        env:
                          - name: ARGOCD_SERVER
                            value: argocd-server.argocd.svc.cluster.local
                          - name: ARGOCD_TOKEN
                            valueFrom:
                              secretKeyRef:
                                name: argocd-ci-token
                                key: token
                    restartPolicy: Never
                backoffLimit: 2
```

### Sensor: Preview Healthy → Spawn Agent

Chains agent spawning to preview readiness, solving the namespace race condition.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: preview-agent-trigger
  namespace: argo-events
spec:
  dependencies:
    - name: pr-opened
      eventSourceName: github-webhook
      eventName: pr-events
      filters:
        data:
          - path: body.action
            type: string
            value:
              - "opened"
              - "synchronize"
          - path: body.pull_request.draft
            type: bool
            value:
              - "false"
          - path: body.pull_request.labels.#(name=="ai-review").name
            type: string
            value:
              - "ai-review"

  triggers:
    - template:
        name: wait-and-spawn-agent
        k8s:
          operation: create
          source:
            resource:
              apiVersion: batch/v1
              kind: Job
              metadata:
                generateName: spawn-agent-
                namespace: argo-events
              spec:
                template:
                  spec:
                    serviceAccountName: argo-events-sa
                    containers:
                      - name: wait-and-spawn
                        image: bitnami/kubectl:latest
                        command:
                          - /bin/sh
                          - -c
                          - |
                            PR_NUMBER=$(echo '${{.Input.body}}' | jq -r '.pull_request.number')
                            NS="preview-pr-${PR_NUMBER}"
                            
                            # Wait for namespace + healthy app (max 10 min)
                            for i in $(seq 1 60); do
                              if kubectl get ns "$NS" 2>/dev/null; then
                                HEALTHY=$(kubectl get pods -n "$NS" -l app=your-app \
                                  -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
                                if [ "$HEALTHY" = "True" ]; then
                                  echo "Preview namespace $NS is healthy"
                                  break
                                fi
                              fi
                              echo "Waiting for preview... ($i/60)"
                              sleep 10
                            done
                            
                            # Kelos TaskSpawner handles agent creation from here
                            # This job just ensures the namespace exists before
                            # the TaskSpawner poll picks it up
                            echo "Preview ready for agent"
                    restartPolicy: Never
                backoffLimit: 1
```

---

## Component 2: CI Pipeline

### GitHub Actions Workflow

The CI pipeline builds the container image and notifies Argo Events when complete. This is the only component that runs outside Kubernetes.

```yaml
# .github/workflows/preview-build.yml
name: Preview Build
on:
  pull_request:
    types: [opened, synchronize, reopened]
    branches: [main]

concurrency:
  group: preview-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      statuses: write

    steps:
      - uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Login to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: |
            ghcr.io/${{ github.repository }}:pr-${{ github.event.pull_request.number }}-${{ github.event.pull_request.head.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Notify Argo Events — image pushed
        run: |
          curl -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${{ secrets.ARGO_EVENTS_TOKEN }}" \
            -d '{
              "repository": "${{ github.repository }}",
              "tag": "pr-${{ github.event.pull_request.number }}-${{ github.event.pull_request.head.sha }}",
              "pr_number": "${{ github.event.pull_request.number }}",
              "head_sha": "${{ github.event.pull_request.head.sha }}"
            }' \
            ${{ secrets.ARGO_EVENTS_WEBHOOK_URL }}/registry/push

      - name: Set commit status
        uses: actions/github-script@v7
        with:
          script: |
            await github.rest.repos.createCommitStatus({
              owner: context.repo.owner,
              repo: context.repo.repo,
              sha: context.payload.pull_request.head.sha,
              state: 'success',
              context: 'ci/preview-build',
              description: 'Image built and pushed successfully'
            });
```

**Key design decisions:**

- `concurrency.cancel-in-progress: true` — rapid commits cancel previous builds, preventing wasted CI minutes and duplicate image tags.
- The commit status `ci/preview-build` is what Argo Events' Sensor matches on.
- The curl to Argo Events webhook replaces GHCR's lack of native push webhooks.

### Container Registry Authentication

Each preview namespace needs `imagePullSecrets` to pull from GHCR. Use External Secrets Operator for automatic distribution.

```yaml
# ClusterExternalSecret — auto-provisions pull secrets into all preview-* namespaces
apiVersion: external-secrets.io/v1beta1
kind: ClusterExternalSecret
metadata:
  name: ghcr-pull-secret
spec:
  namespaceSelector:
    matchLabels:
      preview: "true"
  externalSecretSpec:
    refreshInterval: 1h
    secretStoreRef:
      name: vault-backend
      kind: ClusterSecretStore
    target:
      name: ghcr-pull-secret
      template:
        type: kubernetes.io/dockerconfigjson
        data:
          .dockerconfigjson: '{{ .dockerconfigjson }}'
    data:
      - secretKey: dockerconfigjson
        remoteRef:
          key: preview/ghcr-credentials
```

Reference in the Helm chart Deployment:

```yaml
# deploy/preview/templates/app-deployment.yaml
spec:
  template:
    spec:
      imagePullSecrets:
        - name: ghcr-pull-secret
```

---

## Component 3: Argo CD Preview Lifecycle

### AppProject

Lock down what preview Applications can do.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: previews
  namespace: argocd
spec:
  description: "PR preview environments — restricted scope"
  destinations:
    - namespace: 'preview-*'
      server: https://kubernetes.default.svc
  sourceRepos:
    - https://github.com/your-org/your-app.git
  clusterResourceWhitelist: []
  namespaceResourceBlacklist:
    - group: ''
      kind: ResourceQuota
    - group: networking.k8s.io
      kind: NetworkPolicy
    - group: rbac.authorization.k8s.io
      kind: '*'
```

### ApplicationSet

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: preview-envs
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - pullRequest:
        github:
          owner: your-org
          repo: your-app
          tokenRef:
            secretName: github-token
            key: token
          labels:
            - preview
        requeueAfterSeconds: 30

  template:
    metadata:
      name: 'preview-{{.branch_slug}}-pr-{{.number}}'
      labels:
        preview: "true"
        pr-number: '{{.number}}'
      annotations:
        notifications.argoproj.io/subscribe.on-deployed.github: ""
        notifications.argoproj.io/subscribe.on-health-degraded.github: ""
    spec:
      project: previews
      source:
        repoURL: https://github.com/your-org/your-app.git
        targetRevision: '{{.head_sha}}'
        path: deploy/preview
        helm:
          valuesObject:
            prNumber: '{{.number}}'
            image:
              repository: ghcr.io/your-org/your-app
              tag: 'pr-{{.number}}-{{.head_short_sha}}'
            ingress:
              host: 'pr-{{.number}}.preview.yourdomain.com'
            namespace: 'preview-pr-{{.number}}'
            database:
              name: 'preview_pr_{{.number}}'
            redis:
              enabled: true
      destination:
        server: https://kubernetes.default.svc
        namespace: 'preview-pr-{{.number}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
        retry:
          limit: 5
          backoff:
            duration: 30s
            factor: 2
            maxDuration: 5m
```

### Preview Helm Chart Structure

```
deploy/preview/
├── Chart.yaml
├── values.yaml
├── templates/
│   ├── app-deployment.yaml        # Application with health probes
│   ├── app-service.yaml
│   ├── app-ingress.yaml
│   ├── postgres-cluster.yaml      # CloudNativePG Cluster CR
│   ├── postgres-migration-job.yaml # With hook-delete-policy
│   ├── redis-deployment.yaml
│   ├── redis-service.yaml
│   ├── networkpolicy.yaml         # Isolation rules
│   ├── resourcequota.yaml         # Resource limits
│   ├── limitrange.yaml            # Per-pod defaults
│   └── ai-agent-rbac.yaml         # RBAC for Kelos agent access
```

### Sync Waves

```yaml
# Wave 1: Infrastructure
# postgres-cluster.yaml, redis-deployment.yaml, ai-agent-rbac.yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"

# Wave 2: Migrations
# postgres-migration-job.yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "2"

# Wave 3: Application
# app-deployment.yaml, app-service.yaml, app-ingress.yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "3"
```

### Health Probes

Without probes, Argo CD cannot accurately assess Application health, and the Argo Events Sensor for "preview healthy" will fire prematurely.

```yaml
# deploy/preview/templates/app-deployment.yaml
spec:
  template:
    spec:
      containers:
        - name: app
          image: '{{ .Values.image.repository }}:{{ .Values.image.tag }}'
          ports:
            - containerPort: 3000
          startupProbe:
            httpGet:
              path: /api/health
              port: 3000
            failureThreshold: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /api/health
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /api/health
              port: 3000
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 5
```

The `startupProbe` is critical — the app needs time to connect to the freshly-created PostgreSQL and run initial setup. Without it, the liveness probe kills the pod before it finishes starting.

### Migration Job Configuration

```yaml
# deploy/preview/templates/postgres-migration-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migration
  namespace: 'preview-pr-{{ .Values.prNumber }}'
  annotations:
    argocd.argoproj.io/sync-wave: "2"
    argocd.argoproj.io/hook: Sync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  activeDeadlineSeconds: 300   # 5 min max — fail fast
  backoffLimit: 2
  template:
    spec:
      containers:
        - name: migrate
          image: '{{ .Values.image.repository }}:{{ .Values.image.tag }}'
          command: ["npm", "run", "migrate"]
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: app-secrets
                  key: DATABASE_URL
      restartPolicy: Never
```

The `hook-delete-policy: BeforeHookCreation` ensures stale migration Jobs are cleaned up before each sync attempt.

### Wildcard DNS and TLS

```
*.preview.yourdomain.com  →  A  →  <ingress-controller-LB-IP>
```

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: preview-wildcard
  namespace: ingress-nginx
spec:
  secretName: preview-wildcard-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - "*.preview.yourdomain.com"
```

### Namespace Cleanup

Argo CD handles primary cleanup via `prune: true`. The reaper CronJob catches orphans:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: preview-reaper
  namespace: argocd
spec:
  schedule: "*/15 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: preview-reaper
          containers:
            - name: reaper
              image: bitnami/kubectl:latest
              command:
                - /bin/sh
                - -c
                - |
                  for ns in $(kubectl get ns -l preview=true -o jsonpath='{.items[*].metadata.name}'); do
                    pr_number=$(echo $ns | sed 's/preview-pr-//')
                    app_count=$(kubectl get applications -n argocd \
                      -l "pr-number=${pr_number}" --no-headers 2>/dev/null | wc -l)
                    if [ "$app_count" -eq 0 ]; then
                      echo "Orphaned namespace: $ns — deleting"
                      kubectl delete namespace "$ns"
                    fi
                  done
          restartPolicy: OnFailure
```

---

## Component 4: Kelos AI Agent Layer

### Installation

```bash
# Option A: CLI
go install github.com/kelos-dev/kelos/cmd/kelos@latest
kelos install

# Option B: Direct apply
kubectl apply -f https://raw.githubusercontent.com/kelos-dev/kelos/main/install.yaml
```

### Workspace

```yaml
apiVersion: kelos.dev/v1alpha1
kind: Workspace
metadata:
  name: your-app
  namespace: kelos-system
spec:
  repo: https://github.com/your-org/your-app.git
  ref: main
  secretRef:
    name: github-pat
---
apiVersion: v1
kind: Secret
metadata:
  name: github-pat
  namespace: kelos-system
type: Opaque
stringData:
  GITHUB_TOKEN: ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

### AgentConfig: Fixer Agent

The default agent that investigates preview health, diagnoses issues, and fixes code.

```yaml
apiVersion: kelos.dev/v1alpha1
kind: AgentConfig
metadata:
  name: fixer-agent
  namespace: kelos-system
spec:
  systemPrompt: |
    You are a senior DevOps-aware coding agent working on PR preview
    environments for a SaaS application.

    ## Environment Context
    - Each open PR gets a dedicated Kubernetes namespace: preview-pr-{number}
    - Preview URL: https://pr-{number}.preview.yourdomain.com
    - Deployed by Argo CD, auto-syncs from PR branch HEAD
    - Stack: Next.js, PostgreSQL (CloudNativePG), Redis
    - Preview databases start empty — blank UIs are expected, not bugs

    ## Pre-flight Check
    Before starting work, verify the preview namespace exists:
      kubectl get namespace preview-pr-{number}
    If it does not exist, wait 3 minutes and retry (max 3 retries).
    If still missing, comment: "Preview not ready" and add label
    "ai/needs-input", then STOP.

    ## Capabilities
    - Read/edit source code in the cloned PR branch
    - Run tests, linter, type checker
    - kubectl (read-only): pods, logs, events, services, ingress
    - gh CLI: comment, label PRs
    - Commit and push to PR branch

    ## Operating Rules
    1. First: add label "ai/in-progress" to the PR
    2. NEVER force-push, rebase, or amend existing commits
    3. ALWAYS run tests before committing
    4. Atomic commits, prefixed with "ai: "
    5. When code changes are committed, Argo CD auto-syncs the preview
    6. If stuck: add label "ai/needs-input", comment why, STOP
    7. Do NOT modify deploy/ directory unless asked
    8. Do NOT access namespaces other than the preview namespace
    9. For migration failures: fix the migration code, do NOT run manual SQL
    10. Last: remove label "ai/in-progress" from the PR

    ## Debugging Workflow
    1. kubectl get pods -n preview-pr-{number}
    2. kubectl get events -n preview-pr-{number} --sort-by=.lastTimestamp
    3. kubectl logs -n preview-pr-{number} -l app=your-app --tail=100
    4. Correlate errors with the PR diff
    5. Fix or report

  skills:
    - name: kelos
```

### AgentConfig: Security Reviewer

```yaml
apiVersion: kelos.dev/v1alpha1
kind: AgentConfig
metadata:
  name: security-reviewer
  namespace: kelos-system
spec:
  systemPrompt: |
    You are a security engineer reviewing a PR for a SaaS application.

    ## Your Scope
    Review the code changes in this PR for security vulnerabilities:
    - SQL injection, XSS, CSRF
    - Authentication and authorization bypasses
    - Secrets, credentials, or API keys committed in code
    - Insecure deserialization
    - Path traversal or file inclusion
    - Dependency vulnerabilities (check package.json, lock files)
    - OWASP Top 10 violations
    - Improper error handling that leaks internal state

    ## Output Format
    Post a structured PR comment with:
    ### Security Review — PR #{number}
    **Critical:** (issues that must be fixed before merge)
    **Warning:** (issues that should be addressed)
    **Info:** (suggestions for hardening)
    **Clean:** (areas reviewed with no findings)

    ## Rules
    - Do NOT fix code unless explicitly asked — report only
    - Do NOT modify any files unless asked
    - Be specific: cite file paths, line numbers, and CWE IDs
    - If no issues found, say so clearly
    - Add label "ai/in-progress" at start, remove at end

  skills:
    - name: kelos
```

### AgentConfig: QA Reviewer

```yaml
apiVersion: kelos.dev/v1alpha1
kind: AgentConfig
metadata:
  name: qa-reviewer
  namespace: kelos-system
spec:
  systemPrompt: |
    You are a QA engineer reviewing a PR for a SaaS application.

    ## Your Scope
    1. Analyze test coverage for all changed files
    2. Write missing unit tests and integration tests
    3. Run the full test suite: npm test
    4. Check the preview environment:
       - Hit the preview URL and verify key user flows
       - curl internal API endpoints from the preview namespace
       - Check for console errors, broken routes, 500s
    5. Verify edge cases in changed code paths

    ## Preview Environment
    - Namespace: preview-pr-{number}
    - URL: https://pr-{number}.preview.yourdomain.com
    - kubectl is available for pod inspection

    ## Output
    - Commit new/fixed tests to the PR branch (prefix: "ai: ")
    - Post a PR comment summarizing:
      - Test coverage before and after
      - Tests added
      - Preview health check results
      - Edge cases found

    ## Rules
    - Add label "ai/in-progress" at start, remove at end
    - Run tests BEFORE committing
    - Do NOT modify non-test files unless asked

  skills:
    - name: kelos
```

### AgentConfig: Dev Reviewer

```yaml
apiVersion: kelos.dev/v1alpha1
kind: AgentConfig
metadata:
  name: dev-reviewer
  namespace: kelos-system
spec:
  systemPrompt: |
    You are a senior software engineer doing a thorough code review.

    ## Review Criteria
    - Code quality, readability, and maintainability
    - Performance: N+1 queries, unnecessary re-renders, O(n²) loops
    - Error handling: missing try/catch, unhandled promise rejections
    - API contract: backward compatibility, breaking changes
    - Naming conventions and code organization
    - DRY violations and abstraction opportunities
    - Type safety: proper TypeScript usage, `any` abuse
    - Race conditions in async code

    ## Output Format
    Post a structured PR comment:
    ### Code Review — PR #{number}
    **Must Fix:** (blocking issues)
    **Should Fix:** (non-blocking but important)
    **Nit:** (style/preference suggestions)
    **Positive:** (things done well — always include at least one)

    ## Rules
    - Do NOT modify code unless explicitly asked
    - Be constructive and specific
    - Cite file paths and line numbers
    - Add label "ai/in-progress" at start, remove at end

  skills:
    - name: kelos
```

### TaskSpawner: Auto-Trigger on PR

Runs the fixer agent automatically on every qualifying PR.

```yaml
apiVersion: kelos.dev/v1alpha1
kind: TaskSpawner
metadata:
  name: preview-auto-review
  namespace: kelos-system
spec:
  when:
    githubPullRequests:
      workspaceRef:
        name: your-app
      state: open
      draft: false
      labels:
        - ai-review
      excludeLabels:
        - ai-skip
        - ai/needs-input
        - ai/in-progress       # per-PR deduplication

  taskTemplate:
    type: claude-code
    credentials:
      type: api-key
      secretRef:
        name: anthropic-api-key
    model: claude-sonnet-4-20250514
    agentConfigRef:
      name: fixer-agent
    promptTemplate: |
      ## PR #{{.Number}}: {{.Title}}
      Branch: {{.HeadRef}}
      Preview: preview-pr-{{.Number}}
      URL: https://pr-{{.Number}}.preview.yourdomain.com

      ### Description
      {{.Body}}

      ### Task
      1. Review code changes for bugs and issues
      2. Check preview health (pods, logs, events)
      3. Fix any errors found
      4. Run tests and fix failures
      5. Post summary comment on PR

    podOverrides:
      activeDeadlineSeconds: 3600

  pollInterval: 5m
  maxConcurrency: 3
  maxTotalTasks: 50
```

### TaskSpawner: On-Demand Fixer

```yaml
apiVersion: kelos.dev/v1alpha1
kind: TaskSpawner
metadata:
  name: preview-fixer
  namespace: kelos-system
spec:
  when:
    githubPullRequests:
      workspaceRef:
        name: your-app
      state: open
      triggerComment:
        pattern: "@agent fix"
      excludeLabels:
        - ai/in-progress

  taskTemplate:
    type: claude-code
    credentials:
      type: api-key
      secretRef:
        name: anthropic-api-key
    model: claude-sonnet-4-20250514
    agentConfigRef:
      name: fixer-agent
    promptTemplate: |
      ## PR #{{.Number}}: {{.Title}}
      Branch: {{.HeadRef}}
      Preview: preview-pr-{{.Number}}

      ### Request
      > {{.TriggerComment}}

      Address the request. Commit changes. Reply with summary.

    podOverrides:
      activeDeadlineSeconds: 1800

  pollInterval: 2m
  maxConcurrency: 2
  maxTotalTasks: 100
```

### TaskSpawner: Security Review

```yaml
apiVersion: kelos.dev/v1alpha1
kind: TaskSpawner
metadata:
  name: preview-security
  namespace: kelos-system
spec:
  when:
    githubPullRequests:
      workspaceRef:
        name: your-app
      state: open
      triggerComment:
        pattern: "@agent security"
      excludeLabels:
        - ai/in-progress

  taskTemplate:
    type: claude-code
    credentials:
      type: api-key
      secretRef:
        name: anthropic-api-key
    model: claude-sonnet-4-20250514
    agentConfigRef:
      name: security-reviewer
    promptTemplate: |
      ## Security Review — PR #{{.Number}}: {{.Title}}
      Branch: {{.HeadRef}}
      Preview: preview-pr-{{.Number}}

      Review all code changes in this PR for security vulnerabilities.
      Post findings as a structured comment on the PR.

    podOverrides:
      activeDeadlineSeconds: 1800

  pollInterval: 2m
  maxConcurrency: 2
  maxTotalTasks: 100
```

### TaskSpawner: QA Review

```yaml
apiVersion: kelos.dev/v1alpha1
kind: TaskSpawner
metadata:
  name: preview-qa
  namespace: kelos-system
spec:
  when:
    githubPullRequests:
      workspaceRef:
        name: your-app
      state: open
      triggerComment:
        pattern: "@agent qa"
      excludeLabels:
        - ai/in-progress

  taskTemplate:
    type: claude-code
    credentials:
      type: api-key
      secretRef:
        name: anthropic-api-key
    model: claude-sonnet-4-20250514
    agentConfigRef:
      name: qa-reviewer
    promptTemplate: |
      ## QA Review — PR #{{.Number}}: {{.Title}}
      Branch: {{.HeadRef}}
      Preview: preview-pr-{{.Number}}
      URL: https://pr-{{.Number}}.preview.yourdomain.com

      Check test coverage, write missing tests, verify the preview
      environment works. Commit tests and post findings.

    podOverrides:
      activeDeadlineSeconds: 1800

  pollInterval: 2m
  maxConcurrency: 2
  maxTotalTasks: 100
```

### TaskSpawner: Dev Review

```yaml
apiVersion: kelos.dev/v1alpha1
kind: TaskSpawner
metadata:
  name: preview-dev-review
  namespace: kelos-system
spec:
  when:
    githubPullRequests:
      workspaceRef:
        name: your-app
      state: open
      triggerComment:
        pattern: "@agent review"
      excludeLabels:
        - ai/in-progress

  taskTemplate:
    type: claude-code
    credentials:
      type: api-key
      secretRef:
        name: anthropic-api-key
    model: claude-sonnet-4-20250514
    agentConfigRef:
      name: dev-reviewer
    promptTemplate: |
      ## Code Review — PR #{{.Number}}: {{.Title}}
      Branch: {{.HeadRef}}

      Review all code changes for quality, performance, error handling,
      and maintainability. Post structured findings on the PR.

    podOverrides:
      activeDeadlineSeconds: 1800

  pollInterval: 2m
  maxConcurrency: 2
  maxTotalTasks: 100
```

### Per-PR Task Deduplication

All TaskSpawners include `ai/in-progress` in their `excludeLabels`. The agent adds this label at the start of every run and removes it at the end. This prevents a second agent from spawning for the same PR while one is active.

```
Developer comments: @agent security
    │
    ▼
TaskSpawner polls → finds PR without "ai/in-progress" label → creates Task
    │
    ▼
Agent starts → adds "ai/in-progress" label to PR
    │
    ▼
Another developer comments: @agent fix
    │
    ▼
TaskSpawner polls → sees "ai/in-progress" label → SKIPS (deduplication)
    │
    ▼
First agent finishes → removes "ai/in-progress" label
    │
    ▼
Next poll cycle → @agent fix request is now eligible → creates Task
```

**Usage on a PR:**

```
@agent fix the 500 error on /api/users     → fixer agent
@agent security                             → security audit
@agent qa                                   → writes tests, checks preview
@agent review                               → code review with feedback
@agent fix the login page is broken          → fixer agent (any "fix" pattern)
```

---

## RBAC and Security

### Argo CD AppProject Restrictions

The AppProject enforces:

- Deployments only to `preview-*` namespaces
- Source code only from the specified repo
- No cluster-scoped resources
- No modification of ResourceQuota, NetworkPolicy, or RBAC within previews

### Preview Namespace RBAC for AI Agent

```yaml
# ClusterRole (created once)
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: preview-ai-agent-reader
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "services", "configmaps", "events", "endpoints"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list"]
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["get", "list"]
  # NOT included: pods/exec, secrets, delete, namespace, networkpolicy, rbac
---
# RoleBinding (per-namespace, in Helm chart)
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ai-agent-reader
  namespace: 'preview-pr-{{ .Values.prNumber }}'
subjects:
  - kind: ServiceAccount
    name: kelos-agent-sa
    namespace: kelos-system
roleRef:
  kind: ClusterRole
  name: preview-ai-agent-reader
  apiGroup: rbac.authorization.k8s.io
```

### NetworkPolicy for Agent Pods

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kelos-agent-egress
  namespace: kelos-system
spec:
  podSelector:
    matchLabels:
      kelos.dev/component: task
  policyTypes:
    - Egress
    - Ingress
  ingress: []
  egress:
    - to: [{namespaceSelector: {}}]
      ports: [{port: 53, protocol: UDP}, {port: 53, protocol: TCP}]
    - to: [{ipBlock: {cidr: 0.0.0.0/0}}]
      ports: [{port: 443}]
    - to: [{ipBlock: {cidr: "<API_SERVER_IP>/32"}}]
      ports: [{port: 6443}]
```

### NetworkPolicy for Preview Namespaces

```yaml
# deploy/preview/templates/networkpolicy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: preview-isolation
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
  egress:
    - to: [{namespaceSelector: {}}]
      ports: [{port: 53, protocol: UDP}, {port: 53, protocol: TCP}]
    - to: [{podSelector: {}}]
    - to: [{ipBlock: {cidr: 0.0.0.0/0}}]
      ports: [{port: 443}]
```

---

## Resource Governance

### Per-Namespace Quotas

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: preview-quota
spec:
  hard:
    requests.cpu: "500m"
    requests.memory: "1Gi"
    limits.cpu: "2"
    limits.memory: "4Gi"
    persistentvolumeclaims: "2"
    pods: "15"
    services: "5"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: preview-defaults
spec:
  limits:
    - default: {cpu: "500m", memory: "512Mi"}
      defaultRequest: {cpu: "100m", memory: "128Mi"}
      type: Container
```

### Cluster-Level Namespace Cap

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: limit-preview-namespaces
spec:
  validationFailureAction: Enforce
  rules:
    - name: cap-preview-namespaces
      match:
        any:
          - resources:
              kinds: [Namespace]
              names: ["preview-*"]
      preconditions:
        all:
          - key: "{{ request.operation }}"
            operator: Equals
            value: CREATE
      validate:
        message: "Maximum 15 preview namespaces. Close some PRs first."
        deny:
          conditions:
            all:
              - key: "{{ request.object.metadata.name | length(@) }}"
                operator: GreaterThan
                value: 0
```

### AI Agent Cost Controls

| Control | Configuration | Effect |
|---|---|---|
| Model selection | `model: claude-sonnet-4-20250514` | Sonnet for routine. Reserve Opus for complex. |
| Concurrency cap | `maxConcurrency: 3` (auto), `2` (on-demand) | Limits parallel agents |
| Total task cap | `maxTotalTasks: 50` (auto), `100` (on-demand) | Absolute limit |
| Runtime timeout | `activeDeadlineSeconds: 3600` (auto), `1800` (on-demand) | Kills long-running agents |
| Emergency stop | `kelos suspend taskspawner <name>` | Pauses immediately |
| Per-PR dedup | `excludeLabels: [ai/in-progress]` | One agent per PR at a time |
| Feedback loop | `excludeLabels: [ai/needs-input]` | Agent self-pauses when stuck |

---

## Observability

### Preview Namespace Monitoring

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: preview-app
  labels:
    prometheus.io/retention: "24h"
spec:
  selector:
    matchLabels:
      app: your-app
  podMetricsEndpoints:
    - port: metrics
      interval: 30s
```

### Kelos Task Monitoring

```bash
kelos get tasks                      # list all tasks
kubectl get tasks -n kelos-system -w # watch status transitions
kelos logs <task-name> -f            # stream agent logs
kelos get taskspawners               # list spawner state
```

---

## Argo CD Notifications

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-notifications-cm
  namespace: argocd
data:
  trigger.on-deployed: |
    - description: Preview synced and healthy
      send: [github-deployment-status]
      when: app.status.operationState.phase in ['Succeeded'] and app.status.health.status == 'Healthy'

  trigger.on-health-degraded: |
    - description: Preview health degraded
      send: [github-pr-comment-degraded]
      when: app.status.health.status == 'Degraded'

  template.github-deployment-status: |
    message: |
      Preview deployed: https://{{ .app.spec.source.helm.valuesObject.ingress.host }}
      Agent commands: `@agent fix ...` `@agent security` `@agent qa` `@agent review`

  template.github-pr-comment-degraded: |
    message: |
      Preview health degraded. Run `@agent fix investigate the preview failure` for automated diagnosis.
```

---

## Secrets Management

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: app-secrets
  namespace: 'preview-pr-{{ .Values.prNumber }}'
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: app-secrets
  data:
    - secretKey: DATABASE_URL
      remoteRef:
        key: preview/database-url
    - secretKey: NEXTAUTH_SECRET
      remoteRef:
        key: preview/nextauth-secret
```

---

## Operations Runbook

### Emergency Procedures

| Scenario | Command | Effect |
|---|---|---|
| Agent going rogue | `kelos suspend taskspawner preview-auto-review` | Stops all new auto-trigger tasks |
| Stop ALL agents | `kelos suspend taskspawner --all` | Stops all task spawners |
| Resume after investigation | `kelos resume taskspawner preview-auto-review` | Re-enables task creation |
| Kill a specific agent | `kubectl delete task <name> -n kelos-system` | Kills agent pod via owner reference |
| List running agents | `kelos get tasks` | Shows all task statuses |
| Orphaned namespace | `kubectl delete namespace preview-pr-<n>` | Manual cleanup |

### Diagnostics

| What | Command |
|---|---|
| ApplicationSet controller health | `kubectl logs -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller --tail=50` |
| Argo Events controller health | `kubectl logs -n argo-events -l app=sensor-controller --tail=50` |
| Kelos controller health | `kubectl logs -n kelos-system deployment/kelos-controller-manager --tail=50` |
| EventBus (NATS) health | `kubectl get eventbus -n argo-events` |
| All preview Applications | `kubectl get applications -n argocd -l preview=true` |
| Failed previews only | `kubectl get applications -n argocd -l preview=true -o jsonpath='{range .items[?(@.status.health.status!="Healthy")]}{.metadata.name}{"\t"}{.status.health.status}{"\n"}{end}'` |
| Recent agent costs | `kelos get tasks -o wide` |

### Credential Rotation

| Credential | Location | Rotation |
|---|---|---|
| GitHub PAT (Kelos) | `Secret github-pat` in `kelos-system` | Update Secret, restart Kelos controller |
| GitHub Token (Argo CD) | `Secret github-token` in `argocd` | Update Secret, restart ApplicationSet controller |
| Anthropic API Key | `Secret anthropic-api-key` in `kelos-system` | Update Secret — new tasks pick up automatically |
| GitHub Webhook Secret | `Secret github-webhook-secret` in `argo-events` | Update Secret + GitHub webhook config simultaneously |
| GHCR Pull Secret | Managed by External Secrets Operator | Automatic via ESO refresh interval |

---

## Known Gotchas

### PVC Cleanup

CloudNativePG creates PersistentVolumeClaims. Use `reclaimPolicy: Delete` on your preview StorageClass, or create a dedicated `preview-storage` StorageClass.

### GitHub Token Scope

The GitHub PAT for Kelos must have `contents:write` on the repo. Missing this permission causes silent push failures.

### Branch Protection

Agents push to PR branches, not `main`. If PR branches have protection rules (e.g., "require linear history"), agents may fail to push merge commits. Ensure PR branches allow standard pushes.

### GHCR Webhook Limitation

GHCR does not support native push webhooks. The CI pipeline must POST to the Argo Events webhook endpoint after `docker push`. This is handled by the GitHub Actions workflow included in this spec.

### Kelos Poll Interval

Kelos TaskSpawner still uses polling (not webhooks). The `pollInterval` is 5m for auto-trigger and 2m for on-demand. Argo Events handles the CI→CD sequencing via webhooks, but the agent spawning delay is bounded by the poll interval.

### Empty Preview Databases

Preview databases start empty after migrations. Blank UIs are expected behavior. The fixer agent's system prompt includes this context to prevent false-positive bug reports.

### Event Ordering

Argo Events' Sensor conditions use AND logic, not ordering. Both `ci-success` AND `image-ready` must occur, but they can arrive in any order. The Sensor will fire as soon as both are satisfied.

---

## Implementation Order

| Phase | What | Validates | Tools |
|---|---|---|---|
| 1 | Argo CD AppProject + ApplicationSet with minimal chart | PR → namespace works | Argo CD |
| 2 | Wildcard DNS + cert-manager | Previews are routable with TLS | cert-manager |
| 3 | GitHub Actions CI pipeline + GHCR push | Images build per PR | GitHub Actions |
| 4 | Argo Events: EventBus + EventSource + "ci+image" Sensor | Image race condition solved | Argo Events |
| 5 | Add PostgreSQL + Redis + sync waves to Helm chart | Startup ordering works | Argo CD |
| 6 | Health probes + migration Job with hook-delete-policy | Reliable health signals | Argo CD |
| 7 | ResourceQuota + LimitRange + NetworkPolicy in chart | Resource governance | Kubernetes |
| 8 | External Secrets: registry pull secrets + app secrets | No ImagePullBackOff from auth | ESO |
| 9 | Argo CD Notifications | PR comments with preview URLs | Argo CD |
| 10 | Install Kelos, create Workspace + manual Task test | Agent can clone, work, push | Kelos |
| 11 | Create fixer AgentConfig + on-demand TaskSpawner | `@agent fix` works | Kelos |
| 12 | Create security, QA, dev review AgentConfigs + spawners | `@agent security/qa/review` works | Kelos |
| 13 | Argo Events: "preview-healthy" Sensor → agent trigger | Namespace race solved | Argo Events |
| 14 | Create auto-trigger TaskSpawner with dedup labels | Fully autonomous loop | Kelos |
| 15 | Kyverno namespace cap + final cost control tuning | Cluster-wide safety | Kyverno |

---

## Appendix: Full Manifest Reference

### Component Summary

| Component | Type | Namespace | Description |
|---|---|---|---|
| EventBus `default` | Argo Events CR | `argo-events` | NATS transport |
| EventSource `github-webhook` | Argo Events CR | `argo-events` | GitHub PR/status webhooks |
| EventSource `container-registry` | Argo Events CR | `argo-events` | Image push notifications |
| Sensor `preview-deploy` | Argo Events CR | `argo-events` | CI+image → sync preview |
| Sensor `preview-agent-trigger` | Argo Events CR | `argo-events` | Preview healthy → spawn agent |
| AppProject `previews` | Argo CD CR | `argocd` | Scoped project |
| ApplicationSet `preview-envs` | Argo CD CR | `argocd` | PR → Application generator |
| CronJob `preview-reaper` | Kubernetes CronJob | `argocd` | Orphan cleanup (15m) |
| Certificate `preview-wildcard` | cert-manager CR | `ingress-nginx` | Wildcard TLS |
| ClusterExternalSecret `ghcr-pull-secret` | ESO CR | Cluster-scoped | Registry auth distribution |
| Workspace `your-app` | Kelos CR | `kelos-system` | Repo + credentials |
| AgentConfig `fixer-agent` | Kelos CR | `kelos-system` | Fix/diagnose agent |
| AgentConfig `security-reviewer` | Kelos CR | `kelos-system` | Security audit agent |
| AgentConfig `qa-reviewer` | Kelos CR | `kelos-system` | QA/testing agent |
| AgentConfig `dev-reviewer` | Kelos CR | `kelos-system` | Code review agent |
| TaskSpawner `preview-auto-review` | Kelos CR | `kelos-system` | Auto-trigger on PR |
| TaskSpawner `preview-fixer` | Kelos CR | `kelos-system` | `@agent fix` trigger |
| TaskSpawner `preview-security` | Kelos CR | `kelos-system` | `@agent security` trigger |
| TaskSpawner `preview-qa` | Kelos CR | `kelos-system` | `@agent qa` trigger |
| TaskSpawner `preview-dev-review` | Kelos CR | `kelos-system` | `@agent review` trigger |
| ClusterRole `preview-ai-agent-reader` | RBAC | Cluster-scoped | Agent read-only access |
| ClusterPolicy `limit-preview-namespaces` | Kyverno CR | Cluster-scoped | Namespace cap (15) |
| NetworkPolicy `kelos-agent-egress` | NetworkPolicy | `kelos-system` | Agent pod egress |

### Helm Chart Values Reference

```yaml
# deploy/preview/values.yaml

prNumber: "0"

image:
  repository: ghcr.io/your-org/your-app
  tag: latest
  pullPolicy: IfNotPresent

ingress:
  host: localhost
  className: nginx

namespace: preview-pr-0

database:
  name: preview_pr_0
  instances: 1
  storage: 1Gi

redis:
  enabled: true
  persistence: false

resources:
  app:
    requests: {cpu: 100m, memory: 256Mi}
    limits: {cpu: 500m, memory: 512Mi}

quota:
  cpu: {requests: "500m", limits: "2"}
  memory: {requests: "1Gi", limits: "4Gi"}
  pods: "15"
  pvcs: "2"
```
