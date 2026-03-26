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

### Purpose

Simulates rapid clicks on sidebar view links and reports whether soft-nav settles cleanly or gets stuck.

### Best used for

- detecting queue/in-flight lockups
- validating rapid click responsiveness
- confirming stale in-flight requests are superseded correctly

### Run

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

### Healthy signal

- every burst reports `settled`
- final snapshot has `inFlight: false` and empty `queuedPath`
- `finishes` tracks closely with actual destination transitions

---

## 2) Soft-Nav Phase Benchmark

Script: `htmx/scripts/soft_nav_phase_benchmark.py`

### Purpose

Measures phase timings per navigation target:

1. shell becomes visible
2. hydration work completes
3. widget/data requests settle

### Best used for

- identifying whether latency is shell, hydration, or data dominated
- comparing tuning changes (cache, prefetch, hydration guard) with p95 data
- regression checks during frontend performance work

### Run

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
- request counters and cache counters

### Aggregate metrics

- avg and p95 for shell/hydration/widget-settle/in-flight
- timeout count vs settled count

---

## Browser Telemetry Exposed

Telemetry is exposed through:

- `window.__softNavDebug.snapshot()`
- `window.__softNavDebug.reset()`
- `window.__riskdashPerfMetrics` (existing broader perf counters)

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
  - `widgetRequestTimeouts`
- **Shell cache state**
  - `shellCacheSize`
  - `shellCacheCapacity`
  - `allShellPrefetchScheduled`
  - `allShellPrefetchCompleted`

### Event stream (`snapshot().events`)

Includes timestamped records such as:

- `start`, `finish`
- `shell_visible`
- `hydrate_start`, `hydrate_finish`, `hydrate_settled`, `hydrate_skip`
- `queue_enqueue`, `queue_drain`
- `superseded_skip`, `superseded_skip_post_guard`

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

