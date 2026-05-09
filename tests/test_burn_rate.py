"""Burn-rate buffer: window trim + rate math.

Clock is injected so tests don't sleep. Costs are passed in USD; rate
output is in cents-per-minute.
"""
from __future__ import annotations

import pytest

from proxy.burn_rate import BurnRateBuffer


class FakeClock:
    def __init__(self) -> None:
        self.t = 0.0
    def __call__(self) -> float:
        return self.t


def test_empty_buffer_is_zero():
    b = BurnRateBuffer(window_sec=60, clock=FakeClock())
    assert b.cents_per_min() == 0.0


def test_single_event_normalized_over_full_window():
    """One $1 call inside a 60s window → $1/min = 100 cents/min, regardless
    of how recent the call was. Avoids spiky readings on the first event."""
    clock = FakeClock()
    b = BurnRateBuffer(window_sec=60, clock=clock)
    b.record(1.00)
    assert b.cents_per_min() == pytest.approx(100.0)


def test_multiple_events_sum_in_window():
    clock = FakeClock()
    b = BurnRateBuffer(window_sec=60, clock=clock)
    b.record(0.50)
    clock.t = 10
    b.record(0.50)
    # Two $0.50 calls = $1.00 in the last 60s = 100 c/min.
    assert b.cents_per_min() == pytest.approx(100.0)


def test_old_events_drop_off_after_window():
    clock = FakeClock()
    b = BurnRateBuffer(window_sec=60, clock=clock)
    b.record(2.00)             # $2 at t=0
    clock.t = 30
    assert b.cents_per_min() == pytest.approx(200.0)
    clock.t = 61
    # After 61s the t=0 event is outside the trailing 60s window.
    assert b.cents_per_min() == pytest.approx(0.0)


def test_zero_cost_record_still_trims_buffer():
    clock = FakeClock()
    b = BurnRateBuffer(window_sec=60, clock=clock)
    b.record(5.00)
    clock.t = 65
    b.record(0.0)              # idle ping
    assert b.cents_per_min() == pytest.approx(0.0)


def test_window_scales_rate_correctly():
    """A 30s window with $0.50 in it should also report 100 c/min."""
    clock = FakeClock()
    b = BurnRateBuffer(window_sec=30, clock=clock)
    b.record(0.50)
    assert b.cents_per_min() == pytest.approx(100.0)


def test_zero_window_is_safe():
    b = BurnRateBuffer(window_sec=0, clock=FakeClock())
    b.record(5)
    # Defensive: don't divide by zero, just return 0.
    assert b.cents_per_min() == 0.0
