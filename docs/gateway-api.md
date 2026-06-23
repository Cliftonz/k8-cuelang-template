# Gateway API + Traefik

[Gateway API](https://gateway-api.sigs.k8s.io/) is the next-gen replacement
for `Ingress`. It splits routing concerns across three roles:

- **GatewayClass** (cluster-admin defines): which controller implements the
  spec (Traefik, Cilium, Istio, etc.).
- **Gateway** (platform team owns): listeners, ports, TLS, allowed-routes
  policy. One per "edge" (LAN, DMZ, internal-only, etc.).
- **HTTPRoute / TLSRoute / GRPCRoute** (app teams own): hostnames + path
  rules + backendRefs. Lives next to the workload.

vs `Ingress`:

| | Ingress | Gateway API |
|---|---|---|
| **Listener config** | annotations + class-specific CRDs | typed Gateway resource |
| **Cross-namespace refs** | annotations + provider-specific | `parentRefs` + `ReferenceGrant` |
| **Path matching** | regex inconsistent across providers | typed `PathPrefix` / `Exact` / `RegularExpression` |
| **TLS** | annotation-driven | first-class listener field |
| **gRPC / TCP / TLS routing** | provider extensions only | first-class `GRPCRoute`, `TCPRoute`, `TLSRoute` |
| **Header / weight matching** | provider-specific annotations | first-class match fields |
| **Status / observability** | none | `status.parents[*]` shows routing state per gateway |

## What we have today

Each LAN service (`*.example.internal`) is exposed via stock `Ingress`
resources rendered from `composites/home/ingresses.cue` → `XIngress`.
This won't go away — Traefik handles both `Ingress` and Gateway in
parallel. Gateway API is added alongside for new services that benefit
from typed routing (gRPC, TLS passthrough, weighted canary, etc.).

## Install order

1. **Apply Gateway API CRDs + Traefik RBAC**:
   ```bash
   ./infrastructure/gateway-api/install.sh
   ```
   Pulls the standard-channel CRDs (v1.5.1) + the Traefik-specific
   ClusterRole that lets the Traefik controller watch Gateway CRs.

2. **Enable the kubernetesGateway provider in Traefik values**:

   In `composites/home/helmreleases.cue` → traefik values:
   ```cue
   providers: kubernetesGateway: enabled: true
   ```

3. **Re-render + apply**:
   ```bash
   make export-cluster CLUSTER=home
   kubectl apply -f clusters/home/helm/xhelmrelease-traefik.yaml
   ```

4. **Verify GatewayClass appears**:
   ```bash
   kubectl get gatewayclass
   # NAME      CONTROLLER                      ACCEPTED   AGE
   # traefik   traefik.io/gateway-controller   True       30s
   ```

5. **Smoke test**:
   ```bash
   kubectl apply -f infrastructure/gateway-api/example-gateway.yaml
   kubectl -n default port-forward svc/whoami 8000:80
   curl -H 'Host: whoami.localhost' http://localhost:8000/
   ```

## Authoring a Gateway-routed service

Two options:

**A. Reuse the LAN gateway** (simplest — define one cluster-wide Gateway
and point HTTPRoutes at it):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: lan
  namespace: traefik
spec:
  gatewayClassName: traefik
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces: {from: All}
```

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: my-app
spec:
  parentRefs:
    - name: lan
      namespace: traefik
  hostnames:
    - my-app.example.internal
  rules:
    - backendRefs:
        - name: my-app
          port: 80
```

If `parentRefs` cross namespaces, you also need a `ReferenceGrant` in
the gateway's namespace.

**B. Per-namespace Gateway** (when isolation matters — different TLS
listeners, separate IPs).

## Pairing with cert-manager

Gateway API has first-class TLS. With cert-manager v1.15+, annotate the
Gateway:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: openbao-example-internal
spec:
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - name: lan-tls
```

cert-manager auto-creates the Certificate, mints from OpenBao PKI, and
keeps it renewed.

## Known issues / gotchas

- The Traefik kubernetesGateway provider runs ALONGSIDE the kubernetesIngress
  provider. Both Ingress and Gateway resources are honored by the same
  Traefik pods.
- ReferenceGrant is required for cross-namespace `backendRefs`. If a
  HTTPRoute → Service in different ns, controller silently drops the
  rule without it.
- The Traefik chart's RBAC needs the rules from
  `kubernetes-gateway-rbac.yml` — applied separately by `install.sh`.
  Without it, the provider logs `forbidden: cannot list httproutes`.

## Reference

- Gateway API: https://gateway-api.sigs.k8s.io/
- Sidero Traefik guide: https://docs.siderolabs.com/kubernetes-guides/advanced-guides/deploy-traefik
- Traefik kubernetesGateway provider: https://doc.traefik.io/traefik/providers/kubernetes-gateway/
