# Setting up a ZFS dataset for etcd on TrueNAS (Talos control-plane VM)

> Runbook for hosting a Talos/Kubernetes control-plane VM disk on ZFS without an SSD or SLOG. Written after a homelab control-plane brownout traced to **12-second etcd WAL `fdatasync`** on a shared `sync=standard` dataset backed by spinning disk. See `omni-truenas-control-plane-memory.md` for the incident that led here.

## The problem this solves

etcd is brutal on storage. It `fdatasync`'s on **every** write to its write-ahead log, and it does many small (~4 KB) writes. Its health depends on low fsync latency — etcd wants WAL fsync p99 under ~10 ms and starts logging warnings at 1 s. When fsync is slow you get a cascade that looks like a memory or networking problem but isn't:

```
"msg":"slow fdatasync","took":"11.96s","expected-duration":"1s"
"msg":"apply request took too long" ... "etcdserver: request timed out"
→ etcd health flaps OK ↔ context deadline exceeded
→ apiserver slow → kube-scheduler / kube-controller-manager lose their
  leader lease → CrashLoopBackOff → no scheduling, no rollouts
```

On ZFS, three dataset-level choices decide whether etcd lives or dies on a given pool:

1. **`sync`** — whether ZFS waits for the ZIL (and, on HDD with no SLOG, an extra in-pool write) before acking each etcd fsync.
2. **`recordsize`** — how much write amplification each tiny etcd write incurs.
3. **Isolation** — whether etcd shares a dataset (and its `sync`/`recordsize` policy, and its I/O contention) with everything else.

The default for a TrueNAS VM disk on a bulk HDD pool — `sync=standard`, `recordsize=128K`, shared dataset, no SLOG — is the worst case for etcd.

## Recommended dataset config

| Property | SSD / NVMe pool (ideal) | **HDD-only pool (no SLOG) — the achievable config** |
| --- | --- | --- |
| Dedicated dataset | yes | **yes** |
| `sync` | `standard` (durable + fast) | **`disabled`** (fast; durability covered by etcd backups) |
| `recordsize` | `16K` | **`16K`** |
| `compression` | `lz4` | `lz4` |
| `atime` | `off` | `off` |
| `dedup` | `off` | `off` |
| `special_small_blocks` | `16K` *(only with a mirrored SSD special vdev)* | `0` *(no-op without a special vdev)* |
| `logbias` | `latency` | `latency` |
| `primarycache` | `all` | `all` |
| `copies` | `1` | `1` |
| Backups | recommended | **mandatory** (this is what makes `sync=disabled` safe) |

The HDD column is the one to use when you can't add an SSD or a SLOG. It trades a sliver of crash-durability (recoverable from backups) for the fsync latency etcd actually needs.

## Why each setting

- **Dedicated dataset.** Put the control-plane VM disk in its own dataset (e.g. `tank/vm/talos-cp-etcd`) so its `sync`/`recordsize` policy and I/O don't mingle with other VMs or bulk data. You should never set `sync=disabled` on a shared `default` dataset — you'd weaken durability for unrelated workloads.

- **`sync=disabled` (HDD case).** This is the big lever. With `sync=standard` on a pool with no SLOG, every etcd fsync forces a synchronous ZIL commit *to the same spinning disks*, so a single etcd write waits on HDD seek latency — seconds under load. `sync=disabled` makes ZFS acknowledge writes from RAM and flush them on the normal transaction group (~5 s, `zfs_txg_timeout`).
  - **What you risk, precisely:** ZFS is copy-on-write, so the **pool stays consistent** — no pool corruption, ever. The only exposure is that on an **unclean** host power-loss or crash, etcd writes from the last txg (up to ~5 s) may be lost, which on a single-member etcd can mean a small rollback. **Clean reboots/shutdowns lose nothing.**
  - This is acceptable **only** with working etcd backups (next section). With them, the worst case is "restore etcd snapshot, lose a few seconds of cluster state."

