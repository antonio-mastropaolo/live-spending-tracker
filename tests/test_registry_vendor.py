"""Vendor poller tests.

We don't hit real endpoints — the unit under test is the parsing /
shape-walking logic, plus the yesterday/7-day window math. We exercise
``_walk_anthropic_buckets`` and ``_walk_openai_buckets`` directly with
fixture payloads, plus the ``fetch_account`` orchestration with the
HTTP layer monkey-patched.
"""
from __future__ import annotations

import asyncio
import json
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pytest

from registry.loader import RegistryEntry
from registry.vendor import (
    AccountSnapshot,
    VendorError,
    _fetch_anthropic,
    _fetch_openai,
    _last_7d_utc_window,
    _walk_anthropic_buckets,
    _walk_openai_buckets,
    fetch_account,
)
import registry.vendor as vendor_mod


FIXTURES = Path(__file__).parent / "fixtures"


def _stamp_anthropic_fixture() -> dict:
    """Substitute today/yesterday/etc placeholders in the fixture."""
    raw = (FIXTURES / "anthropic_cost_report.json").read_text()
    today = date.today()
    for i in range(7):
        raw = raw.replace(f"__DAY_MINUS_{i}__", (today - timedelta(days=i)).isoformat())
    raw = raw.replace("__YESTERDAY__", (today - timedelta(days=1)).isoformat())
    raw = raw.replace("__TODAY__", today.isoformat())
    return json.loads(raw)


def _stamp_openai_fixture() -> dict:
    raw = (FIXTURES / "openai_costs.json").read_text()
    today_start = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    for i in range(7):
        ts = int((today_start - timedelta(days=i)).timestamp())
        raw = raw.replace(f"__TS_DAY_MINUS_{i}__", str(ts))
    raw = raw.replace("__TS_YESTERDAY__", str(int((today_start - timedelta(days=1)).timestamp())))
    raw = raw.replace("__TS_TODAY__", str(int(today_start.timestamp())))
    return json.loads(raw)


def test_walk_anthropic_buckets_skips_non_usd():
    payload = {
        "data": [
            {"starting_at": "2026-05-08T00:00:00Z", "ending_at": "2026-05-09T00:00:00Z",
             "results": [
                 {"amount": "1.0", "currency": "USD", "workspace_id": "w", "api_key_id": "k"},
                 {"amount": "5.0", "currency": "EUR", "workspace_id": "w", "api_key_id": "k"},
             ]},
        ]
    }
    rows = _walk_anthropic_buckets(payload)
    assert len(rows) == 1
    assert rows[0]["usd"] == 1.0


def test_walk_openai_buckets_normalizes_currency_case():
    payload = {
        "data": [
            {"start_time": int(datetime.now(timezone.utc).timestamp()) - 86400,
             "end_time":   int(datetime.now(timezone.utc).timestamp()),
             "results": [
                 {"amount": {"value": 2.5, "currency": "USD"}, "project_id": "p", "api_key_id": "k"},
                 {"amount": {"value": 4.0, "currency": "EUR"}, "project_id": "p", "api_key_id": "k"},
             ]},
        ]
    }
    rows = _walk_openai_buckets(payload)
    assert len(rows) == 1
    assert rows[0]["usd"] == 2.5


@pytest.mark.asyncio
async def test_fetch_anthropic_aggregates_yesterday_and_trend(monkeypatch):
    payload = _stamp_anthropic_fixture()

    async def fake_cost(session, key, s, e, group_by):
        return payload

    async def fake_labels(session, key):
        return {"wrk_main": "Main", "wrk_side": "Side"}

    monkeypatch.setattr(vendor_mod, "_anthropic_cost_report", fake_cost)
    monkeypatch.setattr(vendor_mod, "_anthropic_workspace_labels", fake_labels)

    entry = RegistryEntry(
        id="ant", label="Anthropic", provider="anthropic",
        admin_key="sk-ant-admin-x", groupings=("workspace_id", "api_key_id"),
    )
    snap = await _fetch_anthropic(entry)

    # Yesterday: 8.10 + 4.33 = 12.43
    assert round(snap.yesterday_usd, 2) == 12.43
    assert snap.yesterday_date == (date.today() - timedelta(days=1)).isoformat()

    # Workspace breakdown picks up labels.
    assert snap.by_workspace["wrk_main"]["label"] == "Main"
    assert snap.by_workspace["wrk_main"]["usd"] == 8.10
    assert snap.by_workspace["wrk_side"]["usd"] == 4.33

    # Key tail extracted from partial_key_hint (last 4 chars).
    assert snap.by_key["apikey_prod"]["tail"] == "AbCd"
    assert snap.by_key["apikey_dev"]["tail"]  == "MnOp"

    # 7-day trend: oldest-first. The window starts 7 days ago, so:
    #   trend_7d_usd[0] = today-7   (no data in fixture)
    #   trend_7d_usd[1] = today-6   (= DAY_MINUS_6 → 0.50)
    #   trend_7d_usd[3] = today-4   (= DAY_MINUS_4 → 1.10)
    #   trend_7d_usd[6] = today-1   (= yesterday  → 12.43)
    assert snap.trend_7d_usd[0] == 0.0
    assert snap.trend_7d_usd[1] == 0.50
    assert snap.trend_7d_usd[3] == 1.10
    assert round(snap.trend_7d_usd[6], 2) == 12.43


