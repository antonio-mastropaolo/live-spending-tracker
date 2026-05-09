"""Reconciler + state-merge tests.

Verifies (a) successful reconcile writes accounts.<id>, (b) per-account
errors land in errors[] without poisoning siblings, (c) merge_account_snapshot
recomputes totals, (d) error rows are cleared on subsequent success.
"""
from __future__ import annotations

import asyncio
import json
from datetime import date

import pytest

from registry.loader import RegistryEntry, save
from registry.vendor import AccountSnapshot, VendorError
import registry.reconciler as recon
import registry.vendor as vendor_mod
import state.manager as sm
from state.manager import (
    load_state,
    merge_account_snapshot,
    prune_accounts,
    record_account_error,
    record_today_estimate,
    _recompute_totals,
)


def _snap(label: str, usd: float = 1.0, trend=None) -> dict:
    return AccountSnapshot(
        label=label, provider="anthropic", yesterday_date="2026-05-08",
        yesterday_usd=usd, by_workspace={"w1": {"label": "L", "usd": usd}},
        by_key={"k1": {"label": "", "tail": "AbCd", "usd": usd}},
        trend_7d_usd=trend or [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, usd],
    ).to_dict()


def test_merge_account_snapshot_writes_and_recomputes_totals():
    merge_account_snapshot("ant1", _snap("Anthropic", usd=10.0))
    merge_account_snapshot("oai1", _snap("OpenAI",    usd=4.5))
    state = load_state()
    assert state["schema_version"] == 2
    assert set(state["accounts"].keys()) == {"ant1", "oai1"}
    assert state["totals"]["yesterday_usd"] == 14.5
    assert state["totals"]["trend_7d_usd"][6] == 14.5


def test_merge_clears_prior_error_for_same_account():
    record_account_error("ant1", "auth", "401")
    assert any(e["account_id"] == "ant1" for e in load_state()["errors"])

    merge_account_snapshot("ant1", _snap("Anthropic"))
    assert not any(e["account_id"] == "ant1" for e in load_state()["errors"])


def test_record_account_error_dedupes_kind_per_account():
    record_account_error("oai1", "auth", "first")
    record_account_error("oai1", "auth", "second")
    record_account_error("oai1", "network", "transient")
    errors = load_state()["errors"]
    auth = [e for e in errors if e["account_id"] == "oai1" and e["kind"] == "auth"]
    assert len(auth) == 1
    assert auth[0]["msg"] == "second"
    assert any(e["kind"] == "network" for e in errors if e["account_id"] == "oai1")


def test_record_today_estimate_does_not_clobber_v1_state():
    # Seed a v1-shaped state.json (no v2 fields).
    sm.STATE_FILE.write_text(json.dumps({
        "date": date.today().isoformat(),
        "total_usd": 1.23,
        "by_provider": {"anthropic": 1.23},
        "by_model": {},
        "by_key": {},
    }))
    record_today_estimate(1.23)
    state = load_state()
    # v2 hook stamped its field.
    assert state["today_estimate"]["usd"] == 1.23
    # v1 fields untouched.
    assert state["total_usd"] == 1.23
    assert state["by_provider"] == {"anthropic": 1.23}


@pytest.mark.asyncio
async def test_reconcile_one_records_vendor_error(monkeypatch):
    async def boom(_entry):
        raise VendorError("auth", "HTTP 401: invalid_api_key")

    monkeypatch.setattr(recon, "fetch_account", boom)
    entry = RegistryEntry("oai1", "OpenAI", "openai", "sk-admin-bad", ())
    await recon._reconcile_one(entry)

    state = load_state()
    assert "oai1" not in state["accounts"]
    assert any(e["account_id"] == "oai1" and e["kind"] == "auth" for e in state["errors"])


@pytest.mark.asyncio
async def test_reconcile_one_records_network_error(monkeypatch):
    async def boom(_entry):
        raise asyncio.TimeoutError("upstream timeout")

    monkeypatch.setattr(recon, "fetch_account", boom)
    entry = RegistryEntry("oai1", "OpenAI", "openai", "sk-admin-x", ())
    await recon._reconcile_one(entry)
    state = load_state()
    assert any(e["kind"] == "network" for e in state["errors"])


@pytest.mark.asyncio
async def test_reconcile_one_success_writes_account(monkeypatch):
    async def ok(entry):
        return AccountSnapshot(
            label=entry.label, provider="anthropic", yesterday_date="2026-05-08",
            yesterday_usd=7.5, by_workspace={}, by_key={},
            trend_7d_usd=[0]*6 + [7.5],
        )

    monkeypatch.setattr(recon, "fetch_account", ok)
    entry = RegistryEntry("ant1", "A", "anthropic", "sk-ant-admin-x", ())
    await recon._reconcile_one(entry)
    state = load_state()
    assert state["accounts"]["ant1"]["yesterday"]["usd"] == 7.5


