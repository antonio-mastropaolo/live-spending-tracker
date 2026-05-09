"""90-day daily-rollup history at ~/.ai-spending/history.json.

Schema (mode 0600):

    {
      "<account_id>": {"YYYY-MM-DD": <usd_float>, ...},
      ...
    }

Why JSON, not sqlite: ≤ ~1 KB per account at 90 days, no new dependency,
atomic writes via the same temp-file dance the rest of the project uses,
and the Swift side can read it with one ``JSONSerialization`` call.

Ownership:
    - The v2 reconciler writes here (one merge per tick, after the snapshot
      lands in state.json). See ``registry/reconciler.py``.
    - The Swift store reads here (lazy, with a small in-process cache).
    - History for a no-longer-active account is pruned, mirroring
      ``state.manager.prune_accounts``.

Concurrency: all writes go through ``_write_history`` which holds the
shared fcntl lock at ``state.manager.STATE_DIR/.history.lock`` for the
duration of the merge. Locks are FILE-scoped — a writer here doesn't
block a writer to state.json.
"""

from __future__ import annotations

import fcntl
import json
import logging
import os
import tempfile
from pathlib import Path
from typing import Iterable

from state.manager import STATE_DIR

logger = logging.getLogger(__name__)

HISTORY_FILE = STATE_DIR / "history.json"
LOCK_FILE = STATE_DIR / ".history.lock"

# Bound the on-disk size. 120 days is enough for 90-day heatmap + a little
# slack for time-zone weirdness. Older entries are dropped on every write.
MAX_DAYS = 120


def load_history() -> dict[str, dict[str, float]]:
    """Return {account_id: {date_iso: usd}}. Empty dict if file is absent
    or malformed — never raises. Reader-friendly because the Swift side
    polls this without a lock."""
    if not HISTORY_FILE.exists():
        return {}
    try:
        raw = json.loads(HISTORY_FILE.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        logger.warning("history.json unreadable: %s — treating as empty", exc)
        return {}
    if not isinstance(raw, dict):
        return {}
    out: dict[str, dict[str, float]] = {}
    for aid, days in raw.items():
        if not isinstance(aid, str) or not isinstance(days, dict):
            continue
        clean: dict[str, float] = {}
        for d, v in days.items():
            if not isinstance(d, str):
                continue
            try:
                clean[d] = float(v)
            except (TypeError, ValueError):
                continue
        out[aid] = clean
    return out


def update_history(snapshots: dict[str, dict[str, float]]) -> None:
    """Merge per-account daily totals into history.json.

    `snapshots` shape: {account_id: {date_iso: usd, ...}}. Existing dates
    for the same (account_id) are OVERWRITTEN — vendor data is canonical
    and may revise yesterday's number for ~24h after rollover.
    """
    if not snapshots:
        return
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with open(LOCK_FILE, "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            current = load_history()
            for aid, days in snapshots.items():
                bucket = current.setdefault(aid, {})
                for d, v in days.items():
                    try:
                        bucket[d] = round(float(v), 4)
                    except (TypeError, ValueError):
                        continue
            current = _trim(current)
            _write_history(current)
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


def prune_history(keep_account_ids: Iterable[str]) -> None:
    """Drop history for any account_id not in `keep_account_ids`. Mirrors
    ``state.manager.prune_accounts`` — when an account is disabled or
    removed, its history goes too so the heatmap doesn't surface stale
    spend.
    """
    keep = set(keep_account_ids)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with open(LOCK_FILE, "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            current = load_history()
            new = {aid: days for aid, days in current.items() if aid in keep}
            if new != current:
                _write_history(new)
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _trim(hist: dict[str, dict[str, float]]) -> dict[str, dict[str, float]]:
    """Keep only the most recent MAX_DAYS dates per account. Compares ISO
    strings lexicographically — works because ISO-8601 dates sort
    chronologically."""
    out: dict[str, dict[str, float]] = {}
    for aid, days in hist.items():
        if len(days) <= MAX_DAYS:
            out[aid] = days
            continue
        keep_keys = sorted(days.keys())[-MAX_DAYS:]
        out[aid] = {k: days[k] for k in keep_keys}
    return out


def _write_history(payload: dict[str, dict[str, float]]) -> None:
    tmp = tempfile.NamedTemporaryFile(
        mode="w", dir=STATE_DIR, delete=False, suffix=".tmp"
    )
    try:
        json.dump(payload, tmp, indent=2, sort_keys=True)
        tmp.flush()
        os.fsync(tmp.fileno())
        tmp.close()
        os.replace(tmp.name, HISTORY_FILE)
        try:
            os.chmod(HISTORY_FILE, 0o600)
        except OSError:
            pass
    except Exception:
        tmp.close()
        try:
            os.unlink(tmp.name)
        except OSError:
            pass
        raise
