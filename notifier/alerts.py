"""Budget alerts.

Walks the registry + global budgets after each reconcile tick. For any
account whose daily/monthly spend has crossed its cap, fires a macOS
notification via ``osascript -e 'display notification ...'`` (no
entitlements / unsigned-app-friendly) and stamps a dedupe key into
``state.alerts_fired`` so the same alert can't re-fire later the same
UTC day (daily budgets) or month (monthly budgets).

Dedupe key format:
    daily_<account_id>_<YYYY-MM-DD>
    monthly_<account_id>_<YYYY-MM>
    daily_GLOBAL_<YYYY-MM-DD>
    monthly_GLOBAL_<YYYY-MM>

Why dedupe per (key, day) instead of per (key, threshold-crossing): the
reconciler runs every 5 minutes; without dedupe a single over-budget day
would deliver 288 notifications. Per-day dedupe is the right granularity
— the operator sees one ping the moment they cross, then peace.
"""

from __future__ import annotations

import logging
import shutil
import subprocess
from dataclasses import dataclass
from datetime import date
from typing import Iterable

from registry.loader import Budgets, RegistryEntry, load_global_budgets
from state.history import load_history
from state.manager import get_alerts_fired, mark_alert_fired

logger = logging.getLogger(__name__)


@dataclass
class Alert:
    key: str            # dedupe key
    title: str          # notification title
    message: str        # notification body


def _today_iso() -> str:
    return date.today().isoformat()


def _month_iso() -> str:
    return date.today().strftime("%Y-%m")


def _spend_today(history_for_account: dict[str, float]) -> float:
    return float(history_for_account.get(_today_iso(), 0.0) or 0.0)


def _spend_month_to_date(history_for_account: dict[str, float]) -> float:
    prefix = _month_iso() + "-"
    total = 0.0
    for d, v in history_for_account.items():
        if d.startswith(prefix):
            try:
                total += float(v or 0.0)
            except (TypeError, ValueError):
                pass
    return total


def _send_notification(title: str, message: str) -> None:
    """Fire a macOS notification. Failures are logged, never raised — a
    misconfigured osascript shouldn't take down the reconciler loop."""
    if shutil.which("osascript") is None:
        logger.info("osascript not available, skipping notification: %s", title)
        return
    # AppleScript string-escape: quote → \"
    safe_title = title.replace('"', '\\"')
    safe_msg = message.replace('"', '\\"')
    script = (
        f'display notification "{safe_msg}" '
        f'with title "SpendTracker" subtitle "{safe_title}"'
    )
    try:
        subprocess.run(
            ["osascript", "-e", script],
            check=False,
            timeout=5,
            capture_output=True,
        )
    except (subprocess.SubprocessError, OSError) as exc:
        logger.warning("notification dispatch failed: %s", exc)


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

def check_and_fire(entries: Iterable[RegistryEntry]) -> list[Alert]:
    """Build the per-tick set of would-fire alerts, dedupe against the
    state's alerts_fired log, fire what's new, and return what fired
    (handy for tests and for the Swift UI to display recent alerts).
    """
    history = load_history()
    fired_log = get_alerts_fired()
    global_budgets = load_global_budgets()

    candidates: list[Alert] = _build_candidates(entries, history, global_budgets)
    new_alerts = [a for a in candidates if a.key not in fired_log]

    for alert in new_alerts:
        _send_notification(alert.title, alert.message)
        try:
            mark_alert_fired(alert.key)
        except Exception as exc:  # pragma: no cover
            logger.warning("mark_alert_fired failed for %s: %s", alert.key, exc)
    return new_alerts


def _build_candidates(
    entries: Iterable[RegistryEntry],
    history: dict[str, dict[str, float]],
    global_budgets: Budgets,
) -> list[Alert]:
    out: list[Alert] = []

    # Per-account caps.
    for entry in entries:
        if not entry.budgets.is_set():
            continue
        per = history.get(entry.id, {}) or {}
        today_spend = _spend_today(per)
        month_spend = _spend_month_to_date(per)
        if entry.budgets.daily_usd is not None and today_spend > entry.budgets.daily_usd:
            out.append(Alert(
                key=f"daily_{entry.id}_{_today_iso()}",
                title=entry.label,
                message=f"Daily budget exceeded: ${today_spend:.2f} of ${entry.budgets.daily_usd:.2f}",
            ))
        if entry.budgets.monthly_usd is not None and month_spend > entry.budgets.monthly_usd:
            out.append(Alert(
                key=f"monthly_{entry.id}_{_month_iso()}",
                title=entry.label,
                message=f"Monthly budget exceeded: ${month_spend:.2f} of ${entry.budgets.monthly_usd:.2f}",
            ))

    # Global caps (sum across all enabled accounts).
    if global_budgets.is_set():
        global_today = sum(_spend_today(history.get(e.id, {}) or {}) for e in entries)
        global_month = sum(_spend_month_to_date(history.get(e.id, {}) or {}) for e in entries)
        if global_budgets.daily_usd is not None and global_today > global_budgets.daily_usd:
            out.append(Alert(
                key=f"daily_GLOBAL_{_today_iso()}",
                title="All accounts",
                message=f"Daily total exceeded: ${global_today:.2f} of ${global_budgets.daily_usd:.2f}",
            ))
        if global_budgets.monthly_usd is not None and global_month > global_budgets.monthly_usd:
            out.append(Alert(
                key=f"monthly_GLOBAL_{_month_iso()}",
                title="All accounts",
                message=f"Monthly total exceeded: ${global_month:.2f} of ${global_budgets.monthly_usd:.2f}",
            ))
    return out