@pytest.mark.asyncio
async def test_reconcile_once_isolates_errors_across_accounts(monkeypatch):
    """Path: bad-key account fails, good account succeeds — both reflected
    in state.json, neither poisons the other."""
    async def fetch(entry):
        if entry.id == "bad":
            raise VendorError("auth", "401")
        return AccountSnapshot(
            label=entry.label, provider="anthropic", yesterday_date="2026-05-08",
            yesterday_usd=2.5, by_workspace={}, by_key={},
            trend_7d_usd=[0]*6 + [2.5],
        )

    monkeypatch.setattr(recon, "fetch_account", fetch)
    entries = [
        RegistryEntry("good", "G", "anthropic", "sk-ant-admin-1", ()),
        RegistryEntry("bad",  "B", "anthropic", "sk-ant-admin-2", ()),
    ]
    n = await recon.reconcile_once(entries=entries)
    assert n == 2
    state = load_state()
    assert "good" in state["accounts"]
    assert "bad" not in state["accounts"]
    assert any(e["account_id"] == "bad" for e in state["errors"])


@pytest.mark.asyncio
async def test_reconcile_once_loads_registry_when_no_arg(monkeypatch):
    save([RegistryEntry("ant1", "A", "anthropic", "sk-ant-admin-x", ())])

    async def ok(entry):
        return AccountSnapshot(
            label=entry.label, provider="anthropic", yesterday_date="2026-05-08",
            yesterday_usd=1.0, by_workspace={}, by_key={}, trend_7d_usd=[0]*7,
        )

    monkeypatch.setattr(recon, "fetch_account", ok)
    n = await recon.reconcile_once()
    assert n == 1
    assert load_state()["accounts"]["ant1"]["yesterday"]["usd"] == 1.0


def test_prune_accounts_drops_disabled_and_recomputes_totals():
    # Two accounts, then prune one out: totals shrink and errors are swept.
    merge_account_snapshot("ant1", _snap("Anthropic", usd=10.0))
    merge_account_snapshot("oai1", _snap("OpenAI",    usd=4.5))
    record_account_error("oai1", "auth", "401")

    prune_accounts({"ant1"})
    state = load_state()
    assert set(state["accounts"].keys()) == {"ant1"}
    assert state["totals"]["yesterday_usd"] == 10.0
    assert not any(e["account_id"] == "oai1" for e in state["errors"])


@pytest.mark.asyncio
async def test_reconcile_once_skips_disabled_entries(monkeypatch):
    """Disabled entries: no fetch attempted, account pruned from state."""
    fetched: list[str] = []

    async def fetch(entry):
        fetched.append(entry.id)
        return AccountSnapshot(
            label=entry.label, provider="anthropic", yesterday_date="2026-05-08",
            yesterday_usd=1.0, by_workspace={}, by_key={}, trend_7d_usd=[0]*7,
        )

    # Pre-seed a stale snapshot for the soon-to-be-disabled account.
    merge_account_snapshot("dis", _snap("Disabled", usd=99.0))
    assert load_state()["totals"]["yesterday_usd"] == 99.0

    monkeypatch.setattr(recon, "fetch_account", fetch)
    entries = [
        RegistryEntry("ant",  "A", "anthropic", "sk-ant-admin-x", (), enabled=True),
        RegistryEntry("dis",  "D", "anthropic", "sk-ant-admin-y", (), enabled=False),
    ]
    n = await recon.reconcile_once(entries=entries)
    assert n == 1
    assert fetched == ["ant"]
    state = load_state()
    assert "ant" in state["accounts"]
    assert "dis" not in state["accounts"]            # pruned
    assert state["totals"]["yesterday_usd"] == 1.0   # disabled account excluded


@pytest.mark.asyncio
async def test_reconcile_once_with_all_disabled_still_prunes(monkeypatch):
    merge_account_snapshot("zombie", _snap("Z", usd=7.0))
    monkeypatch.setattr(recon, "fetch_account", lambda *_: pytest.fail("should not fetch"))
    n = await recon.reconcile_once(entries=[
        RegistryEntry("zombie", "Z", "anthropic", "sk-ant-admin-x", (), enabled=False),
    ])
    assert n == 0
    state = load_state()
    assert "zombie" not in state["accounts"]
    assert state["totals"]["yesterday_usd"] == 0.0


def test_recompute_totals_handles_missing_fields():
    accounts = {
        "a": {"yesterday": {}, "trend_7d_usd": []},
        "b": {"yesterday": {"usd": 2}, "trend_7d_usd": [1]},  # short trend padded with zeros
        "c": {},
    }
    t = _recompute_totals(accounts)
    assert t["yesterday_usd"] == 2
    assert t["trend_7d_usd"][0] == 1
    assert t["trend_7d_usd"][6] == 0
