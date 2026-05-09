# Design: Multi-account live AI-spend tracker

> Status: design proposal · captures vision and gotchas; not yet implemented
> Authors: Antonio Mastropaolo, with Claude
> Last updated: 2026-05-09

## 1. Why this doc exists

The current implementation grew out of a single bug ("the menu bar said
$0.08 but Anthropic billed me $50") and evolved through several rounds of
"build, find the gap, refactor." That worked, but the next round —
multi-account, cross-machine, deployed-service coverage — is big enough
that designing first is cheaper than another build-first cycle.

This doc captures:

- What's actually shipped (so a fresh reader knows the baseline).
- What we've learned the hard way (so we don't re-discover gotchas).
- The proposed architecture and where it differs from today.
- Trade-offs the operator must own consciously, not by surprise.

The goal is that whoever builds this next — me, Antonio, or someone else
— starts from a clear north star, not from `git log`.

## 2. Problem statement

A solo developer wants a single, reliable counter showing how much money
their AI usage has burned, **broken down by account, project, and API
key**, across **all** machines that use those keys (laptops, deployed
services, cron jobs, mobile clients). Visible in the macOS menu bar.
Daily reset.

Goals, in priority order:

1. **Coverage across machines.** Spend on a deployed service must show up,
   not just spend on the developer's laptop.
2. **Per-account separation.** Multiple Anthropic / OpenAI orgs (personal,
   work, client) must each have their own line item.
