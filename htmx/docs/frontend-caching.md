# Frontend Caching & Performance

This document describes the caching architecture in the HTMX Risk Dashboard frontend, the
three configuration profiles, every tunable knob, and the operational playbook for switching
between modes or rolling back individual features.

---

## Architecture overview

```
HTMX_CACHE_MODE env var ──┐
                           ▼
Individual HTMX_* env   resolve_cache_config()   ← main.py (server startup)
var overrides ────────────►│
                           ▼
                     Resolved config dict
                           │
              ┌────────────┼──────────────┐
              ▼            ▼              ▼
        warmup knobs   nav tuning   feature flags
              │            │              │
              └────────────┼──────────────┘
                           ▼
              data-* attributes on <body>  ← base.html (Jinja2)
                           │
                           ▼
              readRuntimeInt / readRuntimeBool  ← charts.js (browser)
```

Configuration flows in one direction: an `HTMX_CACHE_MODE` environment variable selects a
baseline profile, individual `HTMX_*` variables override any key, the resolved dict is
injected into the Jinja2 template context, and `base.html` emits `data-*` attributes on
`<body>` that `charts.js` reads at runtime.

---

## Cache layers

The frontend maintains several in-memory caches, all implemented as JavaScript `Map` objects
with LRU eviction.

| Cache | Contents | Max entries | TTL | Scope |
|---|---|---|---|---|
| `softNavShellCache` | Full HTML shells for each page (used by soft navigation) | 5 (configurable) | 10 min (configurable) | session |
| `widgetResponseCache` | Parsed JSON payloads keyed by `widgetId::filterSignature` | 100 (configurable) | governed by max-age per kind | session |
| `detailTableCache` | HTML fragments for drill-down detail tables | 40 | 30 s | session |
| `pageActionCache` | HTML fragments for page-action modals | 40 | 60 s | session |
| `localStorage` persistence | Serialized snapshot of shells + top widget payloads | ~2 MB budget | inherits source TTLs | cross-reload |

The `localStorage` persistence layer is opt-in (`HTMX_PERSIST_CACHE_ENABLED`). When enabled,
a snapshot is written every 30 s and on `beforeunload`, and hydrated on `DOMContentLoaded`
before any HTMX triggers fire. This addresses the cold-load scenario that in-memory caches
cannot help with.

---

## Cache modes

`HTMX_CACHE_MODE` selects one of three profiles. The default is `balanced`.

### Conservative — freshness-first, no speculation

Shorter cache TTLs and faster refresh intervals mean the user always sees near-real-time data.
Warmup is disabled entirely. No prefetching, no speculative work. This is **not** a
low-bandwidth mode — it trades higher request frequency for guaranteed data freshness.

**When to use:** latency-insensitive environments where stale data is unacceptable (e.g.,
active incident monitoring).

### Balanced — today's exact behavior

Every value matches the pre-cache-mode defaults. All new feature flags are `false`. No new
event listeners, fetch calls, or timeouts are registered compared to the previous codebase.
This is the **strict no-op** baseline used for regression gating.

**When to use:** production default. Change nothing, risk nothing.

### Aggressive — speed-first, accept staleness

Longer TTLs, higher warmup budgets, and every prefetch/render optimization enabled. The user
experiences near-instant page navigation and uniform widget loading at the cost of displaying
data that may be seconds to minutes older than the server's latest.

**When to use:** demo environments, presentations, or any context where perceived speed
matters more than real-time accuracy.

---

## Profile comparison

Values that differ from balanced are highlighted.

