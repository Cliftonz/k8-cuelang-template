"""Environment-driven config for netbox-sync."""
import os

from dotenv import load_dotenv

load_dotenv()


def _bool(v: str, default: bool = True) -> bool:
    if v is None:
        return default
    return v.strip().lower() in ("1", "true", "yes", "on")


NETBOX_URL = os.environ.get("NETBOX_URL", "").rstrip("/")
NETBOX_TOKEN = os.environ.get("NETBOX_TOKEN", "")
NETBOX_VERIFY_SSL = _bool(os.environ.get("NETBOX_VERIFY_SSL"), True)

KUBE_CONTEXT = os.environ.get("KUBE_CONTEXT", "") or None

SITE_SLUG = os.environ.get("SITE_SLUG", "home")
SITE_NAME = os.environ.get("SITE_NAME", "Home")
CLUSTER_NAME = os.environ.get("CLUSTER_NAME", "talos-home")
CLUSTER_TYPE = os.environ.get("CLUSTER_TYPE", "talos")

# Marker tag so reflectively-synced objects are identifiable (and prunable later).
MANAGED_TAG = "netbox-sync"


def require_credentials() -> None:
    if not NETBOX_URL or not NETBOX_TOKEN:
        raise SystemExit(
            "NETBOX_URL and NETBOX_TOKEN must be set (copy .env.example -> .env "
            "and paste a real 40-char token)."
        )
