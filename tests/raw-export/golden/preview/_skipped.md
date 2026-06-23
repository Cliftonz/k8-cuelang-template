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

## XObjectPatch `longhorn-frontend-omni-proxy`

**Reason:** server-side-apply patch on a resource owned by another controller — no equivalent in raw mode

**Replacement:**

```
After applying the rest of the bundle, run:

  kubectl annotate Service/longhorn-frontend \
    -n longhorn-system \
    <key>=<value> --overwrite

…for each entry in spec.details.annotations / spec.details.labels.
```

**Details:**

```yaml
annotations:
  omni-kube-service-exposer.sidero.dev/port: "50082"
  omni-kube-service-exposer.sidero.dev/label: Longhorn
  omni-kube-service-exposer.sidero.dev/prefix: longhorn
labels: {}
targetRef:
  apiVersion: v1
  kind: Service
  name: longhorn-frontend
  namespace: longhorn-system
```

