# API Deprecation Process

## Purpose

Establish a predictable, low-risk process for deprecating Crossplane platform APIs so teams have clear timelines, warnings, and upgrade paths.

## Scope

Applies to all platform XRDs and compositions in this repository (group: infra.k8).

## Principles

- CRD stays live for 6 months.
- Warnings first, enforcement later.
- One canonical source of truth for timelines.
- Changes are communicated early and repeated.

## Roles

- Platform Owner: approves deprecation plan and timeline.
- Platform Engineer: implements versioning, warnings, and removal.
- Service Owner: upgrades workloads before the deadline.

## Lifecycle

### 1) Proposal and Approval

- Create a short design note with:
  - API(s) and versions affected
  - Replacement version (for example, v1beta1)
  - Deprecation start date and sunset date (>= 6 months)
  - Migration notes and examples
- Get approval from the Platform Owner.

### 2) Implementation

- Add the new XRD version under spec.versions.
- Keep the old version served and referenceable during the window.
- Update Compositions to support the new version.
- Add deprecation warnings:
  - Native deprecation warnings when supported.
  - Kyverno audit policy to flag old apiVersion usage.

### 2a) Alpha and Beta Promotion

- Add alpha and beta XRD versions (for example, v1alpha2 and v1beta1) alongside stable.
- Use standard Kubernetes versioning rules:
  - alpha: experimental, no compatibility guarantees.
  - beta: stable schema, no breaking changes.
- Keep alpha/beta served during evaluation, but do not remove stable until exit criteria are met.
- Promotion gates:
  - alpha -> beta: tests pass, migration docs exist, and at least one non-prod cluster validates.
  - beta -> stable: adoption targets met, no open blocker issues, and 1-2 release cycles of stable behavior.

### 3) Communication

- Announce in release notes and the platform channel:
  - What is deprecated
  - The sunset date
  - Required migration actions
- Repeat the warning at 3 months, 1 month, and 1 week before sunset.

### 4) Enforcement

- On sunset date:
  - Change Kyverno policy to Enforce (optional but recommended).
  - Remove old version from XRD spec.versions or mark served: false.

### 5) Removal

- Remove old version from compositions and documentation.
- Remove Kyverno deprecation policy for the old version.
- Update changelog with final removal notice.

## Warning Mechanisms

### Native API Warnings

When supported, set deprecated and deprecationWarning in the old version so
clients receive a standard API warning during create/update.

### Kyverno Audit Policy

Use validationFailureAction: Audit to warn on old apiVersion usage. Target
namespaces with app-dev=true first; expand scope as needed.

## Operational Checklist

- [ ] New XRD version added
- [ ] Old version still served
- [ ] Compositions updated for new version
- [ ] Migration examples added
- [ ] Warning policies enabled
- [ ] Communication sent
- [ ] Sunset date confirmed
- [ ] Enforcement applied
- [ ] Old version removed

## Example Timeline (6 Months)

- Day 0: New version released, warnings enabled
- Day 90: Reminder announcement
- Day 150: Final warning
- Day 180: Enforcement + removal

## Notes

- Avoid batch-updating all APIs unless necessary.
- Prefer per-API versioning and phased rollouts.
- Track status in the platform release notes.
