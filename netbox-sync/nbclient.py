"""Idempotent pynetbox wrapper.

Single ingestion seam: every write goes through NB.ensure(). Objects are matched
on a natural key and only drifted scalar fields are patched, so re-running is a
no-op when reality is unchanged. Nothing is ever deleted here (reflective
adds/updates only).
"""
from __future__ import annotations

import pynetbox

import config


# action constants for clear logging / counting
CREATE = "create"
UPDATE = "update"
OK = "ok"
SKIP = "skip"


class NB:
    def __init__(self, dry_run: bool = False):
        config.require_credentials()
        self.dry = dry_run
        self.api = pynetbox.api(config.NETBOX_URL, token=config.NETBOX_TOKEN)
        self.api.http_session.verify = config.NETBOX_VERIFY_SSL
        self.counts = {CREATE: 0, UPDATE: 0, OK: 0, SKIP: 0}

    # ---- core --------------------------------------------------------------

    def ensure(self, endpoint, key: dict, defaults: dict | None = None,
               create_key: dict | None = None, label: str | None = None):
        """Find-or-create-or-patch on `endpoint` keyed by `key`.

        `key`        - filter kwargs used to match an existing object (NetBox
                       filter names, e.g. cluster_id, virtual_machine_id).
        `create_key` - how those same identity fields are expressed in a create
                       payload (e.g. cluster, virtual_machine). Defaults to `key`.
        Returns (record_or_None, action). In dry-run a would-be-created object
        returns (None, CREATE); callers must tolerate a None parent and skip
        dependents rather than dereference .id.
        """
        defaults = defaults or {}
        create_key = create_key if create_key is not None else key
        label = label or endpoint.name

        # A None in the key means a parent wasn't created (dry-run); bail safely.
        if any(v is None for v in key.values()):
            self._log(SKIP, label, key, note="unresolved dependency")
            return None, SKIP

        existing = self._first(endpoint.filter(**key))

        if existing is None:
            payload = {**create_key, **defaults}
            if self.dry:
                self._log(CREATE, label, payload)
                return None, CREATE
            rec = endpoint.create(payload)
            self._log(CREATE, label, payload)
            return rec, CREATE

        drift = self._drift(existing, defaults)
        if drift:
            if not self.dry:
                existing.update(drift)
            self._log(UPDATE, label, drift)
            return existing, UPDATE

        self.counts[OK] += 1
        return existing, OK

    def set_fields(self, record, fields: dict, label: str = "patch"):
        """Patch already-resolved fields on an existing record (e.g. primary_ip)."""
        if record is None:
            self._log(SKIP, label, fields, note="no record")
            return SKIP
        drift = self._drift(record, fields)
        if not drift:
            self.counts[OK] += 1
            return OK
        if not self.dry:
            record.update(drift)
        self._log(UPDATE, label, drift)
        return UPDATE

    # ---- helpers -----------------------------------------------------------

    @staticmethod
    def _first(results):
        results = list(results)
        return results[0] if results else None

    # list/object fields whose serialized form is noisy to diff; set on create only
    _NO_DIFF = {"tags", "custom_fields"}

    @classmethod
    def _drift(cls, record, desired: dict) -> dict:
        """Compare desired scalar/id fields against the record's writable form."""
        current = record.serialize()  # status -> value, refs -> id
        out = {}
        for k, v in desired.items():
            if k in cls._NO_DIFF:
                continue
            if current.get(k) != v:
                out[k] = v
        return out

    def _log(self, action, label, data, note: str | None = None):
        if action in self.counts:
            self.counts[action] += 1
        tag = "[plan] " if self.dry and action in (CREATE, UPDATE) else ""
        suffix = f" ({note})" if note else ""
        print(f"  {tag}{action:6} {label:24} {data}{suffix}")

    def summary(self) -> str:
        c = self.counts
        verb = "would " if self.dry else ""
        return (f"{verb}create={c[CREATE]} {verb}update={c[UPDATE]} "
                f"unchanged={c[OK]} skipped={c[SKIP]}")
