# Why Crossplane + CUE Instead of Helm Alone

This repo uses Crossplane compositions and CUE to define platform resources. Helm is still used for packaging third-party apps, but it is not the primary control plane.

## Short Answer

Helm is great for installing applications. It is not a control plane for multi-team infrastructure with policy, validation, and promotion requirements. Crossplane + CUE gives us stronger contracts, safer defaults, and a repeatable promotion path across environments.

## What Helm Alone Does Not Give Us

- **API contracts**: Helm values are loosely typed. We need strict schemas for cluster inputs (tier, owner, quotas, policies).
- **Policy enforcement**: Helm does not enforce organization-wide defaults and guardrails consistently.
- **Cross-cluster promotion**: Helm charts do not provide a native promotion model with immutable artifacts and digest pinning.
- **Separation of concerns**: Helm mixes app deployment and platform APIs. We need a platform API that teams can consume safely.

## Why Crossplane + CUE

- **Typed, validated inputs**: CUE enforces data shape and constraints before changes are applied.
- **Platform API**: XRDs and Compositions expose a stable interface to consumers (`XNamespace`, `XNetworkPolicy`, etc.).
- **Consistent policy**: Labels, quotas, and network policy defaults are enforced centrally.
- **Deterministic rendering**: CUE renders manifests deterministically, which improves review and diffing.
- **Promotion flow**: Rendered output is packaged as an artifact and promoted with digest pinning.

## Where Helm Still Fits

We still use Helm, but as an **implementation detail** behind Crossplane. Provider Helm installs charts as composed resources. This gives us the governance and validation that Helm alone lacks.

## Onboarding Concerns and Mitigations

- **Learning curve**: We provide concrete examples and templates in `composites/`.
- **Predictability**: `make validate` and `make export-split` show exactly what will be applied.
- **Incremental adoption**: Teams can start with namespaces and quotas before using HelmRelease composites.

## Tradeoffs

- **More moving parts**: Crossplane and providers introduce operational overhead.
- **Initial setup cost**: Bootstrapping takes longer than a single Helm install.
- **Tooling knowledge**: CUE and Crossplane are less common than Helm.

We accept these tradeoffs because the platform requires consistent policy, validation, and promotion across environments.

## Summary

Helm is still part of the stack, but it is not sufficient as a platform control plane. Crossplane + CUE gives us the guardrails, contracts, and promotion workflow we need to operate safely at scale.
