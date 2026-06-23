---
kind: XNodeTaint
group: infra.k8
version: v1alpha1
xrd: xnodetaints.infra.k8
---

# XNodeTaint
Request taints to be applied to a specific Kubernetes node.

- XRD: xnodetaints.infra.k8
- Group: infra.k8
- Version: v1alpha1
- Spec schema: ./schema/xnodetaint.json
- Full schema: ./schema/xnodetaint.full.json

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
- `cluster`
- `owner`
- `nodeName`
- `taints`

## Provider

- provider-kubernetes

## Behavior

- Patches the target Node to include the specified taints.
- The Node resource is orphaned on composite deletion.

## Gotchas

- The composite does not remove taints when deleted.
- Node names are cluster-specific; ensure the node exists.


## Spec Schema

This is the OpenAPI schema for the spec field.

```yaml
type: object
description: Desired node taints and ownership metadata.
example:
  name: gpu-nodes
  cluster: new-dev
  owner: platform-team
  nodeName: ip-10-0-0-10.us-east-2.compute.internal
  taints:
    - key: dedicated
      value: gpu
      effect: PreferNoSchedule
x-docs:
  provider: provider-kubernetes
  policyRefs: []
  behavior:
    - Patches the target Node to include the specified taints.
    - The Node resource is orphaned on composite deletion.
  gotchas:
    - The composite does not remove taints when deleted.
    - Node names are cluster-specific; ensure the node exists.
properties:
  name:
    type: string
    description: Unique identifier for this node taint request.
    pattern: ^[a-z][a-z0-9-]*$
  cluster:
    type: string
    description: Logical cluster identifier used for labeling and placement.
  owner:
    type: string
    description: Owning team or service for accountability and routing.
  nodeName:
    type: string
    description: Kubernetes node name to receive the taint.
    pattern: ^[a-z][a-z0-9.-]*$
  taints:
    type: array
    description: List of taints to apply to the node.
    items:
      type: object
      properties:
        key:
          type: string
          description: Taint key to apply.
        value:
          type: string
          description: Optional taint value.
        effect:
          type: string
          description: Taint effect applied by the scheduler.
          enum:
            - NoSchedule
            - NoExecute
            - PreferNoSchedule
      required:
        - key
        - effect
    minItems: 1
required:
  - name
  - cluster
  - owner
  - nodeName
  - taints
```

## Example

```yaml
apiVersion: infra.k8/v1alpha1
kind: XNodeTaint
metadata:
  name: example-xnodetaint
spec:
  name: gpu-nodes
  cluster: new-dev
  owner: platform-team
  nodeName: ip-10-0-0-10.us-east-2.compute.internal
  taints:
    - key: dedicated
      value: gpu
      effect: PreferNoSchedule
```
