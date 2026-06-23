# Architecture Diagrams

Visual companions to [architecture.md](architecture.md) and
[preview-cluster-setup.md](preview-cluster-setup.md). Each diagram
focuses on one flow; together they cover the whole preview platform.

---

## 1. Build + Promotion Pipeline

CUE renders, CI packages as OCI artifact, env repos reference digest,
GitOps applies to spoke clusters.

```mermaid
flowchart LR
  subgraph Author["Author"]
    edit["Edit composites/preview/*.cue"]
  end

  subgraph CI["CI / Make"]
    validate["cue vet ./..."]
    render["cue export ./export/<br>→ clusters/preview/*.yaml"]
    pkg["oras push<br>OCI artifact"]
  end

  subgraph EnvRepo["env repo"]
    digest["artifact-digest.yaml"]
  end

  subgraph Spoke["Spoke cluster"]
    argocd["Argo CD"]
    workloads["Rendered manifests"]
  end

  edit --> validate --> render --> pkg --> digest
  digest -->|GitOps sync| argocd --> workloads
```

---

## 2. Cluster Topology (`talos-preview`)

Six Talos nodes managed by Omni SaaS, with the platform namespaces this
repo provisions.

```mermaid
flowchart TB
  subgraph Omni["Omni SaaS"]
    omni["example.na-west-1.omni.siderolabs.io"]
  end

  subgraph Cluster["talos-preview"]
    direction TB
    subgraph CP["Control plane (3)"]
      cp1["talos-node-01"]
      cp2["talos-node-07"]
      cp3["talos-node-13"]
    end
    subgraph Workers["Workers (3)"]
      w1["talos-node-02<br>longhorn 161GB"]
      w2["talos-node-06<br>longhorn 161GB"]
      w3["talos-node-17<br>longhorn 161GB"]
    end

    subgraph Platform["Platform namespaces"]
      cs["crossplane-system"]
      es["external-secrets"]
      ob["openbao"]
      ac["argocd"]
      ae["argo-events"]
      tk["traefik"]
      cf["cloudflared"]
      lh["longhorn-system"]
      cnp["cnpg-system"]
      ks["kube-system<br>(metrics-server, omni-exposer)"]
    end

    subgraph Tenant["Tenant namespaces"]
      pr1["preview-app-pr-1"]
      pr2["preview-app-pr-2"]
      prN["preview-app-pr-N"]
    end
  end

  omni -.kubeconfig + machine config.-> CP
  CP --> Workers
  Workers --> Platform
  Workers --> Tenant
```

---

## 3. Preview Environment Per-PR Lifecycle

PR opened with `preview` label → Argo CD ApplicationSet creates an
Application → Helm chart deploys into a fresh namespace → Cloudflare
tunnel routes the URL.

```mermaid
sequenceDiagram
  autonumber
  actor Dev as Developer
  participant GH as GitHub<br>(example-org org)
  participant CFTun as Cloudflare<br>tunnel
  participant ESrc as argo-events<br>EventSource
  participant Sensor as argo-events<br>Sensor
  participant ASet as Argo CD<br>ApplicationSet
  participant App as Argo CD<br>Application
  participant K8s as Preview<br>namespace
  participant CFEdge as Cloudflare<br>edge

  Dev->>GH: open PR (label=preview)
  GH->>CFTun: org webhook POST<br>events.example.com/github/pr
  CFTun->>ESrc: forward to in-cluster<br>Service :12000
  ESrc-->>Sensor: publish to NATS eventbus
  ASet->>GH: pullRequest generator polls<br>(every 30s)
  GH-->>ASet: open PRs with label=preview
  ASet->>App: create<br>{slug}-pr-{N} Application
  App->>K8s: sync Helm chart<br>into preview-{slug}-pr-{N}
  Sensor->>App: optional force sync Job<br>(once CI + image ready)
  K8s-->>CFTun: Service ready
  Dev->>CFEdge: visit {slug}-pr-{N}.preview.example.com
  CFEdge->>CFTun: route via tunnel
  CFTun->>K8s: forward to Traefik → app
```

---

## 4. Multi-Repo Matrix ApplicationSet