- **`recordsize=16K`.** etcd's WAL writes are small. A 128K recordsize turns every small write into a read-modify-write of a 128K block — large write amplification on a disk that's already the bottleneck. 16K matches etcd's I/O far better. **Caveat: `recordsize` only applies to data written *after* the change** — existing files keep their old block size, so you must rewrite/relocate the disk image for it to take effect (see migration).

- **`compression=lz4`.** Nearly free CPU, shrinks what hits disk, and ZFS skips incompressible blocks automatically. Leave it on. (zstd gives a slightly better ratio at more CPU; not worth it for etcd's small WAL.)

- **`atime=off`.** Stops a metadata write every time a file is *read* — pure overhead for a VM disk image.

- **`dedup=off`.** Dedup forces a synchronous dedup-table (DDT) lookup/update on **every write** — latency injected into the exact path etcd is most sensitive to. The DDT must live in RAM or performance collapses, it grows unbounded with data, and it's miserable to remove later. etcd data has no meaningful duplication to reclaim. Pure downside. Never enable it for etcd (or any DB/VM dataset).

- **`special_small_blocks` (Metadata Special Small Block Size).** A **no-op unless the pool has a special (allocation-class) vdev** — a dedicated SSD/NVMe device for metadata and small blocks. With no special vdev, leave it `0` (that's why TrueNAS defaults it to 0). But if you *can* add one, this is the standout option for etcd on HDD — see "When you can add hardware" below.

- **`logbias=latency`** and **`primarycache=all`** are the defaults and are correct here — keep ZIL on the latency path and let etcd reads serve from ARC.

## Prerequisite: etcd backups (do this first)

`sync=disabled` is only safe because you can recover. Set up **at least one**, ideally both:

1. **Omni automated etcd backups** — Omni can snapshot etcd to an S3-compatible store on a schedule. Configure a backup store and enable per-cluster backups in the Omni UI. This is the hands-off option.
2. **Manual / cron `talosctl` snapshot:**
   ```bash
   talosctl -n <cp-node-ip> etcd snapshot /var/lib/etcd-backup.db
   talosctl -n <cp-node-ip> copy /var/lib/etcd-backup.db ./etcd-$(date +%F).db
   ```

Take one snapshot **right now**, before changing anything.

## Procedure

### Option A — Minimum, no VM move (instant relief)

If you just need the bleeding to stop and can't relocate the disk yet:

1. Take an etcd snapshot (above).
2. In TrueNAS, edit the dataset the VM disk lives in → set **Sync = Disabled** → Save.
3. That's it — it applies immediately to new writes; the 12 s fsync stalls stop within seconds.

Downside: you've changed `sync` on a possibly-shared dataset, and `recordsize` is still 128K (write amplification remains, just no longer fatal once sync isn't blocking). Treat this as a stopgap and follow up with Option B.

### Option B — Proper dedicated, tuned dataset (recommended)

1. **Create the dataset** with the right settings from the start (`recordsize` must be set before the data is written):
   ```bash
   zfs create \
     -o recordsize=16K \
     -o sync=disabled \
     -o compression=lz4 \
     -o atime=off \
     -o logbias=latency \
     tank/vm/talos-cp-etcd
   ```
   (Or create it in the TrueNAS UI with the matching values from the table.)

2. **Take an etcd snapshot** and confirm a backup exists.

3. **Gracefully shut down the control-plane VM** so etcd flushes cleanly (single-member etcd — never hard-power-off):
   ```bash
   talosctl -n <cp-node-ip> shutdown
   ```

4. **Relocate the disk image into the new dataset.** Copying the raw image rewrites every block, so it *adopts the new 16K recordsize* (a `zfs send`/clone would preserve the old block size — use a real copy):
   ```bash
   cp --sparse=always /mnt/tank/.../talos-cp.img /mnt/tank/vm/talos-cp-etcd/talos-cp.img
   ```
   (Use `qemu-img convert` if the disk is qcow2 rather than raw.)

5. **Repoint the VM** at the new disk path (TrueNAS VM → Devices → Disk), keeping the same disk otherwise. **Do not recreate the VM** — that would create a blank disk and you'd lose etcd.

6. **Power on**, then verify (next section).

> If your provider (e.g. an `omni-truenas` infrastructure provider) manages VM specs declaratively, make the disk/dataset change at the provider layer so it isn't reverted on the next reconcile.

## Verify it worked

```bash
N=<cp-node-ip>

# 1. etcd health should be steady OK with no "context deadline exceeded"
talosctl -n $N service etcd

# 2. No more slow-fsync warnings (this was 12s before)
talosctl -n $N logs etcd | grep -iE "slow fdatasync|took too long" | tail
#    -> ideally empty; fsync back to single-digit ms

# 3. Control-plane components stop restarting
kubectl -n kube-system get pods | grep -E 'scheduler|controller-manager|apiserver'
#    -> all Running, restart counts frozen

# 4. Rollouts flow again
kubectl get deploy <name> -o jsonpath='gen={.metadata.generation} observed={.status.observedGeneration}'
#    -> observed == gen
```

## When you can add hardware

`sync=disabled` is a software workaround for missing fast storage. The durable fixes, in order of preference, let you go back to `sync=standard` (full crash durability):

1. **Move the etcd dataset to an all-SSD/NVMe pool.** Best — low latency end to end.
2. **Add a mirrored SSD special vdev + `special_small_blocks` (the standout for etcd-on-HDD).** A special (allocation-class) vdev stores metadata and, when `special_small_blocks` is set, small data blocks on SSD while bulk data stays on HDD. On the etcd dataset, set `recordsize=16K` **and** `special_small_blocks=16K` (≥ recordsize ⇒ *all* of etcd's blocks land on the SSD special vdev). etcd then gets SSD **read and write** latency, so you keep `sync=standard` and full durability.
   - **Why this beats a SLOG for etcd:** a SLOG only absorbs *synchronous writes* and is read only during crash recovery — and if you went `sync=disabled`, a SLOG does nothing. A special vdev relocates the blocks themselves, helping **reads and writes regardless of the `sync` setting**, which fits etcd's small-block, latency-bound profile better.
   - **Caveats — read before adding:** a special vdev is **pool-critical** (if it dies, the whole pool dies) so it **must be mirrored** (2+ SSDs, PLP preferred). On a RAIDZ pool it generally **cannot be removed** once added. Size it for metadata + your small-block data.
3. **Add an SSD/NVMe SLOG to the HDD pool.** A dedicated ZIL device absorbs the synchronous etcd writes at SSD latency while bulk data stays on HDD. Mirror the SLOG if you want to survive its failure. Power-loss-protected (PLP) SSDs strongly preferred. Note: only helps while `sync=standard` (or `always`) — a SLOG is useless under `sync=disabled`.

With option 1, 2, or 3 in place: set `sync=standard` on the etcd dataset and keep `recordsize=16K`, `atime=off`, `compression=lz4`, dedicated dataset, backups. You get etcd-grade latency *and* full durability.

## TL;DR

- etcd needs fast fsync; ZFS `sync=standard` on HDD-without-SLOG can't deliver it → control-plane brownouts.
- No SSD available? **Dedicated dataset + `sync=disabled` + `recordsize=16K` + `atime=off` + etcd backups.** Fast, and crash-recoverable from backups (pool stays consistent regardless).
- Set `recordsize` at creation and copy the disk image in so it takes effect.
- Keep **dedup off** always (DDT lookup on every write = latency/RAM disaster).
- **`special_small_blocks`** does nothing without an SSD special vdev (leave `0`). But a **mirrored** SSD special vdev + `special_small_blocks=16K` is the best HDD-era upgrade — etcd's blocks live on SSD, you keep `sync=standard` durability, and it beats a SLOG (helps reads too, works regardless of `sync`).
- When you can: SSD pool, SSD special vdev, or SSD SLOG lets you return to `sync=standard` with no latency penalty.
