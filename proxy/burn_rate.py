"""Trailing-window burn-rate buffer for the proxy.

The proxy intercepts every API call and knows its cost (computed against
``proxy/pricing.json``). Aggregating the last 60 seconds of those costs
gives an honest "rate right now" number — useful for two things:

  1. The Swift UI renders a live ¢/min card while the proxy is hot.
  2. A future "budget panic" feature could look at this to decide
     whether to throttle.

The buffer holds a deque of ``(monotonic_ts, cost_cents)`` pairs and
trims entries older than ``window_sec`` on every observation. Values
are in cents (×100) so the rate-as-cents-per-minute calculation stays
in integer-ish territory and small dollar amounts (a few hundredths of
a cent per call) don't underflow float.

Thread/async-safety: a single proxy daemon runs everything on one event
loop, so no lock needed. If that ever stops being true, swap to
``threading.Lock`` around the deque ops.

Why an in-process buffer rather than a cross-process file: the proxy is
the only producer; serializing the deque to disk would be wasted I/O.
The Swift UI reads the *derived rate* from ``state.json:today_estimate``
which the proxy stamps on each tick.
"""

from __future__ import annotations

import time
from collections import deque
from typing import Callable

DEFAULT_WINDOW_SEC = 60.0


class BurnRateBuffer:
    """Sliding-window cost accumulator. Returns ¢/min over the trailing
    ``window_sec`` seconds of recorded events."""

    def __init__(
        self,
        window_sec: float = DEFAULT_WINDOW_SEC,
        clock: Callable[[], float] | None = None,
    ):
        self.window_sec = float(window_sec)
        self._clock = clock or time.monotonic
        # Each entry: (timestamp_seconds_monotonic, cost_cents_float).
        self._events: "deque[tuple[float, float]]" = deque()

    def record(self, cost_usd: float) -> None:
        """Add an observation. Free calls (cost=0) are still recorded so
        the trim runs and an idle window settles back to zero."""
        now = self._clock()
        self._trim(now)
        self._events.append((now, cost_usd * 100.0))

    def cents_per_min(self) -> float:
        """Sum the in-window costs and scale to a per-minute rate.

        Always reports ¢/min over a full ``window_sec``, *not* a partial
        window — this keeps the rate from spiking when the very first
        event fires (one $1 call shouldn't read as $60/min after one
        second). The trade-off: the rate ramps up over the first 60s,
        which is fine for a "is it hot right now" indicator.
        """
        now = self._clock()
        self._trim(now)
        total_cents = sum(c for _, c in self._events)
        if self.window_sec <= 0:
            return 0.0
        return total_cents * (60.0 / self.window_sec)

    def _trim(self, now: float) -> None:
        cutoff = now - self.window_sec
        while self._events and self._events[0][0] < cutoff:
            self._events.popleft()
