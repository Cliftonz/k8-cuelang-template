# Omni ConfigPatch payloads

One YAML per intended Talos machine-config patch, version-controlled
so a cluster rebuild can replay them in one command.

## Layout

Each `*.payload.yaml` file holds **just** the `machine:` / `cluster:`
block — the raw config-patch content. The Omni ConfigPatch envelope
(metadata + spec.data wrapping) is added at apply time by
[`ci/scripts/apply-omni-patches.sh`](../../../ci/scripts/apply-omni-patches.sh).

Patch IDs are derived from the filename:

  `200-kubelet-cert-rotation.payload.yaml` → `200-kubelet-cert-rotation-<cluster>`

The numeric prefix sets apply order (Omni evaluates patches in
lexicographic order of ID).

## Applying

```bash
ci/scripts/apply-omni-patches.sh talos-home
```

Idempotent. Omni diffs the spec; if nothing changed, no kubelet/
apiserver restart fires.

## Why this exists

Omni ConfigPatches don't carry through a cluster rebuild. The
`200-kubelet-cert-rotation` patch was authored 2026-05-06 during the
Cilium migration but lost in the 2026-05-14 rebuild from base
templates. The gap wasn't noticed until 2026-05-15 when a stuck-
Terminating namespace exposed it.

This directory + apply script means the next rebuild can replay every
patch with one command instead of clicking through the Omni UI.

## What's NOT here

- **`950-discovery-service`** — Omni manages this automatically per
  cluster (the IPv6 ULA endpoint is allocated by Omni). It's owned by
  `DiscoveryServiceConfigPatchController`; users can't apply it.
- **Per-machine-set patches** like `advertised-subnets-...`, `data-volumes-...`,
  `longhorn-ops-...` — these target specific worker machines (by
  machine UUID) and don't survive node replacement anyway. Manage them
  through the Omni UI per node.

## Adding a new cluster-wide patch

1. Write the payload as `{NNN}-{kebab-name}.payload.yaml` here. The
   payload is just the `machine:` and/or `cluster:` block (no wrapper).
2. Run `ci/scripts/apply-omni-patches.sh <cluster>`.
3. Verify in Omni: `omnictl get configpatch -l omni.sidero.dev/cluster=<cluster>`.
