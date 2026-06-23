#!/usr/bin/env python3
"""P1 - reflect the k8s layer (Talos home cluster) into NetBox.

Models:
  site -> cluster-type -> cluster
  nodes        -> virtual machines (+ eth0 interface, primary IPv4)
  node subnets -> prefixes
  pod CIDRs    -> prefixes
  MetalLB pools-> IP ranges (or prefixes for CIDR pools)
  LB svc VIPs  -> IP addresses (described by namespace/name)

Run `python sync_k8s.py --dry-run` first to see planned changes.
"""
from __future__ import annotations

import argparse
import ipaddress
import sys

import config
from nbclient import NB
from sources import k8s


def supernet24(ip: str) -> str:
    return str(ipaddress.ip_interface(f"{ip}/24").network)


def main() -> int:
    ap = argparse.ArgumentParser(description="Reflect the k8s layer into NetBox.")
    ap.add_argument("--dry-run", action="store_true",
                    help="print planned creates/updates, write nothing")
    args = ap.parse_args()

    nb = NB(dry_run=args.dry_run)
    mode = "DRY-RUN" if args.dry_run else "APPLY"
    print(f"== netbox-sync k8s layer [{mode}] -> {config.NETBOX_URL} ==")

    # --- managed marker tag --------------------------------------------------
    tag, _ = nb.ensure(nb.api.extras.tags,
                       key={"slug": config.MANAGED_TAG},
                       defaults={"name": config.MANAGED_TAG, "color": "00bcd4"})
    tag_ref = [tag.id] if tag else []

    # --- site / cluster ------------------------------------------------------
    print("- site / cluster")
    site, _ = nb.ensure(nb.api.dcim.sites,
                        key={"slug": config.SITE_SLUG},
                        defaults={"name": config.SITE_NAME, "status": "active",
                                  "tags": tag_ref})
    ctype, _ = nb.ensure(nb.api.virtualization.cluster_types,
                         key={"name": config.CLUSTER_TYPE},
                         defaults={"slug": config.CLUSTER_TYPE, "tags": tag_ref})
    cluster, _ = nb.ensure(
        nb.api.virtualization.clusters,
        key={"name": config.CLUSTER_NAME},
        defaults={"type": (ctype.id if ctype else None),
                  "scope_type": "dcim.site", "scope_id": (site.id if site else None),
                  "status": "active", "tags": tag_ref},
        create_key={"name": config.CLUSTER_NAME},
    )

    nodes = k8s.get_nodes()

    # --- prefixes: node subnets + pod CIDRs ---------------------------------
    print("- prefixes")
    for net in k8s.node_supernets(nodes):
        nb.ensure(nb.api.ipam.prefixes, key={"prefix": net},
                  defaults={"site": (site.id if site else None), "status": "active",
                            "description": "LAN segment (home)", "tags": tag_ref})
    for cidr in sorted({c for n in nodes for c in n["pod_cidrs"]}):
        nb.ensure(nb.api.ipam.prefixes, key={"prefix": cidr},
                  defaults={"status": "active", "description": "k8s pod CIDR",
                            "tags": tag_ref})

    # --- MetalLB pools -------------------------------------------------------
    print("- metallb pools")
    for pool in k8s.get_metallb_pools():
        for addr in pool["addresses"]:
            if "-" in addr:
                start, end = (a.strip() for a in addr.split("-", 1))
                net = supernet24(start)
                nb.ensure(nb.api.ipam.prefixes, key={"prefix": net},
                          defaults={"site": (site.id if site else None),
                                    "status": "active",
                                    "description": "LAN segment (home)",
                                    "tags": tag_ref})
                plen = net.split("/")[1]
                nb.ensure(
                    nb.api.ipam.ip_ranges,
                    key={"start_address": f"{start}/{plen}",
                         "end_address": f"{end}/{plen}"},
                    defaults={"status": "active",
                              "description": f"metallb pool {pool['name']}",
                              "tags": tag_ref},
                )
            elif "/" in addr:
                nb.ensure(nb.api.ipam.prefixes, key={"prefix": addr},
                          defaults={"status": "active",
                                    "description": f"metallb pool {pool['name']}",
                                    "tags": tag_ref})

    # --- nodes as VMs --------------------------------------------------------
    print("- nodes")
    cluster_id = cluster.id if cluster else None
    for n in nodes:
        comments = (f"{n['os_image']} | kubelet {n['kubelet']} | {n['arch']} | "
                    f"roles: {', '.join(n['roles'])}")
        vm, _ = nb.ensure(
            nb.api.virtualization.virtual_machines,
            key={"name": n["name"], "cluster_id": cluster_id},
            defaults={"status": "active", "vcpus": n["vcpus"],
                      "memory": n["memory_mib"], "comments": comments,
                      "site": (site.id if site else None), "tags": tag_ref},
            create_key={"name": n["name"], "cluster": cluster_id},
            label="virtual_machine",
        )
        if not n["internal_ip"]:
            continue
        vm_id = vm.id if vm else None
        iface, _ = nb.ensure(
            nb.api.virtualization.interfaces,
            key={"virtual_machine_id": vm_id, "name": "eth0"},
            defaults={},
            create_key={"virtual_machine": vm_id, "name": "eth0"},
            label="vm_interface",
        )
        ip_cidr = f"{n['internal_ip']}/24"
        ip, _ = nb.ensure(
            nb.api.ipam.ip_addresses,
            key={"address": ip_cidr},
            defaults={"status": "active",
                      "assigned_object_type": "virtualization.vminterface",
                      "assigned_object_id": (iface.id if iface else None),
                      "dns_name": n["name"], "tags": tag_ref},
            label="ip_address",
        )
        nb.set_fields(vm, {"primary_ip4": (ip.id if ip else None)},
                      label=f"{n['name']}.primary_ip4")

    # --- LoadBalancer VIPs ---------------------------------------------------
    print("- loadbalancer VIPs")
    for svc in k8s.get_lb_services():
        for vip in svc["ips"]:
            nb.ensure(
                nb.api.ipam.ip_addresses,
                key={"address": f"{vip}/32"},
                defaults={"status": "active",
                          "description": f"svc {svc['namespace']}/{svc['name']}",
                          "tags": tag_ref},
                label="vip",
            )

    print(f"== done: {nb.summary()} ==")
    return 0


if __name__ == "__main__":
    sys.exit(main())
