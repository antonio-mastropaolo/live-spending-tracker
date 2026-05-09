"""Loader tests: round-trip, validation, malformed input, unknown keys."""
from __future__ import annotations

import json

import pytest

import registry.loader as rl
from registry.loader import (
    RegistryEntry,
    RegistryError,
    SUPPORTED_PROVIDERS,
    load,
    save,
    set_enabled,
)


def REGISTRY_FILE():
    """Always read the live (test-patched) value rather than capturing a
    stale module attribute at import time."""
    return rl.REGISTRY_FILE


def test_load_missing_returns_empty():
    assert load() == []


def test_save_and_load_roundtrip():
    entries = [
        RegistryEntry(
            id="ant1", label="Anthropic Personal", provider="anthropic",
            admin_key="sk-ant-admin-abc", groupings=("workspace_id", "api_key_id"),
        ),
        RegistryEntry(
            id="oai1", label="OpenAI", provider="openai",
            admin_key="sk-admin-xyz", groupings=("project_id", "api_key_id"),
        ),
    ]
    save(entries)
    out = load()
    assert {e.id for e in out} == {"ant1", "oai1"}
    ant = next(e for e in out if e.id == "ant1")
    assert ant.provider == "anthropic"
    assert ant.admin_key == "sk-ant-admin-abc"


def test_save_writes_0600_permissions():
    save([RegistryEntry("a", "A", "anthropic", "sk-ant-admin-x", ())])
    mode = REGISTRY_FILE().stat().st_mode & 0o777
    assert mode == 0o600


def test_load_skips_invalid_entry_keeps_others(caplog):
    REGISTRY_FILE().write_text(json.dumps([
        {"id": "good", "label": "G", "provider": "anthropic", "admin_key": "sk-ant-admin-x"},
        {"id": "bad-no-key", "label": "B", "provider": "anthropic"},  # missing admin_key
        {"id": "bad-provider", "label": "B", "provider": "huggingface", "admin_key": "k"},
    ]))
    entries = load()
    assert [e.id for e in entries] == ["good"]


def test_load_skips_duplicate_ids():
    REGISTRY_FILE().write_text(json.dumps([
        {"id": "dup", "label": "A", "provider": "anthropic", "admin_key": "sk-ant-admin-1"},
        {"id": "dup", "label": "B", "provider": "openai", "admin_key": "sk-admin-2"},
    ]))
    entries = load()
    assert len(entries) == 1
    assert entries[0].provider == "anthropic"


def test_load_tolerates_unknown_keys_for_forward_compat():
    REGISTRY_FILE().write_text(json.dumps([
        {"id": "x", "label": "X", "provider": "openai", "admin_key": "sk-admin-x",
         "future_field": "ignored", "another": {"nested": True}},
    ]))
    entries = load()
    assert len(entries) == 1
    assert entries[0].id == "x"


def test_load_default_groupings_filled_in():
    REGISTRY_FILE().write_text(json.dumps([
        {"id": "a", "label": "A", "provider": "anthropic", "admin_key": "sk-ant-admin-x"},
    ]))
    entries = load()
    assert entries[0].groupings == ("workspace_id", "api_key_id")


def test_load_malformed_json_raises():
    REGISTRY_FILE().write_text("{ not json")
    with pytest.raises(RegistryError):
        load()


def test_load_non_array_raises():
    REGISTRY_FILE().write_text(json.dumps({"id": "x"}))
    with pytest.raises(RegistryError):
        load()


def test_supported_providers_locked():
    # Sanity check — if this changes, the UI provider matrix needs updating too.
    assert SUPPORTED_PROVIDERS == frozenset({"anthropic", "openai"})


def test_enabled_defaults_true_when_missing():
    REGISTRY_FILE().write_text(json.dumps([
        {"id": "a", "label": "A", "provider": "anthropic", "admin_key": "sk-ant-admin-x"},
    ]))
    entries = load()
    assert entries[0].enabled is True


def test_enabled_false_round_trips():
    save([RegistryEntry("a", "A", "anthropic", "sk-ant-admin-x", (), enabled=False)])
    entries = load()
    assert entries[0].enabled is False


def test_enabled_must_be_bool():
    REGISTRY_FILE().write_text(json.dumps([
        {"id": "a", "label": "A", "provider": "anthropic",
         "admin_key": "sk-ant-admin-x", "enabled": "yes"},
    ]))
    # bad enabled → entry skipped, but loader doesn't crash.
    assert load() == []


def test_set_enabled_flips_existing_entry():
    save([
        RegistryEntry("a", "A", "anthropic", "sk-ant-admin-x", ()),
        RegistryEntry("b", "B", "openai",    "sk-admin-x",     ()),
    ])
    assert set_enabled("a", False) is True
    entries = load()
    by_id = {e.id: e for e in entries}
    assert by_id["a"].enabled is False
    assert by_id["b"].enabled is True   # untouched


def test_set_enabled_unknown_id_returns_false():
    save([RegistryEntry("a", "A", "anthropic", "sk-ant-admin-x", ())])
    assert set_enabled("nope", False) is False
    assert load()[0].enabled is True
