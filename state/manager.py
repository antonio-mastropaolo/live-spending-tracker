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
        # schema_version 2 declares that v2 keys (accounts/totals/errors/
        # today_estimate) MAY be present. v1 writers continue to populate
        # the v1 keys below; readers must tolerate missing fields on either side.
        "schema_version": 2,
        "date": date.today().isoformat(),
        "total_usd": 0.0,
        "by_provider": {},
        "by_model": {},
        "by_key": {},
        "vendor_truth": {},                # {provider: {usd, fetched_at, source}}
        "drift": {},                       # {provider: {state, delta_pct, ...}} — see reconciler.py
        # Snapshot of the previous day's totals, kept so the reconciler can
        # compare apples-to-apples against vendor cost-report endpoints
        # (which only expose completed-day buckets).
        "yesterday_date": None,
        "yesterday_by_provider": {},
        "yesterday_total_usd": 0.0,
        "cache_creation_tokens": 0,
        "cache_read_tokens": 0,
        "last_updated": datetime.now(timezone.utc).isoformat(),
        "last_reconciled": None,
        # v2 multi-account fields. Populated by registry/reconciler.py when
        # ~/.ai-spending/registry.json exists. Empty here so readers always
        # see the same shape.
        "accounts": {},                    # {account_id: {label, provider, yesterday, trend_7d_usd}}
        "totals": {"yesterday_usd": 0.0, "trend_7d_usd": []},
        "errors": [],                      # [{account_id, kind, msg, at}]
        "today_estimate": None,            # {usd, last_updated} — proxy intra-day, optional
    }


def _rollover_if_stale(state: dict) -> dict:
    """If state['date'] is older than today, return a fresh state whose
    yesterday_* fields snapshot the previous day's totals. The previous
    day is whatever date was on the stale state — there's no in-between
    history. If state is already today, return it unchanged.

    v2 fields (accounts/totals/errors/today_estimate) are preserved across
    rollover unchanged: they're vendor-driven and live on their own daily
    cycle keyed off `accounts.<id>.yesterday.date`. The proxy's daily
    rollover is independent.
    """
    today = date.today().isoformat()
    if state.get("date") == today:
        return state
    fresh = _empty_state()
    fresh["yesterday_date"] = state.get("date")
    fresh["yesterday_by_provider"] = dict(state.get("by_provider", {}) or {})
    fresh["yesterday_total_usd"] = state.get("total_usd", 0.0) or 0.0
    # Carry v2 fields across — they aren't rolled by the proxy's local clock.
    fresh["accounts"] = state.get("accounts", {}) or {}
    fresh["totals"] = state.get("totals", {"yesterday_usd": 0.0, "trend_7d_usd": []}) \
        or {"yesterday_usd": 0.0, "trend_7d_usd": []}
    fresh["errors"] = state.get("errors", []) or []
    fresh["today_estimate"] = state.get("today_estimate")
    fresh["last_reconciled"] = state.get("last_reconciled")
    return fresh


def load_state() -> dict:
    if not STATE_FILE.exists():
        return _empty_state()
    try:
        with open(STATE_FILE) as f:
            state = json.load(f)
        return _rollover_if_stale(state)
    except (json.JSONDecodeError, OSError):
        return _empty_state()


def record_usage(
    provider: str,
    model: str,
    input_tokens: int,
    output_tokens: int,
    cache_creation: int = 0,
    cache_read: int = 0,
    key_fp: Optional[str] = None,
    key_tail: Optional[str] = None,
) -> float:
    """Record one API call. Returns the call's USD cost so the proxy can
    feed it directly into the burn-rate buffer without re-doing the
    pricing lookup."""
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
            if key_fp:
                bk = state.setdefault("by_key", {})
                now = datetime.now(timezone.utc).isoformat()
                entry = bk.get(key_fp) or {
                    "tail": key_tail or "",
                    "provider": provider,
                    "usd": 0.0,
                    "first_seen": now,
                }
                entry["usd"] = round(entry.get("usd", 0.0) + cost, 8)
                entry["last_seen"] = now
                # tail/provider may have been missing on an older record
                if key_tail and not entry.get("tail"):
                    entry["tail"] = key_tail
                entry.setdefault("provider", provider)
                bk[key_fp] = entry
            state["cache_creation_tokens"] = state.get("cache_creation_tokens", 0) + cache_creation
            state["cache_read_tokens"] = state.get("cache_read_tokens", 0) + cache_read
            state["last_updated"] = datetime.now(timezone.utc).isoformat()
            _write_state(state)
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)
    return cost


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


# ---------------------------------------------------------------------------
# v2 helpers: registry-driven multi-account snapshot merging.
#
# These helpers are intentionally narrow. Callers (registry/reconciler.py)
# build a per-account AccountSnapshot dict, hand it here, and we mutate the
# `accounts.<id>` and `totals` slices under the same fcntl lock the v1
# writers use. v1 fields (total_usd, by_provider, drift, vendor_truth, etc.)
# are NEVER touched by these helpers — the two writers share the file but
# never the keys.
# ---------------------------------------------------------------------------

