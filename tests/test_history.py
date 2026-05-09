"""state/history.py — JSON rollup round-trip, prune, malformed tolerance.

Each day on-disk is now the rich shape `{usd, by_workspace, by_key}`. The
loader normalizes legacy float entries to the same shape so existing
~/.ai-spending/history.json files keep working.
"""
from __future__ import annotations

import json

import pytest

from state.history import (
    MAX_DAYS,
    load_history,
    prune_history,
    total_for,
    update_history,
)
import state.history as sh


def test_load_returns_empty_when_file_missing():
    assert load_history() == {}


def test_update_history_round_trip_with_floats():
    """Float input still works — it's the legacy shape, and gets upgraded
    to the rich form on storage."""
    update_history({
        "ant1": {"2026-05-01": 1.0, "2026-05-02": 2.5},
        "oai1": {"2026-05-02": 0.0},
    })
    out = load_history()
    assert out["ant1"]["2026-05-01"]["usd"] == 1.0
    assert out["ant1"]["2026-05-01"]["by_workspace"] == {}
    assert out["ant1"]["2026-05-01"]["by_key"] == {}
    assert out["ant1"]["2026-05-02"]["usd"] == 2.5
    assert out["oai1"]["2026-05-02"]["usd"] == 0.0


def test_update_history_round_trip_rich_shape():
    update_history({
        "ant1": {"2026-05-01": {
            "usd": 12.43,
            "by_workspace": {"wrk_main": {"label": "Coder Bot", "usd": 8.10}},
            "by_key": {"apikey_X": {"label": "prod", "tail": "AbCd", "usd": 11.20}},
        }},
    })
    e = load_history()["ant1"]["2026-05-01"]
    assert e["usd"] == 12.43
    assert e["by_workspace"]["wrk_main"]["label"] == "Coder Bot"
    assert e["by_workspace"]["wrk_main"]["usd"] == 8.10
    assert e["by_key"]["apikey_X"]["tail"] == "AbCd"


def test_total_for_helper():
    update_history({"ant1": {"2026-05-01": 4.20}})
    assert total_for("ant1", "2026-05-01") == 4.20
    assert total_for("ant1", "2026-12-31") == 0.0
    assert total_for("missing", "2026-05-01") == 0.0


def test_legacy_float_file_still_loads():
    """A history.json from before the schema bump is still readable."""
    sh.HISTORY_FILE.write_text(json.dumps({"ant1": {"2026-05-01": 1.5}}))
    out = load_history()
    assert out["ant1"]["2026-05-01"]["usd"] == 1.5


def test_update_history_overwrites_same_date():
    update_history({"ant1": {"2026-05-01": 1.0}})
    update_history({"ant1": {"2026-05-01": 4.5}})  # vendor revised yesterday
    assert load_history()["ant1"]["2026-05-01"]["usd"] == 4.5


def test_update_merges_without_dropping_other_dates():
    update_history({"ant1": {"2026-05-01": 1.0}})
    update_history({"ant1": {"2026-05-02": 2.0}})
    days = load_history()["ant1"]
    assert days["2026-05-01"]["usd"] == 1.0
    assert days["2026-05-02"]["usd"] == 2.0


def test_prune_history_drops_unknown_accounts():
    update_history({
        "ant1": {"2026-05-01": 1.0},
        "oai1": {"2026-05-01": 2.0},
        "stale": {"2026-05-01": 9.0},
    })
    prune_history({"ant1", "oai1"})
    out = load_history()
    assert set(out.keys()) == {"ant1", "oai1"}


def test_load_handles_malformed_json():
    sh.HISTORY_FILE.write_text("{ not json")
    assert load_history() == {}


def test_load_skips_non_dict_account_values():
    sh.HISTORY_FILE.write_text(json.dumps({
        "ant1": "not-a-dict",
        "oai1": {"2026-05-01": 1.0, "bad-day-value": ["nope"]},
    }))
    out = load_history()
    assert "ant1" not in out
    assert out["oai1"]["2026-05-01"]["usd"] == 1.0
    assert "bad-day-value" not in out["oai1"]


def test_trim_keeps_only_most_recent_max_days():
    days = {f"2025-01-{i:02d}": float(i) for i in range(1, 32)}
    days.update({f"2025-02-{i:02d}": float(31 + i) for i in range(1, 29)})
    days.update({f"2025-03-{i:02d}": float(60 + i) for i in range(1, 32)})
    days.update({f"2025-04-{i:02d}": float(91 + i) for i in range(1, 31)})
    days.update({f"2025-05-{i:02d}": float(122 + i) for i in range(1, 32)})
    update_history({"ant1": days})
    out = load_history()["ant1"]
    assert len(out) == min(len(days), MAX_DAYS)
    assert "2025-05-31" in out


def test_update_skips_non_numeric_values():
    update_history({"ant1": {"2026-05-01": 1.0}})
    update_history({"ant1": {"2026-05-02": "garbage"}})
    out = load_history()["ant1"]
    assert "2026-05-01" in out
    assert "2026-05-02" not in out
