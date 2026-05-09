# Vendor-truth reconciliation (admin keys)

The proxy at `localhost:7778` gives sub-second feedback when you make an API
call. It can also silently miss traffic — env vars not exported in some tool,
an SDK that doesn't honor `*_BASE_URL`, a future provider that reorders its
response shape. Silent under-counting was the original bug that motivated
this whole tool.

The reconciler is the second layer that catches that. Every 5 minutes it
asks each vendor's official admin API how much that vendor will actually
charge you today, compares it against what the proxy recorded, and trips a
**DRIFT** flag in the menu bar when they disagree. You see the discrepancy
*before* the bill arrives.

## Coverage matrix

What the reconciler can and can't do, per vendor:

| Provider     | Real-time? | Polled? | Vendor lag    | Auth needed                      |
|--------------|------------|---------|---------------|----------------------------------|
| Anthropic    | proxy      | yes     | ~1 hr         | admin key (`sk-ant-admin-…`)     |
| OpenAI       | proxy      | yes     | ~1 hr         | admin key (org-level)            |
| Google       | proxy      | **no**  | ~24 hr        | (BigQuery export — out of scope) |
| HuggingFace  | proxy      | **no**  | —             | no public per-key API            |
| Mistral      | proxy      | **no**  | —             | no public per-key API            |
| Cohere       | proxy      | **no**  | —             | no public per-key API            |

Honest summary: **the reconciler closes the silent-undercount hole for
Anthropic and OpenAI only.** For everything else the proxy is the only
signal — DRIFT cannot fire and you must accept best-effort numbers there.

## Setup

The admin keys live in a separate file from the regular API keys. They are
read-only credentials for *usage data*, scoped at the **organization** level
— you can only create them for orgs you administer.

```bash
# create the file mode 0600, owner-only
touch ~/.ai-spending/admin_keys.json
chmod 600 ~/.ai-spending/admin_keys.json
```

Edit it to match this shape (omit any provider you don't have an admin key
for — that provider falls back to proxy-only):

```json
{
  "anthropic": "sk-ant-admin-...",
  "openai":    "sk-admin-..."
}
```

How to obtain each key:

- **Anthropic:** console.anthropic.com → Settings → Admin Keys → "Create
  Admin Key". Org admin role required. The key has read access to usage and
  cost report endpoints, no spend ability of its own.
- **OpenAI:** platform.openai.com → Organization → Settings → Admin Keys →
  "Create new admin key". Pick the "read usage" scope.

After you save the file, restart the proxy daemon — the reconciler picks up
keys at startup:

```bash
launchctl kickstart -k "gui/$(id -u)/com.ai-tracker.proxy"
```

Within ~5 minutes, `~/.ai-spending/state.json` should grow a `vendor_truth`
block per provider you configured, and a `drift` block tracking the
proxy-vs-vendor delta.

## Drift state machine

Per provider, with hysteresis so the UI doesn't flap:

```
                +-------+   3 ticks > 10% delta   +---------+
   start  --->  |  OK   | ----------------------> |  DRIFT  |
                +-------+ <---------------------- +---------+
                          3 ticks <= 10% delta
```

- **Tick:** every 5 minutes (one reconcile pass).
- **Threshold:** `|proxy − vendor| / max(vendor, $0.05) > 10%`.
- **Floor:** when both numbers are under `$0.05`, ratio is treated as 0
  (vendor rounding noise).
- **Trip:** 3 consecutive over-threshold ticks → DRIFT.
- **Recover:** 3 consecutive within-threshold ticks → OK.

So the UI takes ~15 minutes to enter or leave DRIFT. That tradeoff prevents
the indicator from flapping when vendor accounting briefly lags but still
catches a real undercount within reasonable time.

## What the menu bar shows

| state    | meaning                                                |
|----------|--------------------------------------------------------|
| LIVE     | proxy capturing, fresh data, no provider in DRIFT      |
| STALE    | proxy up but no record in 30 min, or stale state file  |
| DRIFT    | at least one provider's vendor total ≠ proxy total     |
| OFFLINE  | proxy daemon is not running                            |

DRIFT outranks STALE — if vendor truth disagrees with the proxy, that
matters more than the staleness of the file.

## What still bypasses everything

Even with both layers running, these will not be counted:

- Subscription usage (Claude Pro, ChatGPT Plus, etc.) — by design.
- HuggingFace, Mistral, Cohere not honored by env-var → no DRIFT detection
  for them; trust their own dashboards.
- Any tool that opens a fresh shell without `~/.zshrc` (`cron`, some IDE
  plugins, `env -i`-launched scripts).

If you find a tool that *should* be tracked but isn't, the symptoms differ
from a silent gap: DRIFT will trip on the affected provider within ~15
minutes. That's the whole point.