def _recompute_totals(accounts: dict) -> dict:
    """Sum each account's yesterday.usd into a top-level totals card."""
    yesterday_usd = 0.0
    # Sum a 7-element trend by aligning the per-account trends element-wise.
    # If any account has fewer than 7 entries, pad with zeros.
    summed_trend = [0.0] * 7
    for acct in accounts.values():
        y = (acct.get("yesterday") or {}).get("usd", 0.0) or 0.0
        try:
            yesterday_usd += float(y)
        except (TypeError, ValueError):
            pass
        trend = acct.get("trend_7d_usd") or []
        for i in range(7):
            if i < len(trend):
                try:
                    summed_trend[i] += float(trend[i])
                except (TypeError, ValueError):
                    pass
    return {
        "yesterday_usd": round(yesterday_usd, 4),
        "trend_7d_usd": [round(v, 4) for v in summed_trend],
    }


def merge_account_snapshot(account_id: str, snapshot: dict) -> None:
    """Merge one account's reconciled snapshot into state.json under the
    fcntl lock. Recomputes top-level totals.

    `snapshot` shape: {label, provider, yesterday: {date, usd, by_workspace,
    by_key}, trend_7d_usd}. Caller is responsible for filling all fields.
    """
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    lock_path = STATE_DIR / ".state.lock"
    with open(lock_path, "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            state = load_state()
            accounts = state.setdefault("accounts", {})
            accounts[account_id] = snapshot
            state["totals"] = _recompute_totals(accounts)
            state["last_reconciled"] = datetime.now(timezone.utc).isoformat()
            state["schema_version"] = 2
            # A successful merge clears any prior error for this account_id.
            state["errors"] = [
                e for e in (state.get("errors") or [])
                if e.get("account_id") != account_id
            ]
            _write_state(state)
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


def record_account_error(account_id: str, kind: str, msg: str) -> None:
    """Append (or replace) a per-account error entry. Latest error per
    (account_id, kind) wins so the errors[] doesn't grow unbounded.
    """
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    lock_path = STATE_DIR / ".state.lock"
    with open(lock_path, "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            state = load_state()
            errors = [
                e for e in (state.get("errors") or [])
                if not (e.get("account_id") == account_id and e.get("kind") == kind)
            ]
            errors.append({
                "account_id": account_id,
                "kind": kind,
                "msg": msg[:400],
                "at": datetime.now(timezone.utc).isoformat(),
            })
            state["errors"] = errors
            state["schema_version"] = 2
            _write_state(state)
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


def get_alerts_fired() -> dict:
    """Read alerts_fired without taking the write lock. Snapshot is fine
    because the only writer is mark_alert_fired, called sequentially from
    the reconciler tick."""
    state = load_state()
    return dict(state.get("alerts_fired") or {})


def mark_alert_fired(key: str) -> None:
    """Stamp `state.alerts_fired[key] = now`. Used by the budget alert
    notifier to avoid double-firing the same alert in one UTC day/month."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    lock_path = STATE_DIR / ".state.lock"
    with open(lock_path, "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            state = load_state()
            af = dict(state.get("alerts_fired") or {})
            af[key] = datetime.now(timezone.utc).isoformat()
            state["alerts_fired"] = af
            state["schema_version"] = 2
            _write_state(state)
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


def prune_accounts(keep_ids: set[str]) -> None:
    """Drop any account from state.json whose id isn't in `keep_ids`. Also
    sweeps stale errors[] rows for the same ids. Called by the reconciler
    each tick so that disable/remove takes effect immediately, and totals
    excludes the removed account's spend (DESIGN: 'excluded from totals
    + hidden')."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    lock_path = STATE_DIR / ".state.lock"
    with open(lock_path, "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            state = load_state()
            accounts = state.get("accounts") or {}
            stale_ids = [aid for aid in accounts if aid not in keep_ids]
            if not stale_ids:
                return
            for aid in stale_ids:
                accounts.pop(aid, None)
            state["accounts"] = accounts
            state["totals"] = _recompute_totals(accounts)
            state["errors"] = [
                e for e in (state.get("errors") or [])
                if e.get("account_id") not in stale_ids
            ]
            state["schema_version"] = 2
            _write_state(state)
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


def record_today_estimate(usd: float, burn_rate_cents_per_min: float | None = None) -> None:
    """Proxy-side today-estimate hook. Only stamps the `today_estimate`
    field; never touches v1 fields. Cheap to call from each proxy request.

    Called by the proxy after each successful record_usage. Reads the v1
    total_usd as authoritative source-of-truth for the laptop-local guess.
    If ``burn_rate_cents_per_min`` is supplied, the cyan ¢/min card on
    the Overview tier becomes live; ``None`` leaves the prior rate field
    untouched (don't clobber a real rate with a no-rate write).
    """
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    lock_path = STATE_DIR / ".state.lock"
    with open(lock_path, "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            state = load_state()
            te = dict(state.get("today_estimate") or {})
            te["usd"] = round(float(usd), 6)
            te["last_updated"] = datetime.now(timezone.utc).isoformat()
            if burn_rate_cents_per_min is not None:
                te["burn_rate_cents_per_min"] = round(float(burn_rate_cents_per_min), 4)
            state["today_estimate"] = te
            state["schema_version"] = 2
            _write_state(state)
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)
