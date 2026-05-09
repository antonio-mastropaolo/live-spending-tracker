"""Multi-account reconciler loop (DESIGN.md §5b).

Walks the registry every ``POLL_INTERVAL_SEC`` seconds, calls the
provider-specific fetcher in ``registry/vendor.py``, and merges the
result into ``state.json`` via the helpers in ``state/manager.py``.

Per-account try/except funnels failures into ``state.errors[]``. A bad
admin key on one account never poisons another. Network blips are
transient errors; auth errors remain until the operator fixes them
because subsequent successful merges clear them.

Cadence: 5 minutes. Vendor data has a ~24h lag (DESIGN.md §4a) so
polling more often is wasted requests.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Iterable

import aiohttp

from notifier.alerts import check_and_fire as fire_budget_alerts
from registry.loader import RegistryEntry, load
from registry.vendor import VendorError, fetch_account
from state.history import prune_history, update_history
from state.manager import (
    merge_account_snapshot,
    prune_accounts,
    record_account_error,
)

logger = logging.getLogger(__name__)

POLL_INTERVAL_SEC = 300


async def _reconcile_one(entry: RegistryEntry) -> None:
    """Reconcile a single account. Catches everything; records to errors[]
    on failure. Never raises — the loop must keep running."""
    try:
        snapshot = await fetch_account(entry)
    except VendorError as exc:
        logger.warning("reconcile %s (%s): %s", entry.id, entry.provider, exc)
        try:
            record_account_error(entry.id, exc.kind, exc.msg)
        except Exception as inner:  # pragma: no cover — should not happen
            logger.warning("failed to record error for %s: %s", entry.id, inner)
        return
    except (aiohttp.ClientError, asyncio.TimeoutError) as exc:
        logger.warning("reconcile %s network error: %s", entry.id, exc)
        try:
            record_account_error(entry.id, "network", str(exc))
        except Exception as inner:  # pragma: no cover
            logger.warning("failed to record error for %s: %s", entry.id, inner)
        return
    except Exception as exc:  # pragma: no cover — surfaces unknown bugs
        logger.warning("reconcile %s unexpected error: %s", entry.id, exc)
        try:
            record_account_error(entry.id, "internal", repr(exc)[:400])
        except Exception:
            pass
        return

    snapshot_dict = snapshot.to_dict()
    # Carry the operator's budget caps through to state.json so the Swift
    # UI can render OVER pills + progress bars without parsing
    # registry.json (which holds admin keys).
    if entry.budgets.is_set():
        snapshot_dict["budgets"] = entry.budgets.to_dict()
    # Same idea for muted keys: include the list so the UI can hide
    # them and subtract their spend from displayed totals without ever
    # reading registry.json directly.
    if entry.muted_keys:
        snapshot_dict["muted_keys"] = list(entry.muted_keys)

    try:
        merge_account_snapshot(entry.id, snapshot_dict)
    except Exception as exc:  # pragma: no cover
        logger.warning("merge failed for %s: %s", entry.id, exc)
        record_account_error(entry.id, "internal", f"merge failed: {exc!r}")
        return

    # History rollup feeds the heatmap, forecast, and WoW deltas in the
    # Swift UI. Failure here is non-fatal (the snapshot is already
    # persisted) so we just log and move on.
    if snapshot.daily_history:
        try:
            update_history({entry.id: snapshot.daily_history})
        except Exception as exc:  # pragma: no cover
            logger.warning("history update failed for %s: %s", entry.id, exc)


async def reconcile_once(entries: Iterable[RegistryEntry] | None = None) -> int:
    """Run one full pass across the registry. Returns the number of
    accounts attempted (irrespective of success). All accounts are
    processed concurrently.

    After polling, prunes ``state.accounts`` of any id no longer in the
    enabled set — this is how `disable` and `remove` take effect: the
    account vanishes from the UI and stops counting toward totals
    (DESIGN: 'excluded from totals + hidden')."""
    if entries is None:
        try:
            entries = load()
        except Exception as exc:
            logger.warning("registry load failed: %s — skipping tick", exc)
            return 0
    entries = list(entries)

    # Always prune to the active set, even if there's nothing to poll —
    # otherwise a just-disabled account stays visible until the next
    # ENABLED account triggers a reconcile.
    active = [e for e in entries if e.enabled]
    active_ids = {e.id for e in active}
    try:
        prune_accounts(active_ids)
    except Exception as exc:  # pragma: no cover
        logger.warning("prune_accounts failed: %s", exc)
    try:
        prune_history(active_ids)
    except Exception as exc:  # pragma: no cover
        logger.warning("prune_history failed: %s", exc)

    if not active:
        return 0
    await asyncio.gather(*(_reconcile_one(e) for e in active))

    # Budget alerts run after history.json has been refreshed by the
    # _reconcile_one calls above. Failures here are logged, never raised.
    try:
        fire_budget_alerts(active)
    except Exception as exc:  # pragma: no cover — keep loop alive
        logger.warning("budget alert pass failed: %s", exc)
    return len(active)


async def reconciler_loop(interval: int = POLL_INTERVAL_SEC) -> None:
    """Forever-loop intended to run as an asyncio task in the proxy daemon.
    Errors at the loop level (e.g. registry suddenly malformed) are caught
    and logged so the loop keeps trying — this matters because a successful
    poll later in the day clears the AUTH_ERROR pill on its own."""
    while True:
        try:
            n = await reconcile_once()
            if n:
                logger.info("registry reconciler: reconciled %d account(s)", n)
        except Exception as exc:  # pragma: no cover — top-level safety net
            logger.warning("registry reconciler tick failed: %s", exc)
        await asyncio.sleep(interval)
