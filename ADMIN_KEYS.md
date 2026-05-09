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

What the reconciler can and can't do, per vendor (verified against the live
endpoints, not just docs):

| Provider     | Real-time? | Polled? | Vendor lag    | Auth needed                      |
|--------------|------------|---------|---------------|----------------------------------|
| Anthropic    | proxy      | yes     | **~1 day**    | admin key (`sk-ant-admin-…`)     |
| OpenAI       | proxy      | yes     | **~1 day**    | admin key (org-level)            |
| Google       | proxy      | **no**  | ~24 hr        | (BigQuery export — out of scope) |
| HuggingFace  | proxy      | **no**  | —             | no public per-key API            |
| Mistral      | proxy      | **no**  | —             | no public per-key API            |
| Cohere       | proxy      | **no**  | —             | no public per-key API            |

**Important correction from the first cut of this doc:** the lag is *one
full day*, not ~1 hour. Anthropic's `cost_report` endpoint refuses date
ranges that extend into "today" (the bucket containing the current moment)
with a misleading "ending date must be after starting date" error. So we
poll *yesterday's* completed bucket. OpenAI's `organization/costs`
endpoint behaves similarly.

What this means for DRIFT detection:

- **Today's spend:** only the proxy sees it. If the proxy misses traffic
  *today*, you won't know until the next day's reconcile pass.
- **Yesterday's spend:** the reconciler compares yesterday's vendor total
  vs. yesterday's proxy snapshot (saved at midnight rollover). DRIFT fires
  if they disagree.
- **Net:** silent undercounts are caught within ~24 hours, not within
  minutes. Better than nothing, worse than I claimed initially.

The proxy is still your real-time signal. The reconciler is a *next-day*
audit that catches failures of the proxy.

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
- **What's compared:** yesterday's vendor total vs. yesterday's proxy
  snapshot (`state.yesterday_by_provider`). NOT today vs. today — the
  vendor's today bucket isn't fetchable.
- **Threshold:** `|proxy − vendor| / max(vendor, $0.05) > 10%`.
- **Floor:** when both numbers are under `$0.05`, ratio is treated as 0
  (vendor rounding noise).
- **Trip:** 3 consecutive over-threshold ticks → DRIFT.
- **Recover:** 3 consecutive within-threshold ticks → OK.

Note: within a single day, yesterday's snapshot doesn't change, so 3
ticks really means 3 confirmations of the same number. Hysteresis is
mostly defensive against transient API errors / partial vendor
accounting on the boundary just after midnight UTC.

When you first install the reconciler, there is no yesterday snapshot
(proxy hasn't run for a full day yet). The reconciler still records
`vendor_truth` but skips DRIFT computation until the first daily
rollover. You'll see drift come online ~24 hours after install.

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