`_repos` list × pullRequest generator → one Application per (repo, PR).

```mermaid
flowchart LR
  subgraph CUE["composites/preview/argocd.cue"]
    repos["_repos: [<br>{slug: app-a, ...},<br>{slug: app-b, ...},<br>...<br>]"]
  end

  subgraph ASet["matrix(list × pullRequest)"]
    list["list generator<br>iterates _repos"]
    pr["pullRequest generator<br>per repo (open PRs<br>with label=preview)"]
    list --> pr
  end

  subgraph Apps["Argo CD Applications"]
    a1["app-a-pr-1"]
    a2["app-a-pr-2"]
    b1["app-b-pr-7"]
    b2["app-b-pr-12"]
  end

  repos --> ASet --> Apps

  subgraph URLs["URLs (single wildcard CNAME)"]
    u1["app-a-pr-1.preview.example.com"]
    u2["app-a-pr-2.preview.example.com"]
    u3["app-b-pr-7.preview.example.com"]
    u4["app-b-pr-12.preview.example.com"]
  end

  a1 --> u1
  a2 --> u2
  b1 --> u3
  b2 --> u4
```

---

## 5. Secret Flow (OpenBao → ESO → Workload)

Single source of truth in OpenBao; ESO syncs into per-namespace Secrets;
workloads consume via env or volume.

```mermaid
flowchart LR
  subgraph Op["OpenBao (kv v2)"]
    p1["preview/github-pat<br>{GITHUB_USER, GITHUB_TOKEN}"]
    p2["preview/cloudflare-tunnel<br>{account_id, tunnel_name, api_token}"]
    p3["preview/discord-webhook-url<br>{url}"]
    p4["preview/app/*<br>{NEXTAUTH_SECRET, ...}"]
  end

  subgraph ESO["External Secrets Operator"]
    css["ClusterSecretStore<br>openbao-backend"]
    nse["ExternalSecret<br>(per namespace)"]
    ces["ClusterExternalSecret<br>app-shared-secrets,<br>ghcr-pull-secret"]
  end

  subgraph K8s["Kubernetes Secrets"]
    s1["argocd/github-token"]
    s2["argocd/argocd-notifications-secret"]
    s3["cloudflared/cloudflare-external-secret"]
    s4["preview-*/app-shared-secrets"]
    s5["preview-*/ghcr-pull-secret"]
  end

  subgraph WL["Workloads"]
    a["argocd-server,<br>notifications-controller"]
    c["STRRL controller +<br>cloudflared connector"]
    apps["preview app pods"]
  end

  Op --> css
  css --> nse
  css --> ces
  nse --> s1
  nse --> s2
  nse --> s3
  ces --> s4
  ces --> s5
  s1 --> a
  s2 --> a
  s3 --> c
  s4 --> apps
  s5 --> apps
```

---

## 6. Cloudflare Tunnel + Ingress (STRRL)

Edge → tunnel → in-cluster Services. STRRL controller manages tunnel
config, DNS, and the connector Deployment automatically from Ingress
resources.

```mermaid
flowchart LR
  subgraph Internet["Internet"]
    user["Browser /<br>GitHub webhook"]
  end

  subgraph CF["Cloudflare"]
    edge["example.com<br>edge"]
    tun["preview tunnel<br>dd46871d-...cfargotunnel.com"]
    edge --> tun
  end

  subgraph Ctrl["cloudflared ns"]
    strrl["STRRL controller<br>(reads Ingress<br>class=cloudflare-tunnel)"]
    conn["controlled-cloudflared-<br>connector (4 quic conns)"]
    strrl -.creates DNS,<br>tunnel config.-> CF
    strrl --> conn
  end

  subgraph Routes["Ingress resources"]
    i1["traefik/preview-wildcard<br>*.preview.example.com"]
    i2["argo-events/events<br>events.example.com"]
  end

  subgraph Backends["Backends"]
    tk["traefik svc :80<br>→ per-PR IngressRoute"]
    gh["github-webhook-eventsource-svc :12000"]
    cr["container-registry-eventsource-svc :13000"]
  end

  user --> edge
  tun --> conn
  i1 --> tk
  i2 -->|/github/pr| gh
  i2 -->|/registry/push| cr
  conn --> tk
  conn --> gh
  conn --> cr
```

