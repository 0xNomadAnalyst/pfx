# Soft-Nav Testing and Telemetry

This document covers:

- the **sidebar navigation interaction stress test**
- the **soft-nav phase benchmark**
- telemetry exposed in the browser for preload, hydration, and final data settle

---

## Prerequisites

- HTMX UI running (typically `http://127.0.0.1:8002`)
- Python dependencies installed (`playwright`)
- Chromium runtime installed for Playwright

```bash
pip install playwright
python -m playwright install chromium
```

---

## 1) Sidebar Nav Interaction Stress Test

Script: `htmx/scripts/sidebar_nav_stress_test.py`

### Purpose (Stress Test)

Simulates rapid clicks on sidebar view links and reports whether soft-nav settles cleanly or gets stuck.

### Best Used For (Stress Test)

- detecting queue/in-flight lockups
- validating rapid click responsiveness
- confirming stale in-flight requests are superseded correctly

### Run (Stress Test)

```bash
python "htmx/scripts/sidebar_nav_stress_test.py" \
  --url http://127.0.0.1:8002/global-ecosystem \
  --bursts 3 \
  --clicks-per-burst 30 \
  --interval-ms 35 \
  --headless
```

### Important note

This script requires sidebar links (`#sidebar-nav .sidebar-nav-link`).  
If sidebar nav mode is off, enable `NAV_LAYOUT_SIDEBAR=1` before running.

### Key output fields

- `starts` / `finishes`: soft-nav requests started/completed
- `inFlight`: whether nav is still active at end
- `queuedPath`: pending queued destination
- `cacheHits` / `cacheMisses`: shell cache behavior
- `supersededHydrationSkips`: number of hydration passes intentionally skipped
- `burst_summaries`: per-burst settle status, terminal hydration reason, and delta counts
- `route_error_summary`: route-level totals for `errors_5xx`, `errors_total`, `timeouts`, `aborts`
- `route_error_summary[*].started`: per-route started request delta used for abort-ratio guardrails

### Optional assertion gates

Use these in CI/regression runs:

- `--max-timeouts` (default `-1`, disabled)
- `--max-route-errors` (default `-1`, disabled)
- `--max-route-5xx` (default `-1`, disabled)
- `--max-route-timeouts` (default `-1`, disabled)
- `--max-route-abort-ratio` (default `-1`, disabled)
- `--max-hydration-orphans` (default `-1`, disabled)

### Healthy signal

- every burst reports `settled`
- final snapshot has `inFlight: false` and empty `queuedPath`
- `finishes` tracks closely with actual destination transitions

---

## 2) Soft-Nav Phase Benchmark

Script: `htmx/scripts/soft_nav_phase_benchmark.py`

### Purpose (Phase Benchmark)

Measures phase timings per navigation target:

1. shell becomes visible
2. hydration work completes
3. widget/data requests settle

### Best Used For (Phase Benchmark)

- identifying whether latency is shell, hydration, or data dominated
- comparing tuning changes (cache, prefetch, hydration guard) with p95 data
- regression checks during frontend performance work

### Run (Phase Benchmark)

```bash
python "htmx/scripts/soft_nav_phase_benchmark.py" \
  --url http://127.0.0.1:8002/global-ecosystem \
  --cycles 2 \
  --headless
```

### Behavior

- discovers targets from sidebar links, or falls back to page selector options
- navigates through all targets for N cycles
- waits for settle state:
  - `inFlight == false`
  - `queuedPath == ""`
  - `widgetRequestsInFlight == 0`

### Per-sample metrics

- `shell_visible_ms`
- `hydration_ms`
- `widget_settle_ms`
- `in_flight_ms`
- `hydration_terminal_reason`
- request counter deltas (`widget_requests_started_delta`, `widget_request_errors_delta`, etc.)
- request counters and cache counters

### Aggregate metrics

- avg and p95 for shell/hydration/widget-settle/in-flight
- timeout count vs settled count
- `terminal_hydration_reasons_by_path`
- `route_error_summary`

### Optional Assertion Gates (Phase Benchmark)

- `--max-timeouts` (default `-1`, disabled)
- `--max-route-errors` (default `-1`, disabled)
- `--max-route-5xx` (default `-1`, disabled)
- `--max-route-timeouts` (default `-1`, disabled)
- `--max-route-abort-ratio` (default `-1`, disabled)
- `--max-hydration-orphans` (default `-1`, disabled)

---

## Browser Telemetry Exposed

Telemetry is exposed through:

- `window.__softNavDebug.snapshot()`
- `window.__softNavDebug.reset()`
- `window.__riskdashPerfMetrics` (existing broader perf counters)

Wave 3 correlation fields:

- `activeNavTraceId`
- `lastCompletedNavTraceId`

