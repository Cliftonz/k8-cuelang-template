# Optional: ExternalDNS via UniFi Webhook

Adds an in-cluster ExternalDNS that publishes records to your UniFi
controller (UDM/UDM Pro/UDR), so LAN clients resolve preview hostnames
locally without round-tripping through Cloudflare's edge.

Gated behind a build flag — **off by default**. Cluster works fine
without it. Enable when you actually want LAN-side split-horizon DNS.

Upstream: <https://github.com/kashalls/external-dns-unifi-webhook>

## What gets deployed (when enabled)

| Resource | Namespace | Source |
| --- | --- | --- |
| `Namespace` external-dns | — | `composites/preview/externaldns.cue` |
| `HelmRelease` external-dns-unifi (chart `external-dns/external-dns` 1.15.0) | external-dns | same |
| `ExternalSecret` external-dns-unifi-secret | external-dns | same, syncs from `secret/preview/unifi` |

ExternalDNS runs with the kashalls webhook sidecar
(`ghcr.io/kashalls/external-dns-unifi-webhook:v0.8.2`), policy
`create-only`, sources `ingress`+`service`, domain filter
`preview.example.internal`. Adjust the domain in
[composites/preview/externaldns.cue](../composites/preview/externaldns.cue)
(`_domainFilter`) before enabling if you want a different LAN zone.

## 1. Get a UniFi API key

UniFi Network Application → **Settings → Admins & Users → Add admin** →
choose **API Key only** access. Copy the key once shown — UniFi will
not display it again.

## 2. Seed the secret in OpenBao

```bash
kubectl port-forward -n openbao svc/openbao 8200:8200 &
export BAO_ADDR=http://localhost:8200
export BAO_TOKEN=$(kubectl get secret openbao-keys -n openbao -o jsonpath='{.data.root-token}' | base64 -d)

bao kv put -mount=secret preview/unifi \
  host="https://192.168.1.1" \
  api_key="<paste API key here>" \
  external="false"
```

`external` is `"false"` for tunnels running on UniFi hardware (the
common case). Set `"true"` only if the controller is hosted on
non-UniFi hardware (cloud VM, separate server).

## 3. Render + apply with the flag on

```bash
# Render only (preview the change)
make export-cluster CLUSTER=preview UNIFI=true
# Apply
make apply CLUSTER=preview UNIFI=true
```

Three new resources will appear under `clusters/preview/`:

```
clusters/preview/namespaces/xnamespace-external-dns.yaml
clusters/preview/helm/xhelmrelease-external-dns-unifi.yaml
clusters/preview/xexternalsecret-external-dns-unifi-secret.yaml
```

## 4. Verify

```bash
# HelmRelease + pod
kubectl get release.helm.crossplane.io external-dns-unifi
kubectl get pods -n external-dns

# Secret synced
kubectl get externalsecret -n external-dns

# Logs — look for "all records are already up to date"
kubectl logs -n external-dns deploy/external-dns-unifi -c external-dns --tail=30
kubectl logs -n external-dns deploy/external-dns-unifi -c webhook       --tail=30
```

Add an `Ingress` with a host inside `preview.example.internal`; ExternalDNS
will create the record on the UniFi controller within a minute.

## Disable

Render without the flag (default):

```bash
make apply CLUSTER=preview
# the 3 unifi resources are NOT in the rendered output, but kubectl apply
# does NOT delete resources that disappear from the manifest set.
```

To actually remove from the cluster after disabling the flag:

```bash
kubectl delete xhelmrelease   external-dns-unifi
kubectl delete xexternalsecret external-dns-unifi-secret
kubectl delete xnamespace      external-dns
```

OpenBao secret stays put — leave it for next time, or
`bao kv delete -mount=secret preview/unifi` to clear.