@pytest.mark.asyncio
async def test_fetch_anthropic_to_dict_shape(monkeypatch):
    payload = _stamp_anthropic_fixture()

    async def fake_cost(*a, **k): return payload
    async def fake_labels(*a, **k): return {}

    monkeypatch.setattr(vendor_mod, "_anthropic_cost_report", fake_cost)
    monkeypatch.setattr(vendor_mod, "_anthropic_workspace_labels", fake_labels)

    entry = RegistryEntry("ant", "A", "anthropic", "sk-ant-admin-x", ("workspace_id", "api_key_id"))
    snap = await _fetch_anthropic(entry)
    d = snap.to_dict()
    assert set(d.keys()) == {"label", "provider", "yesterday", "trend_7d_usd"}
    assert set(d["yesterday"].keys()) == {"date", "usd", "by_workspace", "by_key"}
    assert isinstance(d["trend_7d_usd"], list)
    assert len(d["trend_7d_usd"]) == 7


@pytest.mark.asyncio
async def test_fetch_openai_aggregates_yesterday_and_trend(monkeypatch):
    payload = _stamp_openai_fixture()

    async def fake_costs(*a, **k): return payload
    async def fake_labels(*a, **k): return {"proj_main": "Main", "proj_side": "Side"}

    monkeypatch.setattr(vendor_mod, "_openai_costs", fake_costs)
    monkeypatch.setattr(vendor_mod, "_openai_project_labels", fake_labels)

    entry = RegistryEntry("oai", "O", "openai", "sk-admin-x", ("project_id", "api_key_id"))
    snap = await _fetch_openai(entry)

    assert round(snap.yesterday_usd, 2) == 4.70
    assert snap.by_workspace["proj_main"]["label"] == "Main"
    assert snap.by_workspace["proj_main"]["usd"] == 3.50
    assert snap.by_workspace["proj_side"]["usd"] == 1.20

    # OpenAI key tail = last 4 chars of the opaque api_key_id.
    assert snap.by_key["key_RNDProd"]["tail"] == "Prod"
    assert snap.by_key["key_RNDDev"]["tail"]  == "DDev"

    # Trend: oldest-first; index 1 = day-6 = 0.40, index 6 = yesterday = 4.70.
    assert snap.trend_7d_usd[1] == 0.40
    assert round(snap.trend_7d_usd[6], 2) == 4.70


@pytest.mark.asyncio
async def test_fetch_account_dispatches_by_provider(monkeypatch):
    called = {}

    async def fake_anthropic(entry):
        called["anthropic"] = entry
        return AccountSnapshot(
            label=entry.label, provider="anthropic", yesterday_date="2026-05-08",
            yesterday_usd=0, by_workspace={}, by_key={}, trend_7d_usd=[0]*7,
        )

    monkeypatch.setattr(vendor_mod, "_FETCHERS", {"anthropic": fake_anthropic})
    e = RegistryEntry("a", "A", "anthropic", "sk-ant-admin-x", ())
    snap = await fetch_account(e)
    assert snap.provider == "anthropic"
    assert called["anthropic"] is e


@pytest.mark.asyncio
async def test_fetch_account_unknown_provider_raises():
    e = RegistryEntry("a", "A", "anthropic", "sk-x", ())
    # Coerce to an unknown provider after construction.
    object.__setattr__(e, "provider", "huggingface")  # type: ignore[misc]
    with pytest.raises(VendorError) as ei:
        await fetch_account(e)
    assert ei.value.kind == "provider"


def test_last_7d_window_is_seven_completed_days():
    s, e, days = _last_7d_utc_window()
    assert len(days) == 7
    assert days[-1] == (date.today() - timedelta(days=1)).isoformat()
    assert days[0]  == (date.today() - timedelta(days=7)).isoformat()