| Knob | Conservative | Balanced | Aggressive |
|---|---|---|---|
| `warmup_enabled` | **false** | true | true |
| `warmup_budget_seconds` | 30 | 30 | **60** |
| `warmup_max_jobs` | 20 | 20 | **40** |
| `warmup_concurrency` | 3 | 3 | **5** |
| `warmup_widgets_per_page` | 8 | 8 | **14** |
| `critical_cache_max_age_ms` | **15 000** | 60 000 | **120 000** |
| `default_cache_max_age_ms` | **30 000** | 300 000 | **600 000** |
| `soft_nav_shell_refresh_delay_ms` | **500** | 3 000 | **5 000** |
| `soft_nav_shell_cache_ttl_ms` | **60 000** | 600 000 | **1 200 000** |
| `viewport_poll_stale_ms` | **15 000** | 45 000 | **90 000** |
| `refresh_kpi_seconds` | **15** | 0 (widget default) | **90** |
| `refresh_chart_seconds` | **30** | 60 | **120** |
| `refresh_table_seconds` | **45** | 90 | **120** |
| `widget_response_cache_max_entries` | **50** | 100 | **200** |
| `soft_nav_shell_cache_max_entries` | **3** | 5 | **8** |
| `perf_metrics_enabled` | false | false | **true** |
| `hover_prefetch_enabled` | false | false | **true** |
| `parallel_shell_prefetch` | false | false | **true** |
| `shell_prefetch_concurrency` | 1 | 1 | **3** |
| `rewarmup_on_filter_change` | false | false | **true** |
| `rewarmup_idle_delay_ms` | 0 | 0 | **3 000** |
| `batched_reveal_enabled` | false | false | **true** |
| `batched_reveal_timeout_ms` | 0 | 0 | **400** |
| `max_concurrent_widget_requests` | **3** | 0 (unlimited) | **5** |
| `offscreen_pause_enabled` | false | false | **true** |
| `skeleton_min_display_ms` | 0 | 0 | **150** |
| `adaptive_dialdown_enabled` | false | false | **true** |
| `adaptive_dialdown_hit_threshold` | 0 | 0 | **0.2** |
| `persist_cache_enabled` | false | false | false |

---

## Feature details

### Soft navigation & shell caching

When the user selects a new page from the **View** dropdown, the dashboard performs a
*soft navigation*: instead of a full page reload, it fetches the target page's HTML, extracts
the `<main>` content and topbar state, and swaps them into the current DOM. The full HTML
response (the "shell") is stored in `softNavShellCache`.

On subsequent navigations to the same page, the cached shell is applied instantly and a
background refresh is scheduled after `soft_nav_shell_refresh_delay_ms` to silently update
the cache for next time.

### Server-side warmup

After the first user interaction (and a 4 s delay), the client sends a `POST /api/v1/warmup`
with a manifest of widget targets across all non-current pages. The server precomputes
responses and stores them in its own cache. When the user later navigates to a warmed page,
widget requests hit server-side cache and return significantly faster.

After the warmup API call completes, the client also prefetches shell HTML for every other
page, populating `softNavShellCache` so that the first navigation feels instant.

Warmup respects `navigator.connection.saveData` and slow effective connection types.

### Viewport-aware polling

Widgets that are scrolled out of view have their periodic refresh polls suppressed after
they've been offscreen for `viewport_poll_stale_ms`. An `IntersectionObserver` tracks
visibility. Critical widgets (defined in `CRITICAL_WIDGET_IDS`) are exempt.

### Intent-based prefetch (aggressive only)

When `hover_prefetch_enabled` is true, focusing the page selector prefetches shell HTML for
the adjacent pages (next and previous in the list). On `change`, the selected page's shell is
also prefetched before the soft navigation begins. This gives the browser a head start on the
fetch.

Prefetch is skipped if `navigator.connection.saveData` is true or the shell is already cached.
The `addEventListener("focus", ...)` call is skipped entirely when the flag is false —
no listener overhead under balanced mode.

### Parallel shell prefetching (aggressive only)

When `parallel_shell_prefetch` is true, the warmup shell prefetch phase uses a
concurrency-limited `Promise` pool (controlled by `shell_prefetch_concurrency`) instead of
sequential `await`s. With 5+ pages this completes measurably faster.

### Re-warmup on filter change (aggressive only)

When `rewarmup_on_filter_change` is true, changing protocol, pair, asset, or time-window
filters schedules a debounced re-warmup cycle. The debounce delay is
`rewarmup_idle_delay_ms` (default 3 s in aggressive). If another filter change occurs within
the window, the timer resets. On expiry, the warmup session key is cleared and a fresh
warmup cycle runs for the new filter context.

### Adaptive prefetch dial-down (aggressive only)

When `adaptive_dialdown_enabled` is true, the system tracks how many prefetched shells are
actually used for navigation (`shellPrefetchUsed / shellPrefetchAttempted`). If the hit-rate
falls below `adaptive_dialdown_hit_threshold` (default 0.2) for two consecutive evaluation
windows, and at least 5 prefetches have been attempted, further warmup and shell prefetching
is suppressed for the rest of the session. A `adaptiveDialdownTriggered` perf metric is
recorded.

This prevents aggressive mode from wasting resources when the user isn't actually navigating
between pages.

### Tiered concurrency-limited loading (aggressive only)

