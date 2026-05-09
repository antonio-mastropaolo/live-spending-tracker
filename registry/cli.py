"""Tiny CLI for managing ~/.ai-spending/registry.json.

Usage:
    python3 -m registry add        # interactive prompt
    python3 -m registry list       # one line per entry, redacted key
    python3 -m registry remove ID  # remove by id
    python3 -m registry validate   # parse + lint, print errors

Admin keys are read with ``getpass`` so they don't appear in shell history.
The CLI validates the key prefix before writing — DESIGN.md §4c notes that
``sk-proj-…`` and ``sk-svcacct-…`` keys silently fail with a 401, and the
operator's first build-then-debug round wastes time.
"""

from __future__ import annotations

import argparse
import getpass
import sys

from registry.loader import (
    Budgets,
    REGISTRY_FILE,
    RegistryEntry,
    SUPPORTED_PROVIDERS,
    load,
    load_global_budgets,
    mute_key,
    save,
    save_global_budgets,
    set_budget,
    set_enabled,
    unmute_key,
)


def _prompt(label: str, *, default: str | None = None) -> str:
    suffix = f" [{default}]" if default else ""
    val = input(f"{label}{suffix}: ").strip()
    return val or (default or "")


def _validate_admin_key(provider: str, key: str) -> tuple[bool, str]:
    """Return (ok, reason). DESIGN.md §4c — the bad-prefix class of bug.

    Anthropic admin keys ship as `sk-ant-admin01-…` / `sk-ant-admin02-…`
    in practice (the digits encode the key format version). Older docs
    referenced `sk-ant-admin-…` — both shapes are valid; the invariant
    is that the prefix contains the literal token `sk-ant-admin`. The
    earlier exact-match check was the source of legitimate keys being
    rejected at install time.
    """
    if provider == "anthropic":
        if not key.startswith("sk-ant-admin"):
            return False, ("anthropic admin keys start with 'sk-ant-admin' "
                           "(e.g. 'sk-ant-admin01-…'). Regular sk-ant-… keys "
                           "cannot read /v1/organizations/cost_report.")
    elif provider == "openai":
        if key.startswith("sk-proj-") or key.startswith("sk-svcacct-"):
            return False, ("OpenAI project/service-account keys are rejected by "
                           "/v1/organization/costs with a 401. Need an admin key "
                           "(starts with 'sk-admin-').")
        if not key.startswith("sk-admin-"):
            return False, "OpenAI admin keys start with 'sk-admin-'."
    return True, ""


def _redact(key: str) -> str:
    if len(key) < 10:
        return "***"
    return f"{key[:8]}…{key[-4:]}"


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

def cmd_add(_args: argparse.Namespace) -> int:
    entries = load()
    print(f"Adding a new account to {REGISTRY_FILE}")
    entry_id = _prompt("id (stable, e.g. ant-personal)")
    if not entry_id:
        print("error: id is required", file=sys.stderr)
        return 1
    if any(e.id == entry_id for e in entries):
        print(f"error: id {entry_id!r} already exists", file=sys.stderr)
        return 1
    label = _prompt("label (display only)", default=entry_id)
    provider = _prompt("provider", default="anthropic").lower()
    if provider not in SUPPORTED_PROVIDERS:
        print(f"error: provider must be one of {sorted(SUPPORTED_PROVIDERS)}",
              file=sys.stderr)
        return 1
    admin_key = getpass.getpass("admin key (input hidden): ").strip()
    if not admin_key:
        print("error: admin key is required", file=sys.stderr)
        return 1
    ok, reason = _validate_admin_key(provider, admin_key)
    if not ok:
        print(f"error: {reason}", file=sys.stderr)
        return 1

    entries.append(RegistryEntry(
        id=entry_id,
        label=label,
        provider=provider,
        admin_key=admin_key,
        groupings=(),  # default groupings supplied by loader
    ))
    save(entries)
    print(f"saved. registry now has {len(entries)} account(s).")
    print("(restart the proxy daemon to pick this up immediately, "
          "or wait up to 5 minutes for the next poll cycle.)")
    return 0


def _fmt_budgets(b: Budgets) -> str:
    if not b.is_set():
        return ""
    parts = []
    if b.daily_usd is not None:
        parts.append(f"d=${b.daily_usd:g}")
    if b.monthly_usd is not None:
        parts.append(f"m=${b.monthly_usd:g}")
    return " · " + ",".join(parts)


def cmd_list(_args: argparse.Namespace) -> int:
    entries = load()
    if not entries:
        print("(registry is empty — `python3 -m registry add` to add one)")
        gb = load_global_budgets()
        if gb.is_set():
            print(f"global budgets: {_fmt_budgets(gb).lstrip(' · ')}")
        return 0
    width = max(len(e.id) for e in entries)
    for e in entries:
        status = "ON " if e.enabled else "OFF"
        budget_str = _fmt_budgets(e.budgets)
        print(f"[{status}] {e.id:<{width}}  {e.provider:<10}  {_redact(e.admin_key):<16}  {e.label}{budget_str}")
    gb = load_global_budgets()
    if gb.is_set():
        print(f"global: {_fmt_budgets(gb).lstrip(' · ')}")
    return 0


def cmd_disable(args: argparse.Namespace) -> int:
    if not set_enabled(args.id, False):
        print(f"no entry with id {args.id!r}", file=sys.stderr)
        return 1
    print(f"disabled {args.id!r}. admin key kept on disk; reconciler will skip it.")
    return 0


