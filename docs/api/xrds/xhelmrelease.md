---
kind: XHelmRelease
group: infra.k8
version: v1alpha1
xrd: xhelmreleases.infra.k8
---

# XHelmRelease
Request a Helm chart installation managed by the platform.

- XRD: xhelmreleases.infra.k8
- Group: infra.k8
- Version: v1alpha1
- Spec schema: ./schema/xhelmrelease.json
- Full schema: ./schema/xhelmrelease.full.json

## Usage

Create a composite resource using this API, then export and apply manifests:

```bash
make export-split CLUSTER=new-dev
kubectl apply -R -f clusters/new-dev/
```

## Defaults and Policy

Tier-based defaults and policy enforcement live in libs/tiers and platform policies.
See docs/architecture.md and libs/tiers/*.cue for details.

## Required Fields

- `name`
- `namespace`
- `chart`
- `tier`
- `cluster`
- `owner`

## Provider

- provider-helm

## Behavior

- Installs or upgrades the chart in the target namespace.
- Values are passed through to Helm without validation.

## Gotchas

- The chart repository must be reachable from the cluster.
- Chart version changes will trigger an upgrade.


## Spec Schema

This is the OpenAPI schema for the spec field.

```yaml
type: object
description: Desired Helm release settings and placement metadata.
example:
  name: external-secrets
  namespace: external-secrets
  chart:
    name: external-secrets
    repository: https://charts.external-secrets.io
    version: 0.10.0
  values: {}
  tier: dev
  cluster: new-dev
  owner: platform-team
x-docs:
  provider: provider-helm
  policyRefs: []
  behavior:
    - Installs or upgrades the chart in the target namespace.
    - Values are passed through to Helm without validation.
  gotchas:
    - The chart repository must be reachable from the cluster.
    - Chart version changes will trigger an upgrade.
properties:
  name:
    type: string
    description: Helm release name. Must be DNS-1123 compatible.
    pattern: ^[a-z][a-z0-9-]*$
  namespace:
    type: string
    description: Namespace where the Helm release will be installed.
    pattern: ^[a-z][a-z0-9-]*$
  chart:
    type: object
    description: Chart reference (name, repo, version).
    properties:
      name:
        type: string
        description: Chart name within the repository.
      repository:
        type: string
        description: Chart repository URL.
      version:
        type: string
        description: Chart version to install.
    required:
      - name
      - repository
      - version
  values:
    type: object
    description: Values map passed to the chart (free-form).
    x-kubernetes-preserve-unknown-fields: true
  tier:
    type: string
    description: Tier used for labeling and policy selection.
    enum:
      - dev
      - staging
      - production
  cluster:
    type: string
    description: Logical cluster identifier used for labeling and placement.
  owner:
    type: string
    description: Owning team or service for accountability and routing.
required:
  - name
  - namespace
  - chart
  - tier
  - cluster
  - owner
```

## Example

```yaml
apiVersion: infra.k8/v1alpha1
kind: XHelmRelease
metadata:
  name: example-xhelmrelease
spec:
  name: external-secrets
  namespace: external-secrets
  chart:
    name: external-secrets
    repository: https://charts.external-secrets.io
    version: 0.10.0
  values: {}
  tier: dev
  cluster: new-dev
  owner: platform-team
```
