"""Test configuration: re-route ~/.ai-spending/ to a per-test tmp dir
so unit tests never touch the operator's real registry or admin keys.
"""
from __future__ import annotations

import importlib
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def isolate_state_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    """Point STATE_DIR / REGISTRY_FILE at a tmp path. Re-import the module
    attributes through monkeypatch so any module that already imported
    these symbols sees the patched value."""
    fake = tmp_path / ".ai-spending"
    fake.mkdir()

    import state.manager as sm
    monkeypatch.setattr(sm, "STATE_DIR", fake, raising=True)
    monkeypatch.setattr(sm, "STATE_FILE", fake / "state.json", raising=True)

    import registry.loader as rl
    monkeypatch.setattr(rl, "REGISTRY_DIR", fake, raising=True)
    monkeypatch.setattr(rl, "REGISTRY_FILE", fake / "registry.json", raising=True)
    monkeypatch.setattr(rl, "BUDGETS_FILE", fake / "budgets.json", raising=True)

    import state.history as sh
    monkeypatch.setattr(sh, "HISTORY_FILE", fake / "history.json", raising=True)
    monkeypatch.setattr(sh, "LOCK_FILE", fake / ".history.lock", raising=True)

    yield fake