def cmd_enable(args: argparse.Namespace) -> int:
    if not set_enabled(args.id, True):
        print(f"no entry with id {args.id!r}", file=sys.stderr)
        return 1
    print(f"enabled {args.id!r}. next reconcile pass picks it up.")
    return 0


def cmd_remove(args: argparse.Namespace) -> int:
    entries = load()
    new = [e for e in entries if e.id != args.id]
    if len(new) == len(entries):
        print(f"no entry with id {args.id!r}", file=sys.stderr)
        return 1
    save(new)
    print(f"removed {args.id!r}; {len(new)} account(s) remaining.")
    return 0


def cmd_budget(args: argparse.Namespace) -> int:
    """`python3 -m registry budget {set,clear,global}` dispatcher.

    set:    --daily / --monthly to attach caps to one account
    clear:  drop all caps from one account
    global: set the cross-account caps in budgets.json
    """
    if args.budget_cmd == "set":
        # At least one of --daily / --monthly required.
        if args.daily is None and args.monthly is None:
            print("error: pass at least one of --daily or --monthly", file=sys.stderr)
            return 1
        new_b = Budgets(daily_usd=args.daily, monthly_usd=args.monthly)
        if not set_budget(args.id, new_b):
            print(f"no entry with id {args.id!r}", file=sys.stderr)
            return 1
        print(f"set budgets on {args.id!r}: {_fmt_budgets(new_b).lstrip(' · ')}")
        return 0

    if args.budget_cmd == "clear":
        if not set_budget(args.id, Budgets()):
            print(f"no entry with id {args.id!r}", file=sys.stderr)
            return 1
        print(f"cleared budgets on {args.id!r}")
        return 0

    if args.budget_cmd == "global":
        if args.daily is None and args.monthly is None and not args.clear:
            print("error: pass --daily / --monthly, or --clear", file=sys.stderr)
            return 1
        new_b = Budgets() if args.clear else Budgets(daily_usd=args.daily, monthly_usd=args.monthly)
        save_global_budgets(new_b)
        print(f"global budgets: {_fmt_budgets(new_b).lstrip(' · ') or '(none)'}")
        return 0

    print(f"unknown budget subcommand {args.budget_cmd!r}", file=sys.stderr)
    return 1


def cmd_mute(args: argparse.Namespace) -> int:
    """`python3 -m registry mute <account_id> <api_key_id>` — hide a key
    from the breakdown and exclude its spend from displayed totals.
    Polling continues; the underlying vendor data is untouched.
    """
    if not mute_key(args.id, args.api_key_id):
        print(f"no entry with id {args.id!r}", file=sys.stderr)
        return 1
    print(f"muted key {args.api_key_id!r} on account {args.id!r}.")
    return 0


def cmd_unmute(args: argparse.Namespace) -> int:
    if not unmute_key(args.id, args.api_key_id):
        print(f"no entry with id {args.id!r}", file=sys.stderr)
        return 1
    print(f"unmuted key {args.api_key_id!r} on account {args.id!r}.")
    return 0


def cmd_validate(_args: argparse.Namespace) -> int:
    entries = load()
    print(f"{REGISTRY_FILE}: {len(entries)} valid entry/entries.")
    for e in entries:
        ok, reason = _validate_admin_key(e.provider, e.admin_key)
        flag = "ok" if ok else "WARN"
        print(f"  [{flag}] {e.id} ({e.provider}): {reason or 'looks fine'}")
    return 0


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python3 -m registry")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("add", help="interactively add an account")
    sub.add_parser("list", help="list registered accounts (admin keys redacted)")
    p_remove = sub.add_parser("remove", help="remove an account by id")
    p_remove.add_argument("id")
    p_disable = sub.add_parser("disable", help="stop polling without deleting (keeps admin key)")
    p_disable.add_argument("id")
    p_enable = sub.add_parser("enable", help="resume polling for a disabled account")
    p_enable.add_argument("id")
    p_mute = sub.add_parser("mute", help="hide a single api_key_id from the breakdown + totals")
    p_mute.add_argument("id")
    p_mute.add_argument("api_key_id")
    p_unmute = sub.add_parser("unmute", help="restore a previously muted api_key_id")
    p_unmute.add_argument("id")
    p_unmute.add_argument("api_key_id")
    sub.add_parser("validate", help="lint the registry; warn on bad key prefixes")

    p_budget = sub.add_parser("budget", help="set, clear, or configure global spend caps")
    bsub = p_budget.add_subparsers(dest="budget_cmd", required=True)
    p_set = bsub.add_parser("set", help="attach budgets to one account")
    p_set.add_argument("id")
    p_set.add_argument("--daily",   type=float, default=None, dest="daily",
                       help="daily cap in USD")
    p_set.add_argument("--monthly", type=float, default=None, dest="monthly",
                       help="monthly cap in USD")
    p_clear = bsub.add_parser("clear", help="drop all caps from one account")
    p_clear.add_argument("id")
    p_global = bsub.add_parser("global", help="set or clear cross-account caps")
    p_global.add_argument("--daily",   type=float, default=None, dest="daily")
    p_global.add_argument("--monthly", type=float, default=None, dest="monthly")
    p_global.add_argument("--clear",   action="store_true",
                          help="remove all global caps")

    args = parser.parse_args(argv)
    return {
        "add":      cmd_add,
        "list":     cmd_list,
        "remove":   cmd_remove,
        "disable":  cmd_disable,
        "enable":   cmd_enable,
        "mute":     cmd_mute,
        "unmute":   cmd_unmute,
        "validate": cmd_validate,
        "budget":   cmd_budget,
    }[args.cmd](args)


if __name__ == "__main__":  # pragma: no cover — covered via __main__.py
    raise SystemExit(main())
