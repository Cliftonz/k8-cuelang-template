---
kind: XResourceQuota
group: infra.k8
version: v1alpha1
xrd: xresourcequotas.infra.k8
---

# XResourceQuota
Request a Kubernetes ResourceQuota with tier-based defaults and ownership metadata.

- XRD: xresourcequotas.infra.k8
- Group: infra.k8
- Version: v1alpha1
- Spec schema: ./schema/xresourcequota.json
- Full schema: ./schema/xresourcequota.full.json

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
- `tier`
- `cluster`
- `owner`
- `hard`

## Provider

- provider-kubernetes

## Related Policy

- platform/policy/resourcequota.cue

## Behavior

- Creates or updates a ResourceQuota in the target namespace.

## Gotchas

- All hard values are strings (e.g., 1Gi, 500m).


## Spec Schema

This is the OpenAPI schema for the spec field.

```yaml
type: object
description: Desired ResourceQuota limits and placement metadata.
example:
  name: platform-default
  namespace: platform-system
  tier: dev
  cluster: new-dev
  owner: platform-team
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
x-docs:
  provider: provider-kubernetes
  policyRefs:
    - platform/policy/resourcequota.cue
  behavior:
    - Creates or updates a ResourceQuota in the target namespace.
  gotchas:
    - All hard values are strings (e.g., 1Gi, 500m).
properties:
  name:
    type: string
    description: ResourceQuota resource name to create.
    pattern: ^[a-z][a-z0-9-]*$
  namespace:
    type: string
    description: Namespace where the ResourceQuota will be created.
    pattern: ^[a-z][a-z0-9-]*$
  tier:
    type: string
    description: Tier used for labeling and quota defaults.
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
  hard:
    type: object
    description: Resource quota hard limits map (e.g., requests.cpu, limits.memory).
    additionalProperties:
      type: string
required:
  - name
  - namespace
  - tier
  - cluster
  - owner
  - hard
```

## Example

```yaml
apiVersion: infra.k8/v1alpha1
kind: XResourceQuota
metadata:
  name: example-xresourcequota
spec:
  name: platform-default
  namespace: platform-system
  tier: dev
  cluster: new-dev
  owner: platform-team
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
```