### Soft-nav counters (high-level)

- `starts`, `finishes`
- `queueEnqueues`, `queueDrains`
- `cacheHits`, `cacheMisses`
- `pendingSkeletonShows`
- `supersededHydrationSkips`

### New phase-level telemetry

- **Shell visibility**
  - `shellVisibleCount`
  - `lastShellVisibleMs`
  - `maxShellVisibleMs`
- **Hydration**
  - `hydrationStarts`
  - `hydrationFinishes`
  - `hydrationSkips`
  - `hydrationCancelledSuperseded`
  - `hydrationCancelledNav`
  - `lastHydrationTerminalReason`
  - `lastHydrationMs`
  - `maxHydrationMs`
- **Widget/data settle**
  - `lastWidgetSettleMs`
  - `maxWidgetSettleMs`
  - `widgetRequestsInFlight`
  - `widgetRequestsStarted`
  - `widgetRequestsCompleted`
  - `widgetRequestsAborted`
  - `widgetRequestErrors`
  - `widgetRequest5xx`
  - `widgetRequestTimeouts`
- **Shell cache state**
  - `shellCacheSize`
  - `shellCacheCapacity`
  - `allShellPrefetchScheduled`
  - `allShellPrefetchCompleted`
- **Prefetch telemetry**
  - `shellPrefetchAttempts`
  - `shellPrefetchSuccesses`
  - `shellPrefetchFailures`
  - `shellPrefetchInFlightJoins`
  - `lastShellPrefetchMs`
  - `maxShellPrefetchMs`
  - `prefetchByPath` (`attempts/successes/failures/inFlightJoins/avgMs/maxMs/lastMs`)

### Event stream (`snapshot().events`)

Includes timestamped records such as:

- `start`, `finish`
- `shell_visible`
- `hydrate_start`, `hydrate_finish`, `hydrate_settled`, `hydrate_skip`
- `queue_enqueue`, `queue_drain`
- `superseded_skip`, `superseded_skip_post_guard`
- `shell_prefetch_success`, `shell_prefetch_failed`
- `widget_request_error`, `widget_request_send_error`, `widget_request_timeout`, `widget_request_abort`

Wave 3 request-correlation events include:

- `navTraceId`
- `requestId`

---

## API Telemetry Surface

When `API_TELEMETRY_ENABLED=1` on the API service:

- `GET /api/v1/telemetry` returns:
  - `request_stats` (request totals, success/error totals, by-page/by-widget counters)
  - `request_stats.status_family_counts` (`2xx/4xx/5xx` family counts)
  - `request_stats.latency_by_page` (`count/avg/p50/p95/p99/max`)
  - `request_stats.latency_by_widget` (`count/avg/p50/p95/p99/max`)
  - `request_stats.nav_trace_counts` (top-level nav-trace fanout)
  - `cache_stats` (QueryCache counters)
  - `sql_pool_pressure` (checkout wait counters and query timing counters)
  - `sql_pool_pressure.query_fingerprint_stats` (fingerprint-level `count/error/avg/p95/p99/max` plus `page/widget/query_preview`)
- `POST /api/v1/telemetry/reset` resets request + SQL telemetry counters

Benchmark capture support:

```bash
python "api-w-caching/scripts/benchmark_dashboard.py" \
  --base-url http://127.0.0.1:8005 \
  --page header-health \
  --quick \
  --capture-telemetry \
  --reset-telemetry \
  --output-json "htmx/docs/perf-wave2-api-telemetry-sample.json"
```

Wave 3 load/soak expansion flags:

```bash
python "api-w-caching/scripts/benchmark_dashboard.py" \
  --base-url http://127.0.0.1:8001 \
  --page risk-analysis,health,global-ecosystem \
  --quick \
  --parallel-ramp 1,3 \
  --soak-seconds 20 \
  --soak-pause-seconds 1 \
  --capture-telemetry \
  --reset-telemetry \
  --output-json "htmx/docs/benchmark-runs/wave3-api-ramp-soak.json"
```

---

## Quick Debug Snippets

Reset counters in browser console:

```js
window.__softNavDebug.reset();
```

Get current snapshot:

```js
window.__softNavDebug.snapshot();
```

---

## Troubleshooting

- **`window.__softNavDebug is missing`**
  - hard refresh the page
  - ensure latest `charts.js` is loaded (cache-busted script URL)
- **`ERR_CONNECTION_REFUSED`**
  - verify HTMX service is running on `:8002`
- **stress test cannot find sidebar links**
  - enable `NAV_LAYOUT_SIDEBAR=1` and reload
- **many `htmx:sendAbort` console errors during rapid switching**
  - expected under aggressive cancellation; use benchmark/stress snapshots as ground truth for actual settle behavior
