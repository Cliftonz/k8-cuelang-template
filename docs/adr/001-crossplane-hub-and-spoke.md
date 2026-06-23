# ADR-001: Crossplane Hub-and-Spoke Architecture

**Status:** Accepted  
**Date:** 2024-09-15  
**Decision Makers:** Platform Team

## Context

We need a consistent, declarative way to provision and manage cluster-level infrastructure (namespaces, RBAC, quotas, network policies, Helm releases) across multiple Kubernetes clusters with varying tiers (dev, staging, production).

Options considered:

1. **Helm umbrella charts** — templated YAML per cluster, version-controlled
2. **Terraform + Kubernetes provider** — HCL-based state management
3. **Crossplane with hub-and-spoke** — XRDs as platform API, Compositions as implementation, hub cluster managing spokes

## Decision

Adopt **Crossplane in a hub-and-spoke model**.

- A single **hub cluster** runs Crossplane, XRDs, Compositions, and Providers
- **Spoke clusters** receive pre-rendered manifests via GitOps (Harness/ArgoCD)
- Platform XRDs define the self-service API surface for infrastructure consumers

## Consequences

- **Positive:** Single control plane for all clusters; XRDs provide a stable, validated API contract; Compositions can evolve independently from consumers
- **Positive:** Hub cluster failures don't affect running spoke workloads (desired state is declaratively stored)
- **Negative:** Adds Crossplane as a dependency; team must learn XRD/Composition patterns
- **Negative:** Hub cluster becomes a single point for infrastructure mutations
