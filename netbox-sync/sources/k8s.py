"""Discover the home cluster via kubectl (proven to work in this env).

Returns plain dicts; no NetBox coupling here. The eventual in-cluster CronJob
(P5) can swap this for the in-cluster client without touching the sync logic.
"""
from __future__ import annotations

import ipaddress
import json
import subprocess

import config


def _kubectl(*args) -> dict:
    cmd = ["kubectl", *args, "-o", "json"]
    if config.KUBE_CONTEXT:
        cmd.append(f"--context={config.KUBE_CONTEXT}")  # flag AFTER subcommand (oidc plugin)
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def _mem_to_mib(qty: str) -> int:
    """Kubernetes memory quantity (e.g. '16331052Ki') -> MiB."""
    units = {"Ki": 1 / 1024, "Mi": 1, "Gi": 1024, "Ti": 1024 * 1024}
    for suf, mul in units.items():
        if qty.endswith(suf):
            return int(float(qty[: -len(suf)]) * mul)
    # bare bytes
    return int(int(qty) / (1024 * 1024))


def get_nodes() -> list[dict]:
    nodes = []
    for item in _kubectl("get", "nodes")["items"]:
        st = item.get("status", {})
        info = st.get("nodeInfo", {})
        internal = next((a["address"] for a in st.get("addresses", [])
                         if a["type"] == "InternalIP"), None)
        roles = sorted(
            k.split("/", 1)[1]
            for k in item["metadata"].get("labels", {})
            if k.startswith("node-role.kubernetes.io/") and k.split("/", 1)[1]
        )
        cap = st.get("capacity", {})
        spec = item.get("spec", {})
        nodes.append({
            "name": item["metadata"]["name"],
            "internal_ip": internal,
            "roles": roles or ["worker"],
            "vcpus": int(cap.get("cpu", 0)),
            "memory_mib": _mem_to_mib(cap.get("memory", "0")),
            "os_image": info.get("osImage", ""),
            "kubelet": info.get("kubeletVersion", ""),
            "arch": info.get("architecture", ""),
            "pod_cidrs": spec.get("podCIDRs") or ([spec["podCIDR"]] if spec.get("podCIDR") else []),
        })
    return nodes


def get_lb_services() -> list[dict]:
    svcs = []
    for item in _kubectl("get", "svc", "-A")["items"]:
        if item["spec"].get("type") != "LoadBalancer":
            continue
        ingress = item.get("status", {}).get("loadBalancer", {}).get("ingress", [])
        ips = [i["ip"] for i in ingress if i.get("ip")]
        if not ips:
            continue
        svcs.append({
            "namespace": item["metadata"]["namespace"],
            "name": item["metadata"]["name"],
            "ips": ips,
        })
    return svcs


def get_metallb_pools() -> list[dict]:
    try:
        data = _kubectl("get", "ipaddresspools.metallb.io", "-A")
    except subprocess.CalledProcessError:
        return []
    pools = []
    for item in data["items"]:
        pools.append({
            "name": item["metadata"]["name"],
            "addresses": item["spec"].get("addresses", []),
        })
    return pools


def node_supernets(nodes: list[dict]) -> list[str]:
    """Collapse node internal IPs into their containing /24s."""
    nets = set()
    for n in nodes:
        if n["internal_ip"]:
            ip = ipaddress.ip_interface(f"{n['internal_ip']}/24")
            nets.add(str(ip.network))
    return sorted(nets)
