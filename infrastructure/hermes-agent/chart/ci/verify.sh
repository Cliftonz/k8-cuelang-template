#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass() {
  echo "PASS: $*"
  "$@"
}

expect_fail() {
  local label="$1"
  local expected="$2"
  shift 2

  local log_file="$TMP_DIR/${label//[^A-Za-z0-9_.-]/_}.log"
  if "$@" >"$log_file" 2>&1; then
    echo "FAIL: ${label} unexpectedly succeeded"
    cat "$log_file"
    return 1
  fi

  if ! grep -Fq -- "$expected" "$log_file"; then
    echo "FAIL: ${label} did not contain expected error: $expected"
    cat "$log_file"
    return 1
  fi

  echo "PASS: ${label}"
}

expect_render_contains() {
  local label="$1"
  local expected="$2"
  local file="$3"

  if ! grep -Fq -- "$expected" "$file"; then
    echo "FAIL: ${label} missing expected render fragment: $expected"
    return 1
  fi

  echo "PASS: ${label}"
}

cd "$ROOT_DIR"

pass python3 -m json.tool values.schema.json >/dev/null
pass bash -n ci/verify.sh
pass helm lint .
pass helm lint . -f ci/test-values.yaml
pass helm lint . -f ci/existing-claim-values.yaml
pass helm lint . -f ci/external-bootstrap-values.yaml
pass helm lint . -f ci/default-service-ports-values.yaml
pass helm lint . -f ci/external-secret-values.yaml
pass helm lint . -f ci/tenant-isolation-values.yaml
pass helm lint . -f ci/operator-values.yaml
pass helm template hermes . >"$TMP_DIR/default.yaml"
pass helm template hermes . -f ci/test-values.yaml >"$TMP_DIR/test-values.yaml"
pass helm template hermes . -f ci/existing-claim-values.yaml >"$TMP_DIR/existing-claim.yaml"
pass helm template hermes . -f ci/external-bootstrap-values.yaml >"$TMP_DIR/external-bootstrap.yaml"
pass helm template hermes . -f ci/default-service-ports-values.yaml >"$TMP_DIR/default-service-ports.yaml"
pass helm template hermes . -f ci/external-secret-values.yaml >"$TMP_DIR/external-secret.yaml"
pass helm template hermes . -f ci/tenant-isolation-values.yaml >"$TMP_DIR/tenant-isolation.yaml"
pass helm template hermes . -f ci/operator-values.yaml >"$TMP_DIR/operator.yaml"
pass helm template hermes . --include-crds -f ci/operator-values.yaml >"$TMP_DIR/operator-with-crds.yaml"

expect_render_contains \
  "external bootstrap fixture points at the external ConfigMap" \
  'name: hermes-shared-bootstrap' \
  "$TMP_DIR/external-bootstrap.yaml"
if grep -q '^kind: ConfigMap$' "$TMP_DIR/external-bootstrap.yaml"; then
  echo "FAIL: external bootstrap fixture should not render a chart-managed ConfigMap"
  exit 1
fi
echo "PASS: external bootstrap fixture reuses an existing ConfigMap"

expect_render_contains \
  "default service-port fixture renders api-server port" \
  'name: api-server' \
  "$TMP_DIR/default-service-ports.yaml"
expect_render_contains \
  "default service-port fixture renders webhook port" \
  'name: webhook' \
  "$TMP_DIR/default-service-ports.yaml"
expect_render_contains \
  "default service-port fixture renders telegram-webhook port" \
  'name: telegram-webhook' \
  "$TMP_DIR/default-service-ports.yaml"
echo "PASS: default service-port fixture auto-derives common Hermes listener ports"

expect_render_contains \
  "external secret fixture renders ExternalSecret apiVersion" \
  'apiVersion: external-secrets.io/' \
  "$TMP_DIR/external-secret.yaml"
expect_render_contains \
  "external secret fixture renders ExternalSecret kind" \
  'kind: ExternalSecret' \
  "$TMP_DIR/external-secret.yaml"
expect_render_contains \
  "external secret fixture renders the target secret name" \
  'name: hermes-agent-external-secret' \
  "$TMP_DIR/external-secret.yaml"
expect_render_contains \
  "external secret fixture renders the SecretStore reference" \
  'name: "platform-secrets"' \
  "$TMP_DIR/external-secret.yaml"
