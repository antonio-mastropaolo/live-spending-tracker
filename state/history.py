"""90-day daily-rollup history at ~/.ai-spending/history.json.

Schema (mode 0600), v2 (rich):

    {
      "<account_id>": {
        "YYYY-MM-DD": {
          "usd":          <float>,
          "by_workspace": {"<ws_id>":  {"label": "...", "usd": <float>}, ...},
          "by_key":       {"<key_id>": {"label": "...", "tail": "...", "usd": <float>}, ...}
        },
        ...
      },
      ...
    }

For backwards compatibility, day entries written by the previous shape
(`<usd_float>`) are still accepted on read and normalized to the rich
form with empty ``by_workspace`` / ``by_key`` slots. New writes always
use the rich form.

Why JSON, not sqlite: even with breakdowns this is ≤ ~10 KB per account
at 90 days, no new dependency, atomic writes via the same temp-file
dance the rest of the project uses, and the Swift side can read it
with one ``JSONSerialization`` call.

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


def load_history() -> dict[str, dict[str, dict]]:
    """Return {account_id: {date_iso: {usd, by_workspace, by_key}}}. Empty
    dict if file is absent or malformed — never raises. Old float-only
    entries are upgraded to the rich shape with empty breakdowns."""
    if not HISTORY_FILE.exists():
        return {}
    try:
        raw = json.loads(HISTORY_FILE.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        logger.warning("history.json unreadable: %s — treating as empty", exc)
        return {}
    if not isinstance(raw, dict):
        return {}
    out: dict[str, dict[str, dict]] = {}
    for aid, days in raw.items():
        if not isinstance(aid, str) or not isinstance(days, dict):
            continue
        clean: dict[str, dict] = {}
        for d, v in days.items():
            if not isinstance(d, str):
                continue
            entry = _normalize_day_entry(v)
            if entry is not None:
                clean[d] = entry
        out[aid] = clean
    return out


def total_for(account_id: str, date_iso: str) -> float:
    """Convenience accessor for callers that only care about the day's
    total. Returns 0 when the account or date is missing."""
    hist = load_history()
    return float((hist.get(account_id, {}).get(date_iso, {}) or {}).get("usd", 0.0) or 0.0)


def update_history(snapshots: dict[str, dict[str, object]]) -> None:
    """Merge per-account daily entries into history.json.

    `snapshots` shape: {account_id: {date_iso: <entry>}}, where <entry> is
    either a float (legacy / total-only callers) or the rich form
    {usd, by_workspace, by_key}. Either way the on-disk record is the
    rich shape. Existing dates for the same (account_id) are
    OVERWRITTEN — vendor data is canonical and may revise yesterday's
    number for ~24h after rollover.
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
                    entry = _normalize_day_entry(v)
                    if entry is not None:
                        bucket[d] = entry
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

def _normalize_day_entry(raw: object) -> dict | None:
    """Coerce a single day's value to the rich form `{usd, by_workspace,
    by_key}`. Accepts:
      - bare float / int → upgraded with empty breakdowns (legacy shape)
      - dict with at least a numeric `usd` field → cleaned
    Anything else → None (caller skips).
    """
    if isinstance(raw, bool):       # bools are also ints in Python; reject
        return None
    if isinstance(raw, (int, float)):
        return {"usd": round(float(raw), 4), "by_workspace": {}, "by_key": {}}
    if not isinstance(raw, dict):
        return None
    try:
        usd = round(float(raw.get("usd", 0.0)), 4)
    except (TypeError, ValueError):
        return None
    bw_raw = raw.get("by_workspace")
    bk_raw = raw.get("by_key")
    by_workspace: dict[str, dict] = {}
    if isinstance(bw_raw, dict):
        for wid, w in bw_raw.items():
            if not isinstance(wid, str) or not isinstance(w, dict):
                continue
            try:
                wv = round(float(w.get("usd", 0.0)), 4)
            except (TypeError, ValueError):
                continue
            by_workspace[wid] = {
                "label": str(w.get("label") or wid),
                "usd":   wv,
            }
    by_key: dict[str, dict] = {}
    if isinstance(bk_raw, dict):
        for kid, k in bk_raw.items():
            if not isinstance(kid, str) or not isinstance(k, dict):
                continue
            try:
                kv = round(float(k.get("usd", 0.0)), 4)
            except (TypeError, ValueError):
                continue
            by_key[kid] = {
                "label": str(k.get("label") or ""),
                "tail":  str(k.get("tail") or ""),
                "usd":   kv,
            }
    return {"usd": usd, "by_workspace": by_workspace, "by_key": by_key}


def _trim(hist: dict[str, dict[str, dict]]) -> dict[str, dict[str, dict]]:
    """Keep only the most recent MAX_DAYS dates per account. Compares ISO
    strings lexicographically — works because ISO-8601 dates sort
    chronologically."""
    out: dict[str, dict[str, dict]] = {}
    for aid, days in hist.items():
        if len(days) <= MAX_DAYS:
            out[aid] = days
            continue
        keep_keys = sorted(days.keys())[-MAX_DAYS:]
        out[aid] = {k: days[k] for k in keep_keys}
    return out


def _write_history(payload: dict[str, dict[str, dict]]) -> None:
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
