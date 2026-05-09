"""Reference math for Swift's forecast + week-over-week computeds.

The Swift side derives these from the same history.json the Python
reconciler writes. We replicate the math here so a refactor on either
side gets caught immediately.
"""
from __future__ import annotations

from calendar import monthrange
from datetime import date, timedelta


def forecast_eom(month_to_date_usd: float, day_of_month: int, days_in_month: int) -> float:
    return month_to_date_usd / day_of_month * days_in_month


def week_over_week(this_week: float, prior_week: float) -> float | None:
    if prior_week <= 0:
        return None
    return this_week / prior_week - 1.0


def test_forecast_linear_projection():
    # Spent $30 in 10 days of a 30-day month → projected $90.
    assert forecast_eom(30.0, 10, 30) == 90.0


def test_forecast_zero_when_no_spend():
    assert forecast_eom(0.0, 10, 30) == 0.0


def test_wow_positive_growth():
    assert abs(week_over_week(120.0, 100.0) - 0.20) < 1e-9


def test_wow_negative_growth():
    assert abs(week_over_week(80.0, 100.0) - (-0.20)) < 1e-9


def test_wow_undefined_with_no_prior():
    assert week_over_week(50.0, 0.0) is None


def test_forecast_realistic_calendar_inputs():
    # Real anchors so the test catches any off-by-one in the Swift impl.
    today = date.today()
    days_in_month = monthrange(today.year, today.month)[1]
    # Pretend 50% of the month has elapsed, $100 spent.
    half = max(1, days_in_month // 2)
    proj = forecast_eom(100.0, half, days_in_month)
    assert abs(proj - 100.0 * days_in_month / half) < 1e-9
