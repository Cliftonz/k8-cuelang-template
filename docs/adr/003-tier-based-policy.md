# ADR-003: Tier-Based Policy Enforcement

**Status:** Accepted  
**Date:** 2024-10-05  
**Decision Makers:** Platform Team, Security

## Context

Different environments require different policy strictness levels. Development clusters need flexibility for rapid iteration, while production clusters need strict enforcement to prevent incidents.

## Decision

Implement a **three-tier policy model** (dev, staging, production) with enforcement escalation:

| Aspect | Dev | Staging | Production |
|---|---|---|---|
| Kyverno mode | Audit | Enforce | Enforce |
| Network policy | Deny all + DNS | Deny all + DNS + monitoring | Deny all + DNS + monitoring |
| Resource quotas | 1cpu/1Gi req, 2cpu/2Gi limit | 2cpu/2Gi req, 4cpu/4Gi limit | 4cpu/4Gi req, 8cpu/8Gi limit |

- Tier definitions live in `libs/tiers/` and implement `#TierConfig`
- Policies reference tier defaults so changes propagate automatically
- Kyverno `validationFailureActionOverrides` enforce per-namespace based on `infra.k8/tier` label

## Consequences

- **Positive:** Developers get early warnings in dev without blocking; production is protected
- **Positive:** Single tier definition drives quotas, policies, and enforcement mode
- **Negative:** Tier boundaries must be carefully maintained; a mis-labeled namespace gets wrong policies