if grep -q '^kind: Secret$' "$TMP_DIR/external-secret.yaml"; then
  echo "FAIL: external secret fixture should render an ExternalSecret target instead of a chart-managed Secret"
  exit 1
fi
echo "PASS: external secret fixture renders first-class ExternalSecret support"

expect_render_contains \
  "tenant-isolation fixture renders the tenant label" \
  'tenant.hermes.ai/id: "tenant-a"' \
  "$TMP_DIR/tenant-isolation.yaml"
expect_render_contains \
  "tenant-isolation fixture renders the dedicated NetworkPolicy" \
  'name: hermes-multi-tenant' \
  "$TMP_DIR/tenant-isolation.yaml"
expect_render_contains \
  "tenant-isolation fixture allows ingress-nginx traffic" \
  '- ingress-nginx' \
  "$TMP_DIR/tenant-isolation.yaml"
expect_render_contains \
  "tenant-isolation fixture allows istio-system traffic" \
  '- istio-system' \
  "$TMP_DIR/tenant-isolation.yaml"
expect_render_contains \
  "tenant-isolation fixture preserves external-dns Service annotations" \
  'external-dns.alpha.kubernetes.io/hostname: hermes.tenant-a.example.test' \
  "$TMP_DIR/tenant-isolation.yaml"
expect_render_contains \
  "tenant-isolation fixture preserves ingress controller timeout annotations" \
  'nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"' \
  "$TMP_DIR/tenant-isolation.yaml"
expect_render_contains \
  "tenant-isolation fixture preserves Istio gateway configuration" \
  'istio-system/tenant-gateway' \
  "$TMP_DIR/tenant-isolation.yaml"
echo "PASS: tenant-isolation fixture renders tenant isolation plus controller/ingress/Istio configuration"

expect_render_contains   "operator fixture renders HermesTenant custom resource"   'kind: HermesTenant'   "$TMP_DIR/operator.yaml"
expect_render_contains   "operator fixture renders HermesTenant apiVersion"   'apiVersion: hermes.ai/v1alpha1'   "$TMP_DIR/operator.yaml"
expect_render_contains   "operator fixture renders tenant release namespace"   'namespace: "tenant-a"'   "$TMP_DIR/operator.yaml"
if grep -q '^kind: Deployment$' "$TMP_DIR/operator.yaml"; then
  echo "FAIL: operator fixture should not render direct deployment resources"
  exit 1
fi
echo "PASS: operator fixture renders CRs without direct workload resources"
expect_render_contains   "operator include-crds render includes HermesTenant CRD"   'kind: CustomResourceDefinition'   "$TMP_DIR/operator-with-crds.yaml"
expect_render_contains   "operator include-crds render includes hermestenants.hermes.ai"   'name: hermestenants.hermes.ai'   "$TMP_DIR/operator-with-crds.yaml"
echo "PASS: operator fixture includes the CRD when rendered with --include-crds"

expect_fail \
  "telegram webhook URL required" \
  "telegramWebhook.url: String length must be greater than or equal to 1" \
  helm lint . --set telegramWebhook.enabled=true

expect_fail \
  "service exposure requires ports or enabled endpoints" \
  "service.ports: Array must have at least 1 items" \
  helm lint . -f ci/negative-service-values.yaml

expect_fail \
  "persistent replicas limited to one" \
  "replicaCount: replicaCount does not match: 1" \
  helm lint . -f ci/negative-persistent-replicas-values.yaml

expect_fail \
  "virtual service gateways required" \
  "virtualService.gateways: Array must have at least 1 items" \
  helm lint . --set service.enabled=true --set apiServer.enabled=true --set virtualService.enabled=true

expect_fail \
  "external secret store reference required" \
  "externalSecret.secretStoreRef.name" \
  helm lint . -f ci/external-secret-values.yaml --set externalSecret.secretStoreRef.name=

expect_fail \
  "tenant isolation requires tenant id" \
  "tenant.id" \
  helm lint . -f ci/tenant-isolation-values.yaml --set tenant.id=

expect_fail \
  "operator mode requires controller class" \
  "operator.controllerClass" \
  helm lint . -f ci/operator-values.yaml --set operator.controllerClass=
