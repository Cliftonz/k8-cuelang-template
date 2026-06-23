# Helm immutable-field upgrade failures

## The failure mode

Platform components are installed as `XHelmRelease` claims rendered to
provider-helm `Release` resources. provider-helm runs `helm upgrade` in
place when a release's `spec.forProvider.chart.version` changes.

`helm upgrade` patches existing Kubernetes objects. Some object fields are
**immutable** — the apiserver rejects any patch that changes them:

| Kind | Immutable field(s) |
| --- | --- |
| `RoleBinding`, `ClusterRoleBinding` | `.roleRef` |
| `Deployment`, `StatefulSet`, `DaemonSet`, `ReplicaSet`, `Job` | `.spec.selector` |
| `StatefulSet` | `.spec.serviceName`, `.spec.volumeClaimTemplates` |
| `PersistentVolumeClaim` | `storageClassName`, `accessModes`, `volumeMode`, size (shrink) |
| `Service` | headless ↔ ClusterIP (`.spec.clusterIP: None`) |

When a chart bump changes one of these for an object that already exists,
`helm upgrade` fails atomically and the provider-helm `Release` goes to
`STATE=failed`. provider-helm has **no `--force`/recreate knob**, so it
cannot fix this itself — it retries the same rejected patch. Our
composition sets `rollbackLimit: 3`, so after three failed attempts it
rolls back to the previous revision: the release stays `Ready` on the
**old** version rather than wedging forever, but the new version never
lands until a human deletes the offending object.

Real example: `cloudflare-tunnel-ingress-controller` 0.0.15 → 0.0.23
switched its `RoleBinding`'s `roleRef` from a `ClusterRole` to a `Role`.

## Prevention: the render-diff guard

[`ci/scripts/check-helm-immutable.sh`](../ci/scripts/check-helm-immutable.sh)
renders every bumped chart at its old and new versions (each with its own
desired values) and diffs the immutable fields above. Any difference is
reported with the exact `kubectl delete` that lets the next upgrade land.

- **CI** — [`.github/workflows/check-helm-immutable.yml`](../.github/workflows/check-helm-immutable.yml)
  runs it on every PR that touches a `helmreleases.cue`, comparing the PR
  head against its base. A flagged bump fails the check before it is ever
  applied.
- **Local, read-only:**
  ```bash
  make helm-immutable-check CLUSTER=home          # vs last commit (HEAD)
  make helm-immutable-check CLUSTER=home BASE_REF=origin/main
  ```
- **Local, remediate + land the upgrade:**
  ```bash
  make helm-immutable-fix CLUSTER=home            # prints the deletes, runs none
  make helm-immutable-fix CLUSTER=home CONFIRM=1  # executes the deletes
  make apply CLUSTER=home                          # helm recreates the objects
  ```

The deletes are brief (the object is recreated by the next apply) but are
real cluster mutations — `CONFIRM=1` is required to execute them.

## What the guard does *not* catch

- **Orphaned cluster state** that no longer appears in the rendered chart
  (e.g. a stale `VolumeSnapshotLocation` left from an old velero config).
  That is not a chart-version diff, so a render-diff cannot see it — delete
  the orphan directly.
- **Values-schema incompatibilities** that only fail at real install time.
  `cue vet` validates our claim schema, not the upstream chart's values
  schema. Soak a major bump on the preview cluster if that risk is real.
