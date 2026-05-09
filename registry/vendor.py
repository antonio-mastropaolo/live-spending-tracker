"""Per-provider vendor pollers for the v2 registry-driven reconciler.

Each provider exposes a single coroutine, ``fetch_account``, that takes a
``RegistryEntry`` and returns a normalized ``AccountSnapshot`` dict ready
for ``state.manager.merge_account_snapshot``.

The HTTP scaffolding (yesterday-UTC window discipline, 7-day backfill,
per-bucket sum, currency filter) is shared. Provider-specific code is the
endpoint URL, auth header, and the response-shape walker. Both Anthropic
and OpenAI use the same `data[].results[]` pattern but differ on field
names — see DESIGN.md §9 for the canonical request/response examples.

This module owns no state. The reconciler holds the loop and the lock.
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections import defaultdict
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from typing import Any, Optional

import aiohttp

from registry.loader import RegistryEntry

logger = logging.getLogger(__name__)

HTTP_TIMEOUT_SEC = 20


class VendorError(Exception):
    """Raised when the vendor returns a non-2xx, malformed JSON, or a
    response shape we can't parse. The reconciler converts this into an
    ``errors[]`` entry in state.json — never crashes the loop."""

    def __init__(self, kind: str, msg: str):
        super().__init__(f"{kind}: {msg}")
        self.kind = kind
        self.msg = msg


@dataclass
class AccountSnapshot:
    """Normalized one-account-one-day result. Caller-friendly: every field
    has a sensible empty default so callers can populate progressively."""
    label: str
    provider: str
    yesterday_date: str          # ISO date, the day this snapshot covers
    yesterday_usd: float = 0.0
    by_workspace: dict[str, dict[str, Any]] = None  # type: ignore[assignment]
    by_key: dict[str, dict[str, Any]] = None        # type: ignore[assignment]
    trend_7d_usd: list[float] = None                # type: ignore[assignment]

    def to_dict(self) -> dict:
        return {
            "label": self.label,
            "provider": self.provider,
            "yesterday": {
                "date": self.yesterday_date,
                "usd": round(self.yesterday_usd, 4),
                "by_workspace": self.by_workspace or {},
                "by_key": self.by_key or {},
            },
            "trend_7d_usd": [round(v, 4) for v in (self.trend_7d_usd or [])],
        }


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _yesterday_utc_window() -> tuple[str, str, str]:
    """Return (starting_at, ending_at, iso_date_of_yesterday) in RFC 3339.

    Both Anthropic and OpenAI reject any range whose ``ending_at`` extends
    past the start of today UTC (DESIGN.md §4a). Yesterday is the freshest
    completed bucket.
    """
    now = datetime.now(timezone.utc)
    today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    yest_start = today_start - timedelta(days=1)
    fmt = "%Y-%m-%dT%H:%M:%SZ"
    return yest_start.strftime(fmt), today_start.strftime(fmt), yest_start.date().isoformat()


def _last_7d_utc_window() -> tuple[str, str, list[str]]:
    """Return (starting_at, ending_at, [iso_date]*7) for the previous 7
    completed days, oldest-first. Used for the trend backfill on each tick.
    """
    now = datetime.now(timezone.utc)
    today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    week_start = today_start - timedelta(days=7)
    fmt = "%Y-%m-%dT%H:%M:%SZ"
    days = [(week_start + timedelta(days=i)).date().isoformat() for i in range(7)]
    return week_start.strftime(fmt), today_start.strftime(fmt), days


# ---------------------------------------------------------------------------
# Anthropic
# ---------------------------------------------------------------------------

ANTHROPIC_COST_URL = "https://api.anthropic.com/v1/organizations/cost_report"
ANTHROPIC_WORKSPACES_URL = "https://api.anthropic.com/v1/organizations/workspaces"


async def _anthropic_cost_report(
    session: aiohttp.ClientSession,
    admin_key: str,
    starting_at: str,
    ending_at: str,
    group_by: tuple[str, ...],
) -> dict:
    headers = {"x-api-key": admin_key, "anthropic-version": "2023-06-01"}
    params: list[tuple[str, str]] = [
        ("starting_at", starting_at),
        ("ending_at", ending_at),
    ]
    for axis in group_by:
        params.append(("group_by[]", axis))
    async with session.get(ANTHROPIC_COST_URL, headers=headers, params=params) as resp:
        body = await resp.text()
        if resp.status == 401 or resp.status == 403:
            raise VendorError("auth", f"HTTP {resp.status}: {body[:200]}")
        if resp.status != 200:
            raise VendorError("http", f"HTTP {resp.status}: {body[:200]}")
        try:
            return json.loads(body)
        except json.JSONDecodeError as exc:
            raise VendorError("parse", f"bad JSON: {exc}") from exc


async def _anthropic_workspace_labels(
    session: aiohttp.ClientSession, admin_key: str
) -> dict[str, str]:
    """Return {workspace_id: name}. Failures are non-fatal — labels are
    cosmetic; the reconciler still has the workspace_ids and totals."""
    headers = {"x-api-key": admin_key, "anthropic-version": "2023-06-01"}
    try:
        async with session.get(ANTHROPIC_WORKSPACES_URL, headers=headers) as resp:
            if resp.status != 200:
                return {}
            payload = await resp.json()
    except (aiohttp.ClientError, asyncio.TimeoutError, json.JSONDecodeError):
        return {}
    return {w["id"]: w.get("name", w["id"]) for w in payload.get("data", []) if "id" in w}


def _walk_anthropic_buckets(payload: dict) -> list[dict]:
    """Yield flat result rows: {date, workspace_id, api_key_id, usd, key_tail}."""
    rows: list[dict] = []
    for bucket in payload.get("data") or []:
        bucket_date = (bucket.get("starting_at") or "")[:10]
        for r in bucket.get("results") or []:
            if r.get("currency", "USD") != "USD":
                continue
            try:
                usd = float(r.get("amount", 0))
            except (TypeError, ValueError):
                continue
            rows.append({
                "date": bucket_date,
                "workspace_id": r.get("workspace_id"),
                "api_key_id": r.get("api_key_id"),
                # Anthropic returns "partial_key_hint" with the last 4 chars
                # of the key — convenient for our ‘…AbCd’ tail.
                "key_tail": (r.get("partial_key_hint") or "")[-4:],
                "usd": usd,
            })
    return rows


async def _fetch_anthropic(entry: RegistryEntry) -> AccountSnapshot:
    timeout = aiohttp.ClientTimeout(total=HTTP_TIMEOUT_SEC)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        # Fire the 7-day window and the workspace labels in parallel — both
        # are independent and safe to do concurrently.
        s7, e7, days = _last_7d_utc_window()
        report_task = asyncio.create_task(
            _anthropic_cost_report(session, entry.admin_key, s7, e7, entry.groupings)
        )
        labels_task = asyncio.create_task(
            _anthropic_workspace_labels(session, entry.admin_key)
        )
        payload = await report_task
        labels = await labels_task

    rows = _walk_anthropic_buckets(payload)

    yest_iso = days[-1]  # last entry is yesterday
    yesterday_rows = [r for r in rows if r["date"] == yest_iso]

    by_workspace: dict[str, dict[str, Any]] = defaultdict(lambda: {"label": "", "usd": 0.0})
    by_key: dict[str, dict[str, Any]] = defaultdict(
        lambda: {"label": "", "tail": "", "usd": 0.0}
    )
    yesterday_usd = 0.0
    for r in yesterday_rows:
        usd = r["usd"]
        yesterday_usd += usd
        ws = r.get("workspace_id")
        if ws:
            by_workspace[ws]["usd"] += usd
            by_workspace[ws]["label"] = labels.get(ws, ws)
        ak = r.get("api_key_id")
        if ak:
            by_key[ak]["usd"] += usd
            if not by_key[ak]["tail"] and r.get("key_tail"):
                by_key[ak]["tail"] = r["key_tail"]
            # Anthropic doesn't expose a key label in cost_report; leave blank.

    # Round nested usd values for stable JSON output.
    by_workspace = {k: {**v, "usd": round(v["usd"], 4)} for k, v in by_workspace.items()}
    by_key = {k: {**v, "usd": round(v["usd"], 4)} for k, v in by_key.items()}

    trend = [0.0] * 7
    for r in rows:
        if r["date"] in days:
            trend[days.index(r["date"])] += r["usd"]

    return AccountSnapshot(
        label=entry.label,
        provider=entry.provider,
        yesterday_date=yest_iso,
        yesterday_usd=yesterday_usd,
        by_workspace=by_workspace,
        by_key=by_key,
        trend_7d_usd=trend,
    )


# ---------------------------------------------------------------------------
# OpenAI
# ---------------------------------------------------------------------------

OPENAI_COST_URL = "https://api.openai.com/v1/organization/costs"
OPENAI_PROJECTS_URL = "https://api.openai.com/v1/organization/projects"


async def _openai_costs(
    session: aiohttp.ClientSession,
    admin_key: str,
    start_unix: int,
    end_unix: int,
    group_by: tuple[str, ...],
) -> dict:
    headers = {"Authorization": f"Bearer {admin_key}"}
    params: list[tuple[str, str]] = [
        ("start_time", str(start_unix)),
        ("end_time", str(end_unix)),
        ("bucket_width", "1d"),
        ("limit", "31"),
    ]
    for axis in group_by:
        params.append(("group_by[]", axis))
    async with session.get(OPENAI_COST_URL, headers=headers, params=params) as resp:
        body = await resp.text()
        if resp.status == 401 or resp.status == 403:
            raise VendorError("auth", f"HTTP {resp.status}: {body[:200]}")
        if resp.status != 200:
            raise VendorError("http", f"HTTP {resp.status}: {body[:200]}")
        try:
            return json.loads(body)
        except json.JSONDecodeError as exc:
            raise VendorError("parse", f"bad JSON: {exc}") from exc


async def _openai_project_labels(
    session: aiohttp.ClientSession, admin_key: str
) -> dict[str, str]:
    headers = {"Authorization": f"Bearer {admin_key}"}
    try:
        async with session.get(OPENAI_PROJECTS_URL, headers=headers) as resp:
            if resp.status != 200:
                return {}
            payload = await resp.json()
    except (aiohttp.ClientError, asyncio.TimeoutError, json.JSONDecodeError):
        return {}
    return {p["id"]: p.get("name", p["id"]) for p in payload.get("data", []) if "id" in p}


def _walk_openai_buckets(payload: dict) -> list[dict]:
    """Yield flat rows: {date, project_id, api_key_id, usd}.

    OpenAI's per-bucket schema:
        {"start_time": <unix>, "end_time": <unix>, "results":
            [{"amount": {"value": 1.23, "currency": "usd"},
              "project_id": "proj_…", "api_key_id": "key_…"}, …]}
    """
    rows: list[dict] = []
    for bucket in payload.get("data") or []:
        start = bucket.get("start_time")
        if not isinstance(start, (int, float)):
            continue
        bucket_date = datetime.fromtimestamp(int(start), tz=timezone.utc).date().isoformat()
        for r in bucket.get("results") or []:
            amt = r.get("amount") or {}
            if (amt.get("currency") or "usd").lower() != "usd":
                continue
            try:
                usd = float(amt.get("value", 0))
            except (TypeError, ValueError):
                continue
            rows.append({
                "date": bucket_date,
                "project_id": r.get("project_id"),
                "api_key_id": r.get("api_key_id"),
                "usd": usd,
            })
    return rows


async def _fetch_openai(entry: RegistryEntry) -> AccountSnapshot:
    now = datetime.now(timezone.utc)
    today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    week_start = today_start - timedelta(days=7)
    days = [(week_start + timedelta(days=i)).date().isoformat() for i in range(7)]
    yest_iso = days[-1]

    timeout = aiohttp.ClientTimeout(total=HTTP_TIMEOUT_SEC)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        report_task = asyncio.create_task(
            _openai_costs(
                session,
                entry.admin_key,
                int(week_start.timestamp()),
                int(today_start.timestamp()),
                entry.groupings,
            )
        )
        labels_task = asyncio.create_task(
            _openai_project_labels(session, entry.admin_key)
        )
        payload = await report_task
        labels = await labels_task

    rows = _walk_openai_buckets(payload)
    yesterday_rows = [r for r in rows if r["date"] == yest_iso]

    by_workspace: dict[str, dict[str, Any]] = defaultdict(lambda: {"label": "", "usd": 0.0})
    by_key: dict[str, dict[str, Any]] = defaultdict(
        lambda: {"label": "", "tail": "", "usd": 0.0}
    )
    yesterday_usd = 0.0
    for r in yesterday_rows:
        usd = r["usd"]
        yesterday_usd += usd
        # Reuse the same `by_workspace` slot for OpenAI projects so the UI
        # can render both providers with one code path. Conceptually:
        # Anthropic workspace ↔ OpenAI project — both are "containers
        # that hold api keys."
        proj = r.get("project_id")
        if proj:
            by_workspace[proj]["usd"] += usd
            by_workspace[proj]["label"] = labels.get(proj, proj)
        ak = r.get("api_key_id")
        if ak:
            by_key[ak]["usd"] += usd
            # OpenAI doesn't return a tail in costs response. Best effort:
            # last 4 chars of the api_key_id (which itself is opaque, e.g.
            # "key_AbCdEf…") is at least stable across rows.
            if not by_key[ak]["tail"]:
                by_key[ak]["tail"] = ak[-4:]

    by_workspace = {k: {**v, "usd": round(v["usd"], 4)} for k, v in by_workspace.items()}
    by_key = {k: {**v, "usd": round(v["usd"], 4)} for k, v in by_key.items()}

    trend = [0.0] * 7
    for r in rows:
        if r["date"] in days:
            trend[days.index(r["date"])] += r["usd"]

    return AccountSnapshot(
        label=entry.label,
        provider=entry.provider,
        yesterday_date=yest_iso,
        yesterday_usd=yesterday_usd,
        by_workspace=by_workspace,
        by_key=by_key,
        trend_7d_usd=trend,
    )


# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------

_FETCHERS = {
    "anthropic": _fetch_anthropic,
    "openai":    _fetch_openai,
}


async def fetch_account(entry: RegistryEntry) -> AccountSnapshot:
    """Look up the right per-provider fetcher and run it. Caller is
    responsible for wrapping in try/except (VendorError, asyncio errors,
    aiohttp errors) and routing to record_account_error."""
    try:
        fetcher = _FETCHERS[entry.provider]
    except KeyError:
        raise VendorError("provider", f"no fetcher for provider {entry.provider!r}")
    return await fetcher(entry)
