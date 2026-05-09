"""Loader and validator for ~/.ai-spending/registry.json.

The registry is a flat list of account entries. Each entry tells the
reconciler which provider to poll, which admin key to use, and which
group_by axes to ask for. See DESIGN.md §5a for the canonical shape.

This module is intentionally pure I/O + validation; the reconciler does
the actual polling. Unknown keys are tolerated for forward-compat —
silently ignored, never an error — so older code can keep loading
files written by future versions.
"""

from __future__ import annotations

import json
import logging
import os
import stat
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator

logger = logging.getLogger(__name__)

REGISTRY_DIR = Path.home() / ".ai-spending"
REGISTRY_FILE = REGISTRY_DIR / "registry.json"

SUPPORTED_PROVIDERS = frozenset({"anthropic", "openai"})
DEFAULT_GROUPINGS = {
    "anthropic": ("workspace_id", "api_key_id"),
    "openai":    ("project_id", "api_key_id"),
}

REQUIRED_FIELDS = ("id", "label", "provider", "admin_key")


@dataclass(frozen=True)
class RegistryEntry:
    id: str
    label: str
    provider: str
    admin_key: str
    groupings: tuple[str, ...] = field(default_factory=tuple)
    # `enabled=False` keeps the admin key on disk but stops the reconciler
    # from polling it. Default True so older registries (no `enabled` key)
    # keep behaving as before.
    enabled: bool = True


class RegistryError(Exception):
    """Raised for unrecoverable registry problems (file unreadable, schema
    invalid). Per-entry validation failures are logged and skipped — one
    bad row shouldn't kill the rest."""


def _check_perms(path: Path) -> None:
    """Warn (don't raise) if the registry file is more permissive than 0600.
    Admin keys live here; group/world reads are bad. Loud log, no abort —
    aborting on first install would be hostile to first-time users.
    """
    try:
        mode = path.stat().st_mode & 0o777
    except OSError:
        return
    if mode & (stat.S_IRWXG | stat.S_IRWXO):
        logger.warning(
            "registry.json has perms %o (should be 0600). "
            "Run: chmod 0600 %s", mode, path
        )


def load() -> list[RegistryEntry]:
    """Return the parsed, validated registry. Empty list if file is absent
    (the additive-mode signal that v2 is off). Raises RegistryError only
    if the file exists but is malformed top-level JSON.
    """
    if not REGISTRY_FILE.exists():
        return []
    _check_perms(REGISTRY_FILE)
    try:
        raw = json.loads(REGISTRY_FILE.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise RegistryError(f"can't parse {REGISTRY_FILE}: {exc}") from exc
    if not isinstance(raw, list):
        raise RegistryError(
            f"{REGISTRY_FILE} must be a JSON array of account entries"
        )

    entries: list[RegistryEntry] = []
    seen_ids: set[str] = set()
    for i, item in enumerate(raw):
        try:
            entry = _validate_entry(item, position=i)
        except ValueError as exc:
            logger.warning("registry entry %d skipped: %s", i, exc)
            continue
        if entry.id in seen_ids:
            logger.warning("registry entry %d skipped: duplicate id %r", i, entry.id)
            continue
        seen_ids.add(entry.id)
        entries.append(entry)
    return entries


def _validate_entry(item: object, *, position: int) -> RegistryEntry:
    if not isinstance(item, dict):
        raise ValueError(f"not an object (got {type(item).__name__})")
    for key in REQUIRED_FIELDS:
        if not item.get(key) or not isinstance(item[key], str):
            raise ValueError(f"missing or non-string field {key!r}")
    provider = item["provider"].lower()
    if provider not in SUPPORTED_PROVIDERS:
        raise ValueError(
            f"unsupported provider {provider!r} "
            f"(want one of: {', '.join(sorted(SUPPORTED_PROVIDERS))})"
        )
    groupings_raw = item.get("groupings")
    if groupings_raw is None:
        groupings = DEFAULT_GROUPINGS[provider]
    elif isinstance(groupings_raw, list) and all(isinstance(g, str) for g in groupings_raw):
        groupings = tuple(groupings_raw)
    else:
        raise ValueError("groupings must be a list of strings if provided")
    enabled_raw = item.get("enabled", True)
    if not isinstance(enabled_raw, bool):
        raise ValueError("enabled must be a boolean if provided")
    return RegistryEntry(
        id=item["id"],
        label=item["label"],
        provider=provider,
        admin_key=item["admin_key"],
        groupings=groupings,
        enabled=enabled_raw,
    )


def save(entries: list[RegistryEntry]) -> None:
    """Persist the registry list, mode 0600. Used by registry/cli.py."""
    REGISTRY_DIR.mkdir(parents=True, exist_ok=True)
    payload = [
        {
            "id": e.id,
            "label": e.label,
            "provider": e.provider,
            "admin_key": e.admin_key,
            "groupings": list(e.groupings),
            "enabled": e.enabled,
        }
        for e in entries
    ]
    # Write to a temp file then chmod + rename so the file never exists
    # at default umask perms even briefly.
    tmp = REGISTRY_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, indent=2))
    os.chmod(tmp, 0o600)
    os.replace(tmp, REGISTRY_FILE)


def iter_for_provider(entries: list[RegistryEntry], provider: str) -> Iterator[RegistryEntry]:
    for e in entries:
        if e.provider == provider:
            yield e


def set_enabled(entry_id: str, enabled: bool) -> bool:
    """Flip the enabled bit on one entry. Returns True on success, False
    if the id isn't found. Used by the CLI and the Swift Account Detail
    'Disable' button."""
    entries = load()
    found = False
    new_entries: list[RegistryEntry] = []
    for e in entries:
        if e.id == entry_id:
            new_entries.append(RegistryEntry(
                id=e.id, label=e.label, provider=e.provider,
                admin_key=e.admin_key, groupings=e.groupings, enabled=enabled,
            ))
            found = True
        else:
            new_entries.append(e)
    if found:
        save(new_entries)
    return found
