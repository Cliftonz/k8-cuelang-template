# Add OpenTelemetry (OTLP) support for metrics, traces, and logs

## Current behavior

Kelos v0.29.0 exposes Prometheus metrics via controller-runtime's default
`metricsserver` on `--metrics-bind-address=:8080`. That's scrapeable,
but the only exposed surface is Prometheus — there is no OTLP exporter
for metrics, no tracing instrumentation, and no OTEL logs pipeline.

`go.mod` confirms: no `go.opentelemetry.io/*` dependencies; only
`github.com/prometheus/client_golang`.

The `telemetry` package and `kelos-telemetry` CronJob are unrelated —
they send anonymous aggregate usage stats to kelos-dev's PostHog
endpoint (daily heartbeat, version/count rollup). That is product
analytics, not observability telemetry.

Operators running Kelos in a mixed-signal observability stack (OTEL
Collector → Grafana/Honeycomb/Datadog/Tempo/Loki/etc.) today have two
options:

1. Stand up a Prometheus scrape + OTEL Collector bridge just for Kelos,
   doubling the collector config footprint
2. Skip Kelos metrics entirely and rely on log parsing

Neither gives distributed traces of TaskSpawner → Task → agent pod, which
would be the highest-value signal for debugging why a particular agent
run stalled, which GitHub API call throttled, which webhook processing
step hung, etc.

## Expected behavior

Kelos should emit:

1. **Metrics via OTLP/gRPC or OTLP/HTTP** — push to the endpoint set by
   the standard `OTEL_EXPORTER_OTLP_ENDPOINT` env var (plus the usual
   `OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_SERVICE_NAME`,
   `OTEL_RESOURCE_ATTRIBUTES`). Falls back to the existing Prometheus
   endpoint if OTLP env vars are unset — zero-migration for existing
   operators.
2. **Traces** — instrument the reconcile loop on each controller
   (TaskSpawner, Task, AgentConfig, Workspace) so one trace per reconcile
   shows discovery → CRD update → spawn. Controller-runtime has
   pluggable `trace.TracerProvider` hooks — wiring is straightforward.
3. **Task-level spans** — propagate a trace through the agent pod
   lifecycle (git clone init container → agent container → capture
   container). Agent container can emit spans into the same trace via
   `OTEL_EXPORTER_OTLP_ENDPOINT` passed through the spawner.
4. **Logs via OTLP/logs** — optional, less urgent; stdout + a sidecar
   collector still works for most stacks.

Minimum viable: (1) and (2). (3) and (4) can land later.

## Steps to reproduce (current state observation)

1. Install Kelos per the Quick Start: `kelos install`.
2. Inspect the controller's observability surface:

   ```bash
   kubectl port-forward -n kelos-system deploy/kelos-controller-manager 8080
   curl -s http://localhost:8080/metrics | head -20
   ```

   You see Prometheus-format metrics (controller-runtime defaults).

3. Check for OTLP-related env vars the controller honors:

   ```bash
   kubectl exec -n kelos-system deploy/kelos-controller-manager -- /kelos --help 2>&1 | grep -i otel
   # No matches.
   ```

4. Attempt to configure an OTLP export target:

   ```bash
   kubectl set env deploy/kelos-controller-manager -n kelos-system \
     OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317 \
     OTEL_SERVICE_NAME=kelos-controller
   ```

   Controller restarts. **No traces or metrics ever appear at the
   collector** — the env vars are ignored because Kelos doesn't link in
   an OTLP exporter.

5. Confirm in `go.mod`:

   ```bash
   grep -i otel go.mod
   # (no output)
   ```

## Anything else

### Environment

| Field | Value |
|---|---|
| Kelos version | v0.29.0 |
| Controller-runtime | v0.23.1 |
| Go | 1.22+ (per go.mod) |
| Cluster | Kubernetes 1.35.2 on Talos Linux |

### Scope suggestion for a first PR

Keep it additive and opt-in:

1. Add dependencies: `go.opentelemetry.io/otel`,
   `go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc`,
   `go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc`,
   `go.opentelemetry.io/otel/sdk/{metric,trace,resource}`.
2. In `cmd/kelos-controller/main.go`, after `opts.Scheme` is set,
   initialise a `MeterProvider` + `TracerProvider` when
   `OTEL_EXPORTER_OTLP_ENDPOINT` is set. Pass them into
   controller-runtime's `Manager` options (`Manager.MetricsBindAddress`
   gets a dual-export setup, `Manager.Controller.SkipNameValidation`
   unchanged).
3. Wrap each reconcile method with a span:

   ```go
   ctx, span := tracer.Start(ctx, "reconcile.TaskSpawner")
   defer span.End()
   ```

4. For the spawner pod (`cmd/kelos-spawner`), same treatment with a
   separate `OTEL_SERVICE_NAME=kelos-spawner` resource label.
5. Document the env vars in `docs/reference.md` alongside the existing
   `--metrics-bind-address` flag.

(3) and (4) — agent Task span injection, log pipeline — can be
follow-up PRs once the core is in.

### Related Kelos features that would benefit immediately

- **Task failure debugging** — a trace showing "spawner discovered N items
  → Task created → git clone init → agent runtime: 3m42s → capture exit
  code" eliminates the current "read 100KB of JSONL logs" workflow.
- **PR comment latency investigation** — `githubIssues` polling has a
  `pollInterval` floor of 5m; traces would surface where time goes
  (GitHub API, CRD update, Task create delay, agent startup).
- **Multi-cluster operator view** — when operators run Kelos in several
  clusters, OTLP into a single collector gives the aggregate view
  Prometheus federation can't cleanly do.

### Happy to send a PR

If maintainers agree with the approach, I can submit a PR implementing
the controller-side metrics + reconcile spans (item 1, 2, 3, 5) against
`main`. Let me know.

### Contact

| Field | Value |
|---|---|
| Requester | _fill in before submission_ |
| Org | _fill in before submission_ |
| Severity | Low (feature request; Prometheus works) |
| Preferred channel | GitHub issue on `kelos-dev/kelos` |
