"""state/history.py — JSON rollup round-trip, prune, malformed tolerance."""
from __future__ import annotations

import json

import pytest

from state.history import (
    MAX_DAYS,
    load_history,
    prune_history,
    update_history,
)
import state.history as sh


def test_load_returns_empty_when_file_missing():
    assert load_history() == {}


def test_update_history_round_trip():
    update_history({
        "ant1": {"2026-05-01": 1.0, "2026-05-02": 2.5},
        "oai1": {"2026-05-02": 0.0},
    })
    out = load_history()
    assert out["ant1"]["2026-05-01"] == 1.0
    assert out["ant1"]["2026-05-02"] == 2.5
    assert out["oai1"]["2026-05-02"] == 0.0


def test_update_history_overwrites_same_date():
    update_history({"ant1": {"2026-05-01": 1.0}})
    update_history({"ant1": {"2026-05-01": 4.5}})  # vendor revised yesterday
    assert load_history()["ant1"]["2026-05-01"] == 4.5


def test_update_merges_without_dropping_other_dates():
    update_history({"ant1": {"2026-05-01": 1.0}})
    update_history({"ant1": {"2026-05-02": 2.0}})
    days = load_history()["ant1"]
    assert days["2026-05-01"] == 1.0
    assert days["2026-05-02"] == 2.0


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
    # Should not raise — UI must tolerate junk in this file.
    assert load_history() == {}


def test_load_skips_non_dict_values():
    sh.HISTORY_FILE.write_text(json.dumps({
        "ant1": "not-a-dict",
        "oai1": {"2026-05-01": 1.0, "bad": "value"},
    }))
    out = load_history()
    assert out == {"oai1": {"2026-05-01": 1.0}}


def test_trim_keeps_only_most_recent_max_days():
    # Build a stream of 200 daily entries and verify only the newest
    # MAX_DAYS survive.
    days = {f"2025-01-{i:02d}": float(i) for i in range(1, 32)}            # 31 days
    days.update({f"2025-02-{i:02d}": float(31 + i) for i in range(1, 29)}) # 28 days
    days.update({f"2025-03-{i:02d}": float(60 + i) for i in range(1, 32)}) # 31 days
    days.update({f"2025-04-{i:02d}": float(91 + i) for i in range(1, 31)}) # 30 days
    days.update({f"2025-05-{i:02d}": float(122 + i) for i in range(1, 32)})# 31 days
    # Total: 151 entries
    update_history({"ant1": days})
    out = load_history()["ant1"]
    assert len(out) == min(len(days), MAX_DAYS)
    # Newest date is preserved
    assert "2025-05-31" in out


def test_update_skips_non_numeric_values():
    update_history({"ant1": {"2026-05-01": 1.0}})
    update_history({"ant1": {"2026-05-02": "garbage"}})
    out = load_history()["ant1"]
    assert out == {"2026-05-01": 1.0}
