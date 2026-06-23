# Architecture

> See [diagrams.md](diagrams.md) for visual companions to every flow
> described below (build pipeline, cluster topology, per-PR lifecycle,
> secret flow, Cloudflare tunnel, notification routing).

## Overview

This repository defines a Crossplane-centric platform that renders Kubernetes
manifests at build time using CUE. Rendered outputs are promoted as immutable
OCI artifacts and deployed through GitOps.

## Control Plane vs Workload Clusters

- The hub (management) cluster runs Crossplane, XRDs, Compositions, and providers.
- Spoke clusters run workloads only and apply pre-rendered manifests.

## Build and Promotion Flow

1. CUE validates claims against platform schemas.
2. `cue export` renders YAML to a deterministic output.
3. Rendered manifests are packaged as an OCI artifact.
4. Environment repositories reference the artifact digest.
5. GitOps sync applies the promoted artifact to the target cluster.

## Repository Contracts

- `platform/` defines platform APIs (XRDs) and implementations (Compositions).
- `libs/` defines shared schemas and tier defaults.
- `composites/` defines per-cluster desired state inputs for composite resources.
- `export/` is the single render entry point.
