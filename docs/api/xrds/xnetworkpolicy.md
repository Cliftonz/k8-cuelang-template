---
kind: XNetworkPolicy
group: infra.k8
version: v1alpha1
xrd: xnetworkpolicies.infra.k8
---

# XNetworkPolicy
Request a Kubernetes NetworkPolicy with platform defaults and ownership metadata.

- XRD: xnetworkpolicies.infra.k8
- Group: infra.k8
- Version: v1alpha1
- Spec schema: ./schema/xnetworkpolicy.json
- Full schema: ./schema/xnetworkpolicy.full.json

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
- `policy`

## Provider

- provider-kubernetes

## Related Policy

- platform/policy/networkpolicy.cue

## Behavior

- Applies a NetworkPolicy using the raw Kubernetes spec provided in policy.

## Gotchas

- The policy field is passed through without schema validation by this API.
- NetworkPolicy behavior depends on the cluster CNI implementation.


## Spec Schema

This is the OpenAPI schema for the spec field.

```yaml
type: object
description: Desired NetworkPolicy settings and placement metadata.
example:
  name: default-deny
  namespace: platform-system
  tier: dev
  cluster: new-dev
  owner: platform-team
  policy:
    podSelector: {}
    policyTypes:
      - Ingress
      - Egress
x-docs:
  provider: provider-kubernetes
  policyRefs:
    - platform/policy/networkpolicy.cue
  behavior:
    - Applies a NetworkPolicy using the raw Kubernetes spec provided in policy.
  gotchas:
    - The policy field is passed through without schema validation by this API.
    - NetworkPolicy behavior depends on the cluster CNI implementation.
properties:
  name:
    type: string
    description: NetworkPolicy resource name to create.
    pattern: ^[a-z][a-z0-9-]*$
  namespace:
    type: string
    description: Namespace where the NetworkPolicy will be created.
    pattern: ^[a-z][a-z0-9-]*$
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
  policy:
    type: object
    description: Raw NetworkPolicy spec (podSelector, ingress, egress, etc.).
    x-kubernetes-preserve-unknown-fields: true
required:
  - name
  - namespace
  - tier
  - cluster
  - owner
  - policy
```

## Example

```yaml
apiVersion: infra.k8/v1alpha1
kind: XNetworkPolicy
metadata:
  name: example-xnetworkpolicy
spec:
  name: default-deny
  namespace: platform-system
  tier: dev
  cluster: new-dev
  owner: platform-team
  policy:
    podSelector: {}
    policyTypes:
      - Ingress
      - Egress
```