When `max_concurrent_widget_requests` is greater than 0, `triggerDashboardRefresh` enforces
a global in-flight budget:

- **Tier 0** — critical widgets + visible KPIs: fire immediately using reserved slots (up to
  min(3, budget)).
- **Tier 1** — other visible widgets: fire when slots are available.
- **Tier 2** — offscreen / deferred widgets: queued behind Tiers 0 and 1.

When a request completes, the next queued widget is released. The tight budget (5 in
aggressive, not 10) is intentional: fewer concurrent requests reduce network contention,
tightening response arrival grouping and making batched reveal more effective.

When the budget is 0 (balanced), the original staggered-timeout behavior is used unchanged.

### Skeleton placeholders (aggressive only)

When `skeleton_min_display_ms` is greater than 0, `resetWidgetView` injects CSS shimmer
skeletons instead of text placeholders:

- **KPI widgets**: pulse bars matching value dimensions (40px primary, 16px secondary).
- **Chart widgets**: full-area shimmer block matching the chart canvas.
- **Table widgets**: 3–4 skeleton rows with pulse bars.

A minimum display window prevents "flash-of-skeleton" on very fast responses (e.g., cache
hits that return in 20 ms). If less than `skeleton_min_display_ms` has elapsed since the
skeleton was injected, the render is delayed by the remaining time.

Skeletons reuse the existing `@keyframes` animation pattern from the soft-nav pending state.
When the real payload renders, it overwrites the skeleton's `innerHTML` — no explicit
teardown needed.

### Batched above-fold reveal (aggressive only)

When `batched_reveal_enabled` is true, above-fold widgets (visible-critical + visible-other
at refresh time) are buffered as their responses arrive rather than rendered immediately.
Once all targets are buffered — or `batched_reveal_timeout_ms` expires — they are rendered
together in a single `requestAnimationFrame`.

This turns "widgets pop in one by one over 300–800 ms" into "they all appear at once."

If one widget is slow, the timeout cap ensures the rest render without waiting indefinitely.
Offscreen widgets and late stragglers render individually on arrival as before.

### Stronger offscreen pause (aggressive only)

When `offscreen_pause_enabled` is true, non-critical widgets that are offscreen have their
requests suppressed entirely — including the initial first-load trigger. The widget is marked
with `data-offscreen-deferred="1"`. When the `IntersectionObserver` detects it entering the
viewport, `requestWidgetNow` fires to load it on demand.

**Regression risk:** users who scroll quickly may briefly see blank widget sections before the
observer fires. This is why the feature is gated and placed in Phase 3 of the rollout.

### localStorage persistence (opt-in)

When `persist_cache_enabled` is true, a serialized snapshot of `softNavShellCache` and the
top 20 `widgetResponseCache` entries is written to `localStorage` every 30 s and on
`beforeunload`. On page load, entries that haven't exceeded their TTL are hydrated back into
the in-memory caches before HTMX triggers fire.

The snapshot is version-keyed by `currentPageSlug + cacheMode`. If the version doesn't match
(e.g., the user navigated to a different page or the mode changed), the persisted data is
discarded. A 2 MB size budget prevents unbounded growth.

---

## Configuration reference

All knobs are set via environment variables. `HTMX_CACHE_MODE` selects a profile baseline;
any other `HTMX_*` variable that is explicitly set in the environment overrides the
corresponding profile value.

See [`.env.example`](../.env.example) for the complete list with default values and
descriptions.

### Override examples

```bash
# Use aggressive mode but disable batched reveal
HTMX_CACHE_MODE=aggressive
HTMX_BATCHED_REVEAL_ENABLED=0

# Use balanced mode but enable intent-based prefetch only
HTMX_CACHE_MODE=balanced
HTMX_HOVER_PREFETCH_ENABLED=1

# Use conservative mode but re-enable warmup
HTMX_CACHE_MODE=conservative
HTMX_WARMUP_ENABLED=1
```

---

## Operational playbook

### Rollback switches

Every new feature has a dedicated `HTMX_*_ENABLED` env var. If any feature causes issues in
production, disable it with a single env var change — no code rollback, no mode change
required.

