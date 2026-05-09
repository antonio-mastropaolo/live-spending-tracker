"""Vendor-side spend reconciliation.

The proxy gives sub-second feedback but can silently miss traffic (env var
not exported, tool ignores ANTHROPIC_BASE_URL, request shape changed, …).
This module periodically polls each vendor's official usage/cost API and
records the authoritative number. A small state machine compares vendor
spend with proxy-recorded spend and trips a DRIFT flag when they diverge —
the menu bar surfaces it so the operator sees that the tracker is missing
captures.

Coverage matrix (see ADMIN_KEYS.md for the long version):

    provider     | endpoint                                | granularity | lag
    -------------|-----------------------------------------|-------------|--------
    anthropic    | /v1/organizations/cost_report           | per-day     | ~1 hr
    openai       | /v1/organization/costs                  | per-day     | ~1 hr
    google       | (BigQuery billing export, not polled)   | per-day     | ~24 hr
    huggingface  | (no public per-key API)                 | —           | —
    mistral      | (no public per-key API)                 | —           | —
    cohere       | (no public per-key API)                 | —           | —

For unsupported providers the proxy is the only signal — DRIFT cannot fire
and the operator must accept that those numbers are best-effort.

Admin keys live at ~/.ai-spending/admin_keys.json (mode 0600), keyed by
provider. They are NOT the same as the regular API keys the user codes
with — they're created at the org level and are restricted to read-only
usage data. If the file is missing or empty, the reconciler is a no-op
(proxy-only mode).
"""

from __future__ import annotations

import asyncio
import fcntl
import json
import logging
import os
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Optional

import aiohttp

from state.manager import STATE_DIR, load_state, _write_state

logger = logging.getLogger(__name__)

ADMIN_KEYS_FILE = STATE_DIR / "admin_keys.json"

# Per-provider poll interval. Anthropic and OpenAI both rate-limit admin
# endpoints at the org level; 5 min is comfortably under any documented
# limit and matches the rough lag the endpoints themselves carry.
POLL_INTERVAL_SEC = 300

# Drift state machine: requires DRIFT_TRIP_TICKS consecutive ticks above
# the threshold to enter DRIFT, and DRIFT_RECOVER_TICKS consecutive ticks
# below it to recover. Hysteresis prevents the UI from flapping when the
# vendor's accounting briefly lags or jumps a bucket boundary.
DRIFT_THRESHOLD = 0.10        # 10% relative delta
DRIFT_FLOOR_USD = 0.05        # ignore noise below this — vendor rounding
DRIFT_TRIP_TICKS = 3
DRIFT_RECOVER_TICKS = 3


def load_admin_keys() -> dict[str, str]:
    """Return {provider: admin_key} from disk; {} if file missing or invalid."""
    if not ADMIN_KEYS_FILE.exists():
        return {}
    try:
        data = json.loads(ADMIN_KEYS_FILE.read_text())
        return {k: v for k, v in data.items() if isinstance(v, str) and v}
    except (OSError, json.JSONDecodeError):
        return {}


def _yesterday_utc_window() -> tuple[str, str]:
    """Return (starting_at, ending_at) covering YESTERDAY (UTC) as RFC 3339.

    Anthropic's cost_report rejects ranges that extend past the most recent
    completed day with a misleading "ending date must be after starting
    date" error. So we poll yesterday's bucket — vendor lag is ~1 day, not
    ~1 hour as the docs imply. The DRIFT signal therefore tells us
    'yesterday's vendor total disagrees with what the proxy captured
    yesterday' rather than 'right now is wrong.'
    """
    from datetime import timedelta
    now = datetime.now(timezone.utc)
    today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    yest_start = today_start - timedelta(days=1)
    fmt = "%Y-%m-%dT%H:%M:%SZ"
    return yest_start.strftime(fmt), today_start.strftime(fmt)


async def _fetch_anthropic_today_usd(admin_key: str) -> Optional[float]:
    """Sum Anthropic cost_report buckets covering today (UTC).

    Endpoint: GET /v1/organizations/cost_report
    Auth:     x-api-key: <admin_key>  (must be sk-ant-admin-…)
    Schema (abridged):
        {"data": [{"starting_at": "...", "ending_at": "...",
                   "results": [{"amount": "0.123", "currency": "USD", ...}]}]}
    """
    url = "https://api.anthropic.com/v1/organizations/cost_report"
    starting_at, ending_at = _yesterday_utc_window()
    params = {"starting_at": starting_at, "ending_at": ending_at}
    headers = {
        "x-api-key": admin_key,
        "anthropic-version": "2023-06-01",
    }
    timeout = aiohttp.ClientTimeout(total=15)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        async with session.get(url, headers=headers, params=params) as resp:
            body = await resp.text()
            if resp.status != 200:
                logger.warning("anthropic cost_report HTTP %s — body=%s", resp.status, body[:400])
                return None
            try:
                payload = json.loads(body)
            except json.JSONDecodeError as exc:
                logger.warning("anthropic cost_report bad JSON: %s", exc)
                return None
    total = 0.0
    for bucket in payload.get("data", []):
        for r in bucket.get("results", []):
            if r.get("currency", "USD") == "USD":
                try:
                    total += float(r.get("amount", 0))
                except (TypeError, ValueError):
                    pass
    return total


