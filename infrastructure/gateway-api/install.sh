#!/usr/bin/env bash
# Install the Gateway API CRDs (standard channel) + the Traefik
# kubernetes-gateway RBAC bundle. After this runs, our existing Traefik
# Helm release just needs `providers.kubernetesGateway.enabled: true`
# in its values to register itself as the GatewayClass `traefik`.
#
# Usage:
#   ./infrastructure/gateway-api/install.sh
#   GW_API_VERSION=v1.5.1 TRAEFIK_VERSION=v3.5 ./infrastructure/gateway-api/install.sh
#
# Idempotent — kubectl apply on the same manifests is a no-op.

set -euo pipefail

GW_API_VERSION="${GW_API_VERSION:-v1.5.1}"
TRAEFIK_VERSION="${TRAEFIK_VERSION:-v3.5}"

log() { printf "[gateway-api] %s\n" "$*"; }

kubectl version --request-timeout=5s >/dev/null 2>&1 \
  || { echo "kubectl can't reach the cluster" >&2; exit 1; }

log "applying Gateway API standard-channel CRDs ${GW_API_VERSION}..."
kubectl apply -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GW_API_VERSION}/standard-install.yaml"

log "applying Traefik kubernetes-gateway RBAC ${TRAEFIK_VERSION}..."
kubectl apply -f \
  "https://raw.githubusercontent.com/traefik/traefik/${TRAEFIK_VERSION}/docs/content/reference/dynamic-configuration/kubernetes-gateway-rbac.yml"

log "verifying CRDs..."
kubectl get crd \
  gatewayclasses.gateway.networking.k8s.io \
  gateways.gateway.networking.k8s.io \
  httproutes.gateway.networking.k8s.io 2>&1 | head -5

log "done."
log "Next: enable providers.kubernetesGateway.enabled=true in the Traefik"
log "Helm release values (composites/home/helmreleases.cue → traefik), re-render"
log "+ apply, then check 'kubectl get gatewayclass traefik' shows Accepted=True."