---

## 7. Argo CD Notification Routing

Application status → triggers → templates → external services. Discord
gets the AI-outage signal only when the Application carries
`preview.example.com/depends-on-ai=true`.

```mermaid
flowchart LR
  subgraph App["Argo CD Application"]
    state["status.health<br>operationState.phase"]
    anno["annotations:<br>depends-on-ai=true|false<br>subscribe.on-deployed.github<br>subscribe.on-health-degraded.github<br>subscribe.on-ai-outage.discord"]
  end

  subgraph Triggers["Triggers (in argocd-cm)"]
    t1["on-deployed<br>= Healthy AND Succeeded"]
    t2["on-health-degraded<br>= Degraded"]
    t3["on-ai-outage<br>= Degraded AND<br>depends-on-ai=true"]
  end

  subgraph Templates["Templates"]
    tplGH["github-deployment-status<br>github-pr-comment-degraded"]
    tplDC["discord-ai-outage"]
  end

  subgraph Channels["External"]
    gh["GitHub PR comment<br>POST api.github.com"]
    dc["Discord channel<br>webhook URL"]
  end

  state --> t1 & t2 & t3
  anno -.gates.-> t1 & t2 & t3
  t1 --> tplGH
  t2 --> tplGH
  t3 --> tplDC
  tplGH --> gh
  tplDC --> dc
```

---

## 8. Bootstrap Script Phases

Phases run in order. Idempotent — safe to re-run after partial failure
or chart upgrades.

```mermaid
flowchart TB
  start(["bootstrap-preview.sh"])

  start --> p1["1. Tool + cluster preflight"]
  p1 --> p2["2. Talos disk + iscsi-tools check"]
  p2 --> p3["3. Longhorn install"]
  p3 --> p35["3.5 metrics-server +<br>kubelet-serving-cert-approver"]
  p35 --> p4["4. CloudNativePG"]
  p4 --> p5["5. Crossplane UXP +<br>providers + functions + RBAC"]
  p5 --> p55["5.5 Patch upbound-crossplane-versions<br>ConfigMap (crossplaneVersion key)"]
  p55 --> p6["6. make validate +<br>make export-cluster"]
  p6 --> p7["7. kubectl apply rendered +<br>cloudflared Ingresses +<br>kick omni-exposer DS"]
  p7 --> p8["8. Wait HelmReleases<br>Synced+Ready"]
  p8 --> p85["8.5 Argo CD ci account + RBAC<br>(restart server)"]
  p85 --> p9["9. Print next-steps:<br>OpenBao seeding,<br>Cloudflare API token,<br>GitHub webhook"]
  p9 --> done(["operator runs<br>manual seeding"])
```

---

## 9. End-to-End PR Smoke Test

What happens when a developer opens a PR with the `preview` label.

```mermaid
sequenceDiagram
  autonumber
  actor Dev
  participant GH
  participant CF as Cloudflare<br>tunnel
  participant AE as argo-events<br>(EventSource + Sensor)
  participant ACD as Argo CD
  participant App as Helm app<br>(in preview-{slug}-pr-{N})
  participant ESO
  participant OB as OpenBao
  participant Disc as Discord

  Dev->>GH: open PR + label "preview"
  GH->>CF: webhook
  CF->>AE: POST /github/pr
  AE-->>ACD: (sensor is informational; sync<br>still driven by ApplicationSet polling)
  ACD->>GH: list open PRs<br>(uses github-token from ESO)
  GH-->>ACD: PR list
  ACD->>App: create Application + namespace
  ESO->>OB: read secret/preview/app/*
  OB-->>ESO: shared secret values
  ESO->>App: kubernetes Secret<br>app-shared-secrets
  App->>App: pod Ready + IngressRoute live
  ACD-->>GH: post "Preview deployed" comment
  Note over App,Disc: If app is Degraded AND depends-on-ai=true:
  ACD->>Disc: webhook AI outage message
```