async def _fetch_openai_today_usd(admin_key: str) -> Optional[float]:
    """Sum OpenAI organization/costs buckets covering today (UTC).

    Endpoint: GET /v1/organization/costs
    Auth:     Authorization: Bearer <admin_key>
    Granularity: per-day buckets; we ask for today only.
    """
    today_unix = int(
        datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    )
    url = "https://api.openai.com/v1/organization/costs"
    params = {"start_time": today_unix, "limit": 1}
    headers = {"Authorization": f"Bearer {admin_key}"}
    timeout = aiohttp.ClientTimeout(total=15)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        async with session.get(url, headers=headers, params=params) as resp:
            body = await resp.text()
            if resp.status != 200:
                logger.warning("openai org/costs HTTP %s — body=%s", resp.status, body[:400])
                return None
            try:
                payload = json.loads(body)
            except json.JSONDecodeError as exc:
                logger.warning("openai org/costs bad JSON: %s", exc)
                return None
    total = 0.0
    for bucket in payload.get("data", []):
        for r in bucket.get("results", []):
            amt = r.get("amount") or {}
            try:
                total += float(amt.get("value", 0))
            except (TypeError, ValueError):
                pass
    return total


_FETCHERS = {
    "anthropic": _fetch_anthropic_today_usd,
    "openai": _fetch_openai_today_usd,
}


def _update_drift_for(state: dict, provider: str, vendor_usd: float, proxy_usd: float) -> None:
    """Hysteretic drift state machine. Mutates state['drift'][provider] in place.

    States:
        OK    — proxy and vendor agree within DRIFT_THRESHOLD
        DRIFT — proxy is missing traffic (or over-counting); operator should look

    Transitions (each tick):
        OK    -> DRIFT   after DRIFT_TRIP_TICKS consecutive over-threshold ticks
        DRIFT -> OK      after DRIFT_RECOVER_TICKS consecutive within-threshold ticks

    Spend below DRIFT_FLOOR_USD is treated as noise (vendor rounding +
    proxy precision); the ratio is undefined for tiny numbers.
    """
    drift = state.setdefault("drift", {})
    pd = drift.setdefault(
        provider,
        {
            "state": "OK",
            "above_streak": 0,
            "below_streak": 0,
            "last_proxy_usd": 0.0,
            "last_vendor_usd": 0.0,
            "last_check": None,
            "delta_pct": 0.0,
        },
    )

    if vendor_usd < DRIFT_FLOOR_USD and proxy_usd < DRIFT_FLOOR_USD:
        # Both effectively zero — treat as in-band, recover toward OK.
        ratio = 0.0
        above = False
    else:
        denom = max(vendor_usd, DRIFT_FLOOR_USD)
        ratio = abs(proxy_usd - vendor_usd) / denom
        above = ratio > DRIFT_THRESHOLD

    if above:
        pd["above_streak"] = pd.get("above_streak", 0) + 1
        pd["below_streak"] = 0
    else:
        pd["below_streak"] = pd.get("below_streak", 0) + 1
        pd["above_streak"] = 0

    cur = pd.get("state", "OK")
    if cur == "OK" and pd["above_streak"] >= DRIFT_TRIP_TICKS:
        pd["state"] = "DRIFT"
    elif cur == "DRIFT" and pd["below_streak"] >= DRIFT_RECOVER_TICKS:
        pd["state"] = "OK"

    pd["last_proxy_usd"] = round(proxy_usd, 4)
    pd["last_vendor_usd"] = round(vendor_usd, 4)
    pd["delta_pct"] = round(ratio * 100, 2)
    pd["last_check"] = datetime.now(timezone.utc).isoformat()


async def reconcile_once() -> dict[str, Optional[float]]:
    """One reconciliation tick: poll every configured provider in parallel,
    persist vendor_truth + drift to state.json. Returns the per-provider
    vendor totals that were fetched (None for providers that failed).
    """
    keys = load_admin_keys()
    if not keys:
        return {}

    tasks: list[tuple[str, asyncio.Task[Optional[float]]]] = []
    for provider, fetcher in _FETCHERS.items():
        admin_key = keys.get(provider)
        if not admin_key:
            continue
        tasks.append((provider, asyncio.create_task(fetcher(admin_key))))

    results: dict[str, Optional[float]] = {}
    for provider, task in tasks:
        try:
            results[provider] = await task
        except Exception as exc:  # network, JSON, anything
            logger.warning("reconciler fetch failed for %s: %s", provider, exc)
            results[provider] = None

    fetched = {p: v for p, v in results.items() if v is not None}
    if not fetched:
        return results

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    lock_path = STATE_DIR / ".state.lock"
    with open(lock_path, "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            state = load_state()
            vendor_truth = state.setdefault("vendor_truth", {})
            yest_snapshot = state.get("yesterday_by_provider", {}) or {}
            now = datetime.now(timezone.utc).isoformat()
            for provider, vendor_usd in fetched.items():
                vendor_truth[provider] = {
                    "usd": round(vendor_usd, 4),
                    "fetched_at": now,
                    "source": "admin_api",
                    "covers": "yesterday_utc",
                }
                # Drift compares yesterday-vendor vs yesterday-proxy. If we
                # don't yet have a yesterday snapshot (e.g. proxy was just
                # installed), skip drift this tick rather than computing
                # against today's running total — that would be a
                # misleading apples-to-oranges comparison.
                if provider in yest_snapshot:
                    proxy_yest = yest_snapshot.get(provider, 0.0)
                    _update_drift_for(state, provider, vendor_usd, proxy_yest)
            state["last_reconciled"] = now
            _write_state(state)
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)
    return results


async def reconciler_loop(interval: int = POLL_INTERVAL_SEC) -> None:
    """Forever-loop intended to run as an asyncio task in the proxy daemon.
    Errors never kill the loop — the proxy is more important than the
    reconciler, and a brief vendor-side outage shouldn't take down spend
    capture.
    """
    while True:
        try:
            await reconcile_once()
        except Exception as exc:
            logger.warning("reconciler tick errored: %s", exc)
        await asyncio.sleep(interval)
