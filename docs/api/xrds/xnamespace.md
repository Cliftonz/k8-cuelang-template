---
kind: XNamespace
group: infra.k8
version: v1alpha1
xrd: xnamespaces.infra.k8
---

# XNamespace
Request a Kubernetes namespace with standard labels and policy defaults applied by the platform.

- XRD: xnamespaces.infra.k8
- Group: infra.k8
- Version: v1alpha1
- Spec schema: ./schema/xnamespace.json
- Full schema: ./schema/xnamespace.full.json

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
- `tier`
- `cluster`
- `owner`

## Provider

- provider-kubernetes

## Related Policy

- libs/tiers/tier.cue
- platform/policy/networkpolicy.cue
- platform/policy/resourcequota.cue

## Behavior

- Creates a Kubernetes Namespace with standard labels applied.
- Deletion behavior follows the composition's deletion policy.

## Gotchas

- Namespace names must be DNS-1123 compatible and unique per cluster.


## Spec Schema

This is the OpenAPI schema for the spec field.

```yaml
type: object
description: Desired namespace settings and ownership metadata used by the platform.
example:
  name: team-platform
  tier: dev
  cluster: new-dev
  owner: platform-team
x-docs:
  provider: provider-kubernetes
  policyRefs:
    - libs/tiers/tier.cue
    - platform/policy/networkpolicy.cue
    - platform/policy/resourcequota.cue
  behavior:
    - Creates a Kubernetes Namespace with standard labels applied.
    - Deletion behavior follows the composition's deletion policy.
  gotchas:
    - Namespace names must be DNS-1123 compatible and unique per cluster.
properties:
  name:
    type: string
    description: Namespace name to create in the target cluster. Must be DNS-1123 compatible.
    pattern: ^[a-z][a-z0-9-]*$
  tier:
    type: string
    description: Tier used to select defaults like quota and policy behavior.
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
  - tier
  - cluster
  - owner
```

## Example

```yaml
apiVersion: infra.k8/v1alpha1
kind: XNamespace
metadata:
  name: example-xnamespace
spec:
  name: team-platform
  tier: dev
  cluster: new-dev
  owner: platform-team
```
