# Resources Not Rendered (raw-fallback mode)

These resource types have no kubectl-applyable equivalent. Apply the
rest of the bundle, then handle each entry below manually.

## XObjectPatch `metallb-system-psa-privileged`

**Reason:** server-side-apply patch on a resource owned by another controller — no equivalent in raw mode

**Replacement:**

```
After applying the rest of the bundle, run:

  kubectl annotate Namespace/metallb-system \
    \
    <key>=<value> --overwrite

…for each entry in spec.details.annotations / spec.details.labels.
```

**Details:**

```yaml
annotations: {}
labels:
  pod-security.kubernetes.io/enforce: privileged
targetRef:
  apiVersion: v1
  kind: Namespace
  name: metallb-system
```

## XArgoWorkflowTemplate `preview-build`

**Reason:** raw renderer not yet wired — WorkflowTemplate XR uses preserve-unknown-fields config that needs a dedicated #RenderArgoWorkflowTemplate (mirror #RenderArgoSensor)

**Replacement:**

```
Apply the upstream WorkflowTemplate manifest manually until
the raw renderer lands:

  kubectl apply -n argo-workflows -f workflowtemplate-preview-build.yaml

…where the YAML is the unwrapped argoproj.io/v1alpha1
WorkflowTemplate body from composites/<cluster>/argoworkflows.cue's
`config` field.
```

**Details:**

```yaml
name: preview-build
namespace: argo-workflows
```

## XBackupPolicy `velero-openbao-hourly`

**Reason:** raw renderer not yet wired — durable answer is to apply Velero + its Schedule CRs directly via CUE on the CP, not via Argo. Placeholder unblocks raw-coverage CI until the refactor lands.

**Replacement:**

```
Apply the velero.io/v1 Schedule manifest manually until
the raw renderer (or the Velero-direct-from-CUE refactor)
lands:

  kubectl apply -n velero -f schedule-velero-openbao-hourly.yaml

…where the YAML is the velero.io/v1 Schedule body derived
from composites/<cluster>/backuppolicies.cue's spec
(schedule=0 * * * *).
```

**Details:**

```yaml
name: velero-openbao-hourly
schedule: 0 * * * *
```

## XBackupPolicy `velero-cluster-resources-daily`

**Reason:** raw renderer not yet wired — durable answer is to apply Velero + its Schedule CRs directly via CUE on the CP, not via Argo. Placeholder unblocks raw-coverage CI until the refactor lands.

**Replacement:**

```
Apply the velero.io/v1 Schedule manifest manually until
the raw renderer (or the Velero-direct-from-CUE refactor)
lands:

  kubectl apply -n velero -f schedule-velero-cluster-resources-daily.yaml

…where the YAML is the velero.io/v1 Schedule body derived
from composites/<cluster>/backuppolicies.cue's spec
(schedule=0 4 * * *).
```

**Details:**

```yaml
name: velero-cluster-resources-daily
schedule: 0 4 * * *
```

## XBackupPolicy `velero-hermes-daily`

**Reason:** raw renderer not yet wired — durable answer is to apply Velero + its Schedule CRs directly via CUE on the CP, not via Argo. Placeholder unblocks raw-coverage CI until the refactor lands.

**Replacement:**

```
Apply the velero.io/v1 Schedule manifest manually until
the raw renderer (or the Velero-direct-from-CUE refactor)
lands:

  kubectl apply -n velero -f schedule-velero-hermes-daily.yaml

…where the YAML is the velero.io/v1 Schedule body derived
from composites/<cluster>/backuppolicies.cue's spec
(schedule=30 3 * * *).
```

**Details:**

```yaml
name: velero-hermes-daily
schedule: 30 3 * * *
```

## XBackupPolicy `velero-honcho-daily`

**Reason:** raw renderer not yet wired — durable answer is to apply Velero + its Schedule CRs directly via CUE on the CP, not via Argo. Placeholder unblocks raw-coverage CI until the refactor lands.

**Replacement:**

```
Apply the velero.io/v1 Schedule manifest manually until
the raw renderer (or the Velero-direct-from-CUE refactor)
lands:

  kubectl apply -n velero -f schedule-velero-honcho-daily.yaml

…where the YAML is the velero.io/v1 Schedule body derived
from composites/<cluster>/backuppolicies.cue's spec
(schedule=45 3 * * *).
```

**Details:**

```yaml
name: velero-honcho-daily
schedule: 45 3 * * *
```