| Switch | Effect when set to `0` |
|---|---|
| `HTMX_WARMUP_ENABLED` | Disables all warmup and shell prefetch activity |
| `HTMX_HOVER_PREFETCH_ENABLED` | Disables intent-based prefetch on page selector |
| `HTMX_PARALLEL_SHELL_PREFETCH` | Reverts to sequential shell prefetch |
| `HTMX_BATCHED_REVEAL_ENABLED` | Reverts to immediate per-widget render |
| `HTMX_OFFSCREEN_PAUSE_ENABLED` | Reverts to current offscreen behavior |
| `HTMX_REWARMUP_ON_FILTER_CHANGE` | Disables re-warmup after filter changes |
| `HTMX_ADAPTIVE_DIALDOWN_ENABLED` | Disables self-tuning prefetch suppression |
| `HTMX_PERSIST_CACHE_ENABLED` | Disables localStorage persistence |

### Switching modes

1. Set `HTMX_CACHE_MODE=<mode>` in the environment or `.env` file.
2. Restart the HTMX server process.
3. Hard-refresh the browser (Ctrl+Shift+R) to clear in-memory caches.

The mode change takes effect on the next page render. Existing browser sessions will pick up
new `data-*` values on their next full page load.

### Diagnosing with perf metrics

Set `HTMX_CLIENT_PERF_METRICS=1` (or use aggressive mode, which enables it by default).
Open the browser console — counters are logged every 60 s:

```
[riskdash] perf metrics {
  softNavShellCacheHit: 4,
  softNavShellCacheMiss: 1,
  warmupShellPrefetchAttempted: 5,
  warmupShellPrefetchSuccess: 4,
  suppressedOffscreenPoll: 12,
  adaptiveDialdownTriggered: 0,
  ...
}
```

The full metrics object is also available at `window.__riskdashPerfMetrics` for programmatic
access.

### Acceptance KPIs

| Metric | Target |
|---|---|
| Page-switch shell hit-rate | > 80% in aggressive after warmup |
| Median time-to-first-visible-widget | < 200 ms from cache, < 1 s cold |
| Max concurrent in-flight widget requests | <= 5 in aggressive, unlimited in balanced |
| Wasted prefetch rate | < 80% (at least 20% of prefetches used) |

---

## Data flow for a widget request

```
User lands on page
       │
       ▼
DOMContentLoaded
 ├─ persistCacheHydrate()        ← restore shells + widgets from localStorage
 ├─ initPageSelector()           ← bind soft-nav, attach prefetch if aggressive
 ├─ initFilters()                ← bind filter change → scheduleRewarmup()
 └─ initWidgetVisibilityTracking() ← IntersectionObserver for viewport awareness
       │
       ▼
triggerDashboardRefresh({ prioritizeViewport: true })
 ├─ Classify widgets: visibleCritical / visibleOther / deferredCritical / deferredOther
 ├─ If BATCHED_REVEAL_ENABLED: record above-fold targets, start timeout
 ├─ If MAX_CONCURRENT_WIDGET_REQUESTS > 0: tiered queue
 │   ├─ Tier 0 (critical visible): fire immediately (reserved slots)
 │   ├─ Tier 1 (visible other): fire as slots free
 │   └─ Tier 2 (deferred): queue behind Tiers 0–1
 └─ Else: fire visible immediately, stagger deferred with timeouts
       │
       ▼
htmx:beforeRequest
 ├─ Market-disabled check → suppress
 ├─ Pipeline switch / hidden → suppress
 ├─ OFFSCREEN_PAUSE_ENABLED + offscreen → defer until IntersectionObserver fires
 └─ Stale offscreen poll → suppress
       │
       ▼
htmx:beforeSend
 └─ Increment _concurrencyInFlight
       │
       ▼
  HTTP GET /api/v1/{page}/{widget}?...
       │
       ▼
htmx:afterRequest
 ├─ Decrement _concurrencyInFlight, drain queue
 ├─ Parse JSON payload
 ├─ If BATCHED_REVEAL_ENABLED + widget is above-fold target:
 │   └─ Buffer payload; flush when quorum met or timeout expires
 └─ Else: _renderWidgetResponse()
     ├─ If SKELETON_MIN_DISPLAY_MS > 0 and skeleton was shown < min:
     │   └─ Delay render by remaining time
     └─ renderPayload() → updateTimestamp() → setWidgetCachedPayload()
       │
       ▼
initWarmupScheduler() (after 4 s + user interaction)
 ├─ POST /api/v1/warmup (server precomputes responses)
 └─ prefetchWarmupShells() (parallel or sequential based on config)
       │
       ▼
persistCacheWrite() (every 30 s + beforeunload, if enabled)
```
