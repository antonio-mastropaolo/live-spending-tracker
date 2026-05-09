"""notifier/alerts.py — budget threshold detection, dedupe, no double-fire."""
from __future__ import annotations

from datetime import date

import pytest

from notifier import alerts as alerts_mod
from notifier.alerts import check_and_fire
from registry.loader import Budgets, RegistryEntry, save_global_budgets
from state.history import update_history


@pytest.fixture(autouse=True)
def patch_osascript(monkeypatch: pytest.MonkeyPatch):
    """Capture would-be-fired notifications so tests don't actually pop UI."""
    fired: list[tuple[str, str]] = []
    def fake_send(title: str, msg: str) -> None:
        fired.append((title, msg))
    monkeypatch.setattr(alerts_mod, "_send_notification", fake_send)
    return fired


def _today() -> str:
    return date.today().isoformat()


def _today_month() -> str:
    return date.today().strftime("%Y-%m")


def test_no_budgets_no_alerts(patch_osascript):
    e = RegistryEntry("ant1", "A", "anthropic", "sk-ant-admin-x", ())
    out = check_and_fire([e])
    assert out == []
    assert patch_osascript == []


def test_below_daily_threshold_does_not_fire(patch_osascript):
    update_history({"ant1": {_today(): 4.99}})
    e = RegistryEntry(
        "ant1", "A", "anthropic", "sk-ant-admin-x", (),
        budgets=Budgets(daily_usd=5.0),
    )
    assert check_and_fire([e]) == []
    assert patch_osascript == []


def test_daily_threshold_fires_once_then_dedupes(patch_osascript):
    update_history({"ant1": {_today(): 7.50}})
    e = RegistryEntry(
        "ant1", "A", "anthropic", "sk-ant-admin-x", (),
        budgets=Budgets(daily_usd=5.0),
    )
    fired_first = check_and_fire([e])
    assert len(fired_first) == 1
    assert fired_first[0].key == f"daily_ant1_{_today()}"
    assert len(patch_osascript) == 1
    # Second pass on the same day must NOT re-fire.
    fired_second = check_and_fire([e])
    assert fired_second == []
    assert len(patch_osascript) == 1


def test_monthly_threshold_uses_month_to_date(patch_osascript):
    """Build several days inside the current month, verify MTD vs cap."""
    today_iso = _today()
    month_prefix = _today_month()
    days = {
        f"{month_prefix}-01": 30.0,
        f"{month_prefix}-02": 30.0,
        today_iso: 50.0,
    }
    update_history({"ant1": days})
    e = RegistryEntry(
        "ant1", "A", "anthropic", "sk-ant-admin-x", (),
        budgets=Budgets(monthly_usd=100.0),
    )
    out = check_and_fire([e])
    keys = {a.key for a in out}
    assert f"monthly_ant1_{month_prefix}" in keys


def test_global_daily_sums_across_accounts(patch_osascript):
    update_history({
        "ant1": {_today(): 30.0},
        "oai1": {_today(): 30.0},
    })
    save_global_budgets(Budgets(daily_usd=50.0))
    entries = [
        RegistryEntry("ant1", "A", "anthropic", "sk-ant-admin-x", ()),
        RegistryEntry("oai1", "B", "openai",    "sk-admin-x",     ()),
    ]
    out = check_and_fire(entries)
    keys = {a.key for a in out}
    assert f"daily_GLOBAL_{_today()}" in keys


def test_disabled_account_budget_does_not_run_when_filtered():
    """The reconciler only passes enabled entries to check_and_fire — so
    the function itself doesn't need to filter, but verify that disabled
    entries DO trigger if explicitly passed (separation of concerns)."""
    update_history({"ant1": {_today(): 99.0}})
    e = RegistryEntry(
        "ant1", "A", "anthropic", "sk-ant-admin-x", (),
        enabled=False,                         # would normally be filtered
        budgets=Budgets(daily_usd=1.0),
    )
    out = check_and_fire([e])
    assert len(out) == 1                       # function doesn't filter; that's the reconciler's job
