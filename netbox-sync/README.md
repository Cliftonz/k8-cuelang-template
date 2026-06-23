# netbox-sync

Reflective population of [NetBox](https://netboxlabs.com) (the `your-netbox-tenant` Cloud
instance) from the live homelab. **Discover → NetBox**: live systems are the
truth, these scripts mirror reality into NetBox so it becomes the IPAM /
documentation / (eventual) automation source-of-truth.

This is **not** CUE and does not render cluster YAML. It is a standalone Python
toolchain that co-locates with the infra it documents. The eventual in-cluster
CronJob reconciler (P5) builds on these same scripts.

## Direction of truth

```
live systems  ──discover──▶  netbox-sync  ──idempotent upsert──▶  NetBox
```

NetBox is never the writer back to systems in this phase (reflective). Flipping
select slices to authoritative (NetBox → MetalLB pools, DNS) is a deferred,
separate decision (P6).

## Layer → source map

| Layer        | Source of truth          | Script              | Status |
| ------------ | ------------------------ | ------------------- | ------ |
| k8s          | `kubectl` (Talos home)   | `sync_k8s.py`       | P1 ✅   |
| network      | UniFi controller API     | `sync_unifi.py`     | P2 (needs UniFi creds) |
| edge/public  | Ingress + Cloudflare DNS | `sync_edge.py`      | P3     |
| physical     | `talosctl` node hardware | `sync_physical.py`  | P4     |

## Backbone

**Pure pynetbox**, idempotent upserts keyed on natural keys (slug / name / vid /
address). No Diode (declined — token-only, no add-on cost, we own idempotency).
All writes route through `nbclient.NB.ensure()` so the ingestion path is a
single seam if we ever swap backends.

## Setup

```bash
cd netbox-sync
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env            # then paste your real 40-char NetBox token
```

Mint the token in NetBox Cloud → avatar → **API Tokens** → Add (keep write
enabled). The placeholder shipped in the MCP config is invalid.

## Run

```bash
. .venv/bin/activate
python sync_k8s.py --dry-run     # prints planned creates/updates, writes nothing
python sync_k8s.py               # applies
```

`--dry-run` is the default-safe way to see drift before touching NetBox.

## Idempotency contract

Every object is matched by a natural key and only the drifted scalar fields are
patched. Re-running is a no-op when reality is unchanged. Nothing is ever
deleted automatically (reflective adds/updates only); pruning stale objects is a
deliberate future flag, mirroring the home cluster's no-implicit-teardown stance.
