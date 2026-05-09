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
class Budgets:
    """Per-account spend caps. Either or both may be ``None`` — a missing
    field means "no cap." Everything is in USD; alerts/notifier compares
    against today's spend (daily) or month-to-date (monthly)."""
    daily_usd: float | None = None
    monthly_usd: float | None = None

    def is_set(self) -> bool:
        return self.daily_usd is not None or self.monthly_usd is not None

    def to_dict(self) -> dict:
        out: dict = {}
        if self.daily_usd is not None:
            out["daily_usd"] = self.daily_usd
        if self.monthly_usd is not None:
            out["monthly_usd"] = self.monthly_usd
        return out


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
    # Optional spend caps. ``None`` means no budget configured.
    budgets: Budgets = field(default_factory=Budgets)
    # Per-key mutes — vendor-side ``api_key_id`` strings the operator no
    # longer wants surfaced. Polling continues for the account, but these
    # keys are subtracted from the displayed total and hidden from the
    # by_key breakdown. Different from ``enabled=False`` (which kills
    # polling for the whole account).
    muted_keys: tuple[str, ...] = field(default_factory=tuple)


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
    budgets = _parse_budgets(item.get("budgets"))
    muted_raw = item.get("muted_keys", [])
    if muted_raw is None:
        muted = ()
    elif isinstance(muted_raw, list) and all(isinstance(k, str) for k in muted_raw):
        # Dedupe + drop empty strings; preserve order for stable diffs.
        seen: set[str] = set()
        muted_list: list[str] = []
        for k in muted_raw:
            if k and k not in seen:
                seen.add(k)
                muted_list.append(k)
        muted = tuple(muted_list)
    else:
        raise ValueError("muted_keys must be a list of strings if provided")
    return RegistryEntry(
        id=item["id"],
        label=item["label"],
        provider=provider,
        admin_key=item["admin_key"],
        groupings=groupings,
        enabled=enabled_raw,
        budgets=budgets,
        muted_keys=muted,
    )


def _parse_budgets(raw: object) -> Budgets:
    """Tolerant budget parser. Bad values raise so the caller can skip the
    whole entry — silently dropping a budget would be worse than dropping
    the account, since the operator might assume the cap is in effect."""
    if raw is None:
        return Budgets()
    if not isinstance(raw, dict):
        raise ValueError("budgets must be an object if provided")
    daily = raw.get("daily_usd")
    monthly = raw.get("monthly_usd")
    def _f(name: str, v: object) -> float | None:
        if v is None:
            return None
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            raise ValueError(f"budgets.{name} must be a number")
        if v < 0:
            raise ValueError(f"budgets.{name} must be ≥ 0")
        return float(v)
    return Budgets(daily_usd=_f("daily_usd", daily), monthly_usd=_f("monthly_usd", monthly))


def save(entries: list[RegistryEntry]) -> None:
    """Persist the registry list, mode 0600. Used by registry/cli.py."""
    REGISTRY_DIR.mkdir(parents=True, exist_ok=True)
    payload = []
    for e in entries:
        item: dict = {
            "id": e.id,
            "label": e.label,
            "provider": e.provider,
            "admin_key": e.admin_key,
            "groupings": list(e.groupings),
            "enabled": e.enabled,
        }
        if e.budgets.is_set():
            item["budgets"] = e.budgets.to_dict()
        if e.muted_keys:
            item["muted_keys"] = list(e.muted_keys)
        payload.append(item)
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


BUDGETS_FILE = REGISTRY_DIR / "budgets.json"


def load_global_budgets() -> Budgets:
    """Read ~/.ai-spending/budgets.json if present. Empty Budgets when
    absent or malformed — global caps are optional, and a broken file
    shouldn't break the reconciler."""
    if not BUDGETS_FILE.exists():
        return Budgets()
    try:
        raw = json.loads(BUDGETS_FILE.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        logger.warning("budgets.json unreadable: %s", exc)
        return Budgets()
    try:
        return _parse_budgets(raw)
    except ValueError as exc:
        logger.warning("budgets.json invalid: %s", exc)
        return Budgets()


def save_global_budgets(b: Budgets) -> None:
    REGISTRY_DIR.mkdir(parents=True, exist_ok=True)
    tmp = BUDGETS_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(b.to_dict(), indent=2))
    os.chmod(tmp, 0o600)
    os.replace(tmp, BUDGETS_FILE)


def set_budget(entry_id: str, budgets: Budgets) -> bool:
    entries = load()
    found = False
    new_entries: list[RegistryEntry] = []
    for e in entries:
        if e.id == entry_id:
            new_entries.append(RegistryEntry(
                id=e.id, label=e.label, provider=e.provider,
                admin_key=e.admin_key, groupings=e.groupings,
                enabled=e.enabled, budgets=budgets,
                muted_keys=e.muted_keys,
            ))
            found = True
        else:
            new_entries.append(e)
    if found:
        save(new_entries)
    return found


def mute_key(entry_id: str, api_key_id: str) -> bool:
    """Add ``api_key_id`` to the entry's muted set. Returns True on
    success, False if the entry isn't found. No-op if already muted."""
    entries = load()
    found = False
    new_entries: list[RegistryEntry] = []
    for e in entries:
        if e.id == entry_id:
            keys = list(e.muted_keys)
            if api_key_id not in keys:
                keys.append(api_key_id)
            new_entries.append(RegistryEntry(
                id=e.id, label=e.label, provider=e.provider,
                admin_key=e.admin_key, groupings=e.groupings,
                enabled=e.enabled, budgets=e.budgets,
                muted_keys=tuple(keys),
            ))
            found = True
        else:
            new_entries.append(e)
    if found:
        save(new_entries)
    return found


def unmute_key(entry_id: str, api_key_id: str) -> bool:
    """Remove ``api_key_id`` from the entry's muted set. Returns True on
    success, False if the entry isn't found. No-op if not currently muted."""
    entries = load()
    found = False
    new_entries: list[RegistryEntry] = []
    for e in entries:
        if e.id == entry_id:
            keys = [k for k in e.muted_keys if k != api_key_id]
            new_entries.append(RegistryEntry(
                id=e.id, label=e.label, provider=e.provider,
                admin_key=e.admin_key, groupings=e.groupings,
                enabled=e.enabled, budgets=e.budgets,
                muted_keys=tuple(keys),
            ))
            found = True
        else:
            new_entries.append(e)
    if found:
        save(new_entries)
    return found


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
                budgets=e.budgets, muted_keys=e.muted_keys,
            ))
            found = True
        else:
            new_entries.append(e)
    if found:
        save(new_entries)
    return found
