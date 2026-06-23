---
kind: XRoleBinding
group: infra.k8
version: v1alpha1
xrd: xrolebindings.infra.k8
---

# XRoleBinding
Request a Kubernetes RoleBinding with standard labels and ownership metadata applied.

- XRD: xrolebindings.infra.k8
- Group: infra.k8
- Version: v1alpha1
- Spec schema: ./schema/xrolebinding.json
- Full schema: ./schema/xrolebinding.full.json

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
- `roleRef`
- `subjects`

## Provider

- provider-kubernetes

## Related Policy

- libs/tiers/tier.cue

## Behavior

- Creates a RoleBinding in the target namespace.
- RoleRef may point to a Role or ClusterRole.

## Gotchas

- ServiceAccount subjects require a namespace field.
- RoleBinding names must be unique per namespace.


## Spec Schema

This is the OpenAPI schema for the spec field.

```yaml
type: object
description: Desired RoleBinding settings and subject/role references.
example:
  name: team-platform-admins
  namespace: platform-system
  tier: dev
  cluster: new-dev
  owner: platform-team
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: cluster-admin
  subjects:
    - kind: Group
      name: platform-admins
      apiGroup: rbac.authorization.k8s.io
x-docs:
  provider: provider-kubernetes
  policyRefs:
    - libs/tiers/tier.cue
  behavior:
    - Creates a RoleBinding in the target namespace.
    - RoleRef may point to a Role or ClusterRole.
  gotchas:
    - ServiceAccount subjects require a namespace field.
    - RoleBinding names must be unique per namespace.
properties:
  name:
    type: string
    description: RoleBinding resource name to create.
    pattern: ^[a-z][a-z0-9-]*$
  namespace:
    type: string
    description: Namespace where the RoleBinding will be created.
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
  roleRef:
    type: object
    description: Reference to the Role or ClusterRole to bind.
    properties:
      apiGroup:
        type: string
        description: API group of the referenced role (usually rbac.authorization.k8s.io).
      kind:
        type: string
        description: Role type to bind.
        enum:
          - Role
          - ClusterRole
      name:
        type: string
        description: Name of the referenced Role or ClusterRole.
    required:
      - apiGroup
      - kind
      - name
  subjects:
    type: array
    description: Subjects (users, groups, or service accounts) to bind to the role.
    items:
      type: object
      properties:
        kind:
          type: string
          description: Subject kind.
          enum:
            - User
            - Group
            - ServiceAccount
        name:
          type: string
          description: Subject name.
        apiGroup:
          type: string
          description: API group for User or Group subjects.
        namespace:
          type: string
          description: Namespace for ServiceAccount subjects.
      required:
        - kind
        - name
required:
  - name
  - namespace
  - tier
  - cluster
  - owner
  - roleRef
  - subjects
```

## Example

```yaml
apiVersion: infra.k8/v1alpha1
kind: XRoleBinding
metadata:
  name: example-xrolebinding
spec:
  name: team-platform-admins
  namespace: platform-system
  tier: dev
  cluster: new-dev
  owner: platform-team
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: cluster-admin
  subjects:
    - kind: Group
      name: platform-admins
      apiGroup: rbac.authorization.k8s.io
```