3. **Per-key attribution.** Within an account, individual API keys must be
   distinguishable (so the developer can see "this key is being used by
   that prod service").
4. **Reliability over freshness.** A 24-hour-old number that's correct is
   worth more than a real-time number that silently undercounts.
5. **Privacy.** Admin keys are read-only credentials and must be stored
   mode 0600; raw keys never leave the machine.

Out of scope (by vendor or by design):

- Subscription usage (Claude Pro / Max / ChatGPT Plus). These don't go
  through the API and aren't reported in any cost-report endpoint.
- HuggingFace, Mistral, Cohere per-key spend. No public per-key usage
  endpoint exists; the proxy is the only signal there and it stays best-effort.
- Real-time tracking outside this laptop. Vendors don't expose intra-day
  data, so cross-machine = next-day at best.

## 3. What's shipped today (baseline)

```
                  ┌────────────────────────────────────┐
   API SDK  ──→   │ proxy: localhost:7778              │   ←  request
                  │   parse usage from response body   │
                  │   write ~/.ai-spending/state.json  │
                  └────────────────────────────────────┘
                                   ↑
                                   │ polled every 10 s
                  ┌────────────────────────────────────┐
   menu bar  ←──  │ SwiftUI native app                  │
                  │   reads state.json                  │
                  │   shows total / providers / keys    │
                  │   STALE / DRIFT badges              │
                  └────────────────────────────────────┘
                                   ↑
                                   │ tick every 5 min
                  ┌────────────────────────────────────┐
                  │ reconciler: state/reconciler.py     │
                  │   admin keys → vendor cost_report   │
                  │   yesterday-vs-yesterday DRIFT      │
                  └────────────────────────────────────┘
```

Roles, today:

- **Proxy** — real-time, this laptop only, today's spend.
- **Reconciler** — next-day audit on Anthropic + OpenAI admin keys,
  fires DRIFT when the proxy missed traffic (any device, any tool).

Limitations we already know about:

- Single account per provider. Adding a second Anthropic org or a second
  OpenAI org has no place in the data model.
- Per-key attribution exists for proxy-seen traffic only; vendor-reported
  keys aren't surfaced.
- Multi-machine traffic is invisible until the next day, and even then
  shows up only as an aggregate DRIFT — you can't see "this key on prod
  burned $X."

## 4. Things we discovered the hard way (do not relearn)

### 4a. Anthropic `cost_report` lag is ~1 day, not ~1 hour

The endpoint refuses any range that extends into the current day with a
misleading error: `"ending date must be after starting date"`. The actual
invariant is that `ending_at` must be at most the start of today (UTC).
So the reconciler must poll *yesterday's* completed bucket. Lag is one
full day, not one hour. The ADMIN_KEYS.md note that originally claimed
"~1 hr behind" was wrong.

### 4b. Comparing apples to apples requires snapshotting

Polling yesterday's vendor total against today's proxy total is
misleading (today's proxy is partial, yesterday's vendor is complete).
Solution: at the daily-rollover write, copy yesterday's `by_provider`
into `yesterday_by_provider` so DRIFT can compare yesterday-vendor vs
yesterday-proxy. The reconciler must skip DRIFT entirely on first install
because no snapshot exists yet.

### 4c. OpenAI admin keys need an organization

Personal OpenAI accounts have no admin-keys page. Operators must create
or join an org (free, but a real setup step). Admin keys start with
`sk-admin-`; project keys (`sk-proj-…`) and service-account keys
(`sk-svcacct-…`) are rejected by `/v1/organization/costs` with a 401.
Surface this clearly in the registry UI so users don't mistype the type.

### 4d. Anthropic admin → fingerprint mapping is one-way

Anthropic returns its own `api_key_id` (opaque, e.g. `apikey_01ABC...`)
in cost_report. The proxy computes a salted SHA-256 fingerprint from the
raw key. **These don't share an identifier space.** To merge them:

- Either trust Anthropic's `api_key_id` as canonical and keep both that
  *and* a fingerprint side-by-side (proxy must learn the api_key_id —
  could be done via a one-shot lookup the first time a key is seen).
- Or display the two views side-by-side without trying to merge: vendor
  shows api_key_id + tail (Anthropic returns a partial), proxy shows
  fingerprint + tail. Operator does the merge by eye.

Plan: pick one (probably the first), document the choice, don't assume
the merge is automatic.

### 4e. Compression handling needs forced identity

Original proxy forwarded `Content-Encoding: gzip` from upstream alongside
already-decompressed bodies → ZlibError in clients. Fix that's now
landed: force `Accept-Encoding: identity` upstream and strip
`Content-Encoding`/`Content-Length` from forwarded responses. **Do not
remove this even if it looks unused** — without it, brotli/zstd from
modern endpoints will reintroduce the bug.

### 4f. Silent green is the worst failure mode

The original overlay showed "LIVE" for 49 hours of zero traffic. The
fix (STALE state when `last_updated` > 30 min OR `date != today`) is
non-negotiable for the next iteration too. **Default to red, prove green.**

## 5. Proposed architecture (vision)

Multi-account registry-driven polling. The reconciler stops being an
audit layer on top of the proxy and becomes the *primary* spend signal,
with the proxy demoted to optional "intra-day estimate for the current
laptop."

### 5a. Data model

Two files, both mode 0600.

**`~/.ai-spending/registry.json`** — what to monitor:

```json
[
  {
    "id":         "ant-personal",
    "label":      "Anthropic · Personal",
    "provider":   "anthropic",
    "admin_key":  "sk-ant-admin-...",
    "groupings":  ["workspace_id", "api_key_id"]
  },
  {
    "id":         "ant-acme",
    "label":      "Anthropic · Acme Inc",
    "provider":   "anthropic",
    "admin_key":  "sk-ant-admin-...",
    "groupings":  ["workspace_id", "api_key_id"]
  },
  {
    "id":         "oai-personal",
    "label":      "OpenAI · Personal",
    "provider":   "openai",
    "admin_key":  "sk-admin-...",
    "groupings":  ["project_id", "api_key_id"]
  }
]
```

`id` is operator-chosen, stable, and used as the storage key. `label` is
display-only and may change. `groupings` declares which axes of breakdown
the vendor should return.

**`~/.ai-spending/state.json`** — current state, regenerated by the
reconciler:

```json
{
  "schema_version": 2,
  "generated_at": "2026-05-09T12:00:00Z",
  "accounts": {
    "ant-personal": {
      "label":  "Anthropic · Personal",
      "provider": "anthropic",
      "yesterday": {
        "date":  "2026-05-08",
        "usd":   12.43,
        "by_workspace": {
          "wrkspc_xxx": { "label": "Coder Bot",   "usd": 8.10 },
          "wrkspc_yyy": { "label": "Side Project","usd": 4.33 }
        },
        "by_key": {
          "apikey_01XYZ": { "label": "prod", "tail": "AbCd", "usd": 11.20 },
          "apikey_02ABC": { "label": "dev",  "tail": "MnOp", "usd":  1.23 }
        }
      },
      "trend_7d_usd": [0.0, 2.4, 12.43, 0.0, 0.0, 0.0, 0.0]
    }
  },
  "totals": {
    "yesterday_usd": 42.18,
    "trend_7d_usd":  [...]
  },
  "last_reconciled": "2026-05-09T12:00:00Z",
  "errors": [
    {"account_id": "oai-personal", "kind": "auth", "msg": "401 invalid_api_key", "at": "..."}
  ]
}
```

Notes:

- No `today.usd` field. Vendors don't expose it. Don't pretend.
- `errors` is a first-class field, not a side log. The UI surfaces
  per-account errors so a single dead admin key doesn't poison the whole
  dashboard.
- `trend_7d_usd` is a small array kept for sparklines. Backfill on first
  poll (cost_report supports a 7-day range).

### 5b. Polling strategy

| Vendor | Endpoint | Required `group_by` | Cadence | Notes |
|--------|----------|---------------------|---------|-------|
| Anthropic | `/v1/organizations/cost_report` | `workspace_id`, `api_key_id` | 5 min | Yesterday window only. |
| OpenAI | `/v1/organization/costs` | `project_id`, `api_key_id` | 5 min | Yesterday window only. |
| Google | (skip) | — | — | Cloud Billing export to BigQuery; out of scope. |
| HF / Mistral / Cohere | (skip) | — | — | No public per-key endpoint. |

Cadence is per-account, not per-key. With N accounts polled every 5 min,
that's 12N requests/hour total — well under any documented org-level
rate limit even at N=10.

### 5c. UI hierarchy

Three tiers, all in the menu bar popover. Menu bar icon shows the total
across all accounts for yesterday.

```
OVERVIEW                  ACCOUNT DETAIL                KEY DETAIL
─────────────────         ─────────────────             ─────────────────
yesterday total           [Anthropic · Personal]        […AbCd · prod]
$42.18                    $12.43 yesterday              $11.20 yesterday
                          last reconciled 2 min ago
Anthropic · Personal      ─────────────────             7-day trend
  $12.43 ›                BY WORKSPACE                  ─────────────────
Anthropic · Acme          Coder Bot     $8.10           workspaces touched
  $25.05 ›                Side Project  $4.33           models breakdown
OpenAI · Personal         ─────────────────             first/last seen
  $4.70  ›                BY KEY                        deployed flag (heuristic)
                          …AbCd prod    $11.20 ›
                          …MnOp dev      $1.23 ›
```

Severity ladder (matches today): `OFFLINE > AUTH_ERROR > STALE > LIVE`.
A single account's auth error doesn't downgrade the whole UI to OFFLINE,
just shows an error pill on that account row.

### 5d. Optional: keep the proxy as "current day"

The proxy can stay as an opt-in "intra-day estimate" layer. It would
write to `state.today_estimate.usd` (separate from `accounts.*.yesterday`)
so it's never confused with vendor truth. UI shows it as
`Today (live, this laptop only): $X.XX` with a lighter weight, clearly
distinguished from the authoritative yesterday number.

If the proxy is dropped entirely, the architecture is simpler but the
"I just spent $0.04, the icon updated" feedback is gone.

## 6. Migration paths

Three options, ordered by risk:

1. **Additive build** — add registry and multi-account polling alongside
   the existing proxy + reconciler. Old behavior keeps working; new
   features come online when `registry.json` exists. Schema version
   bump from 1 → 2; old state.json is migrated on first boot. Lowest risk.

2. **Pivot to registry-only** — delete proxy + reconciler, replace with
   registry polling. Cleanest result; highest churn. Reasonable choice
   *after* registry has been used for a few weeks and the operator is
   confident the 1-day lag isn't painful.

3. **Two-mode** — registry-only by default, proxy off. `~/.ai-spending/
   proxy.enabled` opt-in flag. Operator who wants real-time enables it
   manually. Compromise.

Recommendation: **(1) for the first cut** — let the operator run both,
compare in practice, and decide which to keep based on real data.

## 7. Open questions (worth answering before building)

- **api_key_id ↔ fingerprint merge.** Build the lookup ("what's the
  api_key_id of the key with raw value X?") or display side-by-side
  unmerged? Lean: lookup, but only if the admin endpoints expose a
  list-keys-with-values capability — which Anthropic and OpenAI both
  *don't*, for obvious security reasons. Falling back to side-by-side.
- **Which admin scope?** Anthropic admin keys can be scoped (read-only
  vs. full). The reconciler should request the smallest scope that
  works (`usage:read` if available). Document this in setup.
- **Registry editing UX.** Vim-on-disk is fine for a developer tool.
  But adding a "+ Add account" sheet in the menu bar app is friendlier
  and would prevent the JSON-malformed-quote class of bug we hit.
  Worth it eventually; not v2 day-one.
- **Encrypted-at-rest registry.** Mode 0600 is enough for a personal
  laptop. If we ever consider a multi-user / shared-dotfile scenario,
  push registry into Keychain instead.
- **History beyond 7 days.** `trend_7d_usd` is sufficient for a tray
  app. If the operator wants a real history view (sparklines beyond a
  week), it's an `~/.ai-spending/history.sqlite` rollup, written every
  daily rollover.

## 8. Non-goals (worth saying out loud)

- Real-time tracking on machines that aren't this one. Out of reach
  given vendor API constraints. Don't promise it.
- Subscription tracking. Claude Pro/Max/Team and ChatGPT Plus don't
  appear in any reportable endpoint. Operator checks vendor invoice.
- A "panic / alert" feature ("notify me when daily spend > $X").
  Worth doing eventually as a follow-on, but tied to its own state
  machine and not to this design pass.
- Cross-vendor cost normalization. We report what each vendor reports;
  we don't fabricate a unified "1 token = $X" model.

## 9. Appendix: useful endpoints

```
# Anthropic (admin key only, sk-ant-admin-...)
GET  https://api.anthropic.com/v1/organizations/cost_report
       ?starting_at=2026-05-08T00:00:00Z
       &ending_at=2026-05-09T00:00:00Z
       &group_by[]=workspace_id
       &group_by[]=api_key_id
HEAD x-api-key, anthropic-version: 2023-06-01

GET  https://api.anthropic.com/v1/organizations/usage_report/messages
     (token-level breakdown per model — useful for trends, not strictly
      needed for cost_report consumers)

# OpenAI (admin key only, sk-admin-...)
GET  https://api.openai.com/v1/organization/costs
       ?start_time=<unix-ts-of-yesterday-00:00>
       &group_by[]=project_id
       &group_by[]=api_key_id
HEAD Authorization: Bearer <admin_key>
```

Both endpoints reject "today" buckets. Both return `data[].results[]`
with per-bucket totals. Both can fail with 401 if the key is the wrong
type (project key vs. admin key). Failures should land in
`state.json:errors[]`, not silently zero out an account.
