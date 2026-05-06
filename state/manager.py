import fcntl
import json
import os
import tempfile
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Optional

STATE_DIR = Path.home() / ".ai-spending"
STATE_FILE = STATE_DIR / "state.json"
_PRICING_FILE = Path(__file__).parent.parent / "proxy" / "pricing.json"

_pricing_cache: Optional[dict] = None


def _load_pricing() -> dict:
    global _pricing_cache
    if _pricing_cache is None:
        with open(_PRICING_FILE) as f:
            _pricing_cache = json.load(f)
    return _pricing_cache


def _match_price(provider: str, model: str) -> Optional[dict]:
    """Return {"input": float, "output": float} for the closest model match."""
    provider_pricing = _load_pricing().get(provider, {})
    if model in provider_pricing:
        return provider_pricing[model]
    best, best_len = None, 0
    for key, prices in provider_pricing.items():
        if model.startswith(key) and len(key) > best_len:
            best, best_len = prices, len(key)
    return best


def _empty_state() -> dict:
    return {
        "date": date.today().isoformat(),
        "total_usd": 0.0,
        "by_provider": {},
        "by_model": {},
        "cache_creation_tokens": 0,
        "cache_read_tokens": 0,
        "last_updated": datetime.now(timezone.utc).isoformat(),
    }


def load_state() -> dict:
    if not STATE_FILE.exists():
        return _empty_state()
    try:
        with open(STATE_FILE) as f:
            state = json.load(f)
        if state.get("date") != date.today().isoformat():
            return _empty_state()
        return state
    except (json.JSONDecodeError, OSError):
        return _empty_state()


def record_usage(
    provider: str,
    model: str,
    input_tokens: int,
    output_tokens: int,
    cache_creation: int = 0,
    cache_read: int = 0,
):
    prices = _match_price(provider, model)
    cost = 0.0
    if prices:
        cost = (input_tokens * prices["input"] + output_tokens * prices["output"]) / 1_000_000

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    lock_path = STATE_DIR / ".state.lock"

    with open(lock_path, "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            state = load_state()
            state["total_usd"] = round(state["total_usd"] + cost, 8)
            bp = state["by_provider"]
            bp[provider] = round(bp.get(provider, 0.0) + cost, 8)
            bm = state["by_model"]
            bm[model] = round(bm.get(model, 0.0) + cost, 8)
            state["cache_creation_tokens"] = state.get("cache_creation_tokens", 0) + cache_creation
            state["cache_read_tokens"] = state.get("cache_read_tokens", 0) + cache_read
            state["last_updated"] = datetime.now(timezone.utc).isoformat()
            _write_state(state)
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


def reset_state():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    _write_state(_empty_state())


def _write_state(state: dict):
    tmp = tempfile.NamedTemporaryFile(
        mode="w", dir=STATE_DIR, delete=False, suffix=".tmp"
    )
    try:
        json.dump(state, tmp, indent=2)
        tmp.flush()
        os.fsync(tmp.fileno())
        tmp.close()
        os.replace(tmp.name, STATE_FILE)
    except Exception:
        tmp.close()
        try:
            os.unlink(tmp.name)
        except OSError:
            pass
        raise
