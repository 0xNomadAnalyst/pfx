# Loading Speed Assessment (2026-03-27)

This report implements the site-loading assessment plan across preload, hydration, and data settle behavior using:

- `scripts/sidebar_nav_stress_test.py`
- `scripts/soft_nav_phase_benchmark.py`
- `window.__softNavDebug` telemetry

---

## Test Environment

- UI service: local HTMX instances on ports `8012` to `8015`
- API service: `http://127.0.0.1:8001`
- Navigation mode: `NAV_LAYOUT_SIDEBAR=1`
- Script versions:
  - `scripts/sidebar_nav_stress_test.py`
  - `scripts/soft_nav_phase_benchmark.py` (hardened to tolerate transient Playwright context resets during same-tab hard navigations)

### Baseline configuration

- `HTMX_CACHE_MODE=balanced`

### One-knob experiment configurations

- Preload knob: `HTMX_HOVER_PREFETCH_ENABLED=1`
- Hydration/data concurrency knob: `HTMX_MAX_CONCURRENT_WIDGET_REQUESTS=5`
- Data defer knob: `HTMX_OFFSCREEN_PAUSE_ENABLED=1`

---

## Commands Used

Stress:

```bash
python "scripts/sidebar_nav_stress_test.py" \
  --url http://127.0.0.1:<port>/global-ecosystem \
  --bursts 2 --clicks-per-burst 25 --interval-ms 35 --headless
```

Phase benchmark:

```bash
python "scripts/soft_nav_phase_benchmark.py" \
  --url http://127.0.0.1:<port>/global-ecosystem \
  --cycles 1 --headless
```

---

## Baseline Results (balanced)

### Stress summary (port 8012)

- Settled bursts: `2/2`
- Final state: `inFlight=false`, `queuedPath=""`
- `cacheHits=2`, `cacheMisses=0`
- `lastShellVisibleMs=6.6`
- `widgetRequestsAborted=83`

### Phase benchmark summary (port 8012)

- Settled targets: `6/6`
- `shell_visible_ms_p95=3.75`
- `hydration_ms_p95=34859.0`
- `widget_settle_ms_p95=34859.0`
- `in_flight_ms_p95=3.75`
- High abort churn and repeated 502 responses observed on `risk-analysis`/`system-health` paths.

---

## Experiment Matrix Results

| Scenario | Stress settled | Shell p95 (ms) | Hydration p95 (ms) | Widget settle p95 (ms) | Notable effects |
| --- | ---: | ---: | ---: | ---: | --- |
| Baseline (`balanced`) | 2/2 | 3.75 | 34859.0 | 34859.0 | Stable shell swap; backend/API errors dominate long-tail settle |
| `HTMX_HOVER_PREFETCH_ENABLED=1` | 2/2 | 4.8 | 34784.0 | 34784.0 | No material improvement vs baseline; slightly worse shell p95 |
| `HTMX_MAX_CONCURRENT_WIDGET_REQUESTS=5` | 2/2 | 3.2 | 18456.9 | 0.0* | Best p95 shell and hydration; significantly lower hydration tail |
| `HTMX_OFFSCREEN_PAUSE_ENABLED=1` | 2/2 | 4.6 | 36773.4 | 36773.4 | No improvement; slightly worse tail timings |

\* `widget_settle_ms_p95=0.0` in this run reflects current telemetry caveat when hydrate traces are superseded/finished without settle marker, not guaranteed instant data completion.

---

## Diagnosis

### What is working

- Shell preload/swap is consistently fast (single-digit ms p95).
- Queue control prevents nav lockups (`inFlight` and `queuedPath` clear at test end).

### Primary bottleneck

- Long-tail load feel is dominated by downstream widget request churn and backend/API failures (frequent `502`, many aborted HTMX requests), especially on `risk-analysis` and `system-health`.

### Secondary issue (observability quality)

- Hydration telemetry in rapid/superseded flows often records `hydrationStarts` without matching `hydrationFinishes`, and can under-report settle in some paths.
- This is a telemetry quality gap rather than a shell-swap speed issue.

---

## Regression Gates (Pass/Fail)

Use these for tuning acceptance:

1. Stress gate:
   - `settled bursts == total bursts`
   - final `inFlight=false` and `queuedPath=""`
2. Error gate:
   - `widgetRequestErrors` and HTTP 5xx should not increase over baseline
3. Shell gate:
   - `shell_visible_ms_p95 <= 10ms` on warmed routes
4. Hydration gate:
   - `hydration_ms_p95` must be <= baseline by at least 20% for promotion
5. Stability gate:
   - No benchmark timeouts (`timeout_count=0`)

---

## Recommended Rollout

### Recommended setting change (first promotion)

- Promote `HTMX_MAX_CONCURRENT_WIDGET_REQUESTS=5` on top of balanced mode.

Rationale:

- Best measured reduction in hydration tail (`~48%` lower p95 vs baseline in this environment).
- No regressions in stress settle behavior.

### Keep as-is for now

- Do not promote `HTMX_HOVER_PREFETCH_ENABLED=1` yet (no clear gain).
- Do not promote `HTMX_OFFSCREEN_PAUSE_ENABLED=1` yet (no gain and worse tails).

### Staged rollout steps

1. Stage: set only `HTMX_MAX_CONCURRENT_WIDGET_REQUESTS=5` with `HTMX_CACHE_MODE=balanced`.
2. Run both scripts on stage and compare against this report's baseline.
3. If stable, roll to production with monitoring on:
   - `widgetRequestErrors`
   - `hydration_ms_p95`
   - stress settle pass rate
4. Keep rollback ready:
   - set `HTMX_MAX_CONCURRENT_WIDGET_REQUESTS=0` (balanced default)

---

## Follow-up Actions

1. Telemetry refinement:
   - Add explicit hydrate completion/settle markers for superseded traces to improve p95 reliability.
2. Backend/API reliability:
   - Investigate repeated `502` paths for `risk-analysis` and `system-health` endpoints; current frontend tail is mostly bounded by this.
3. Optional next experiment:
   - Test combined profile: `HTMX_MAX_CONCURRENT_WIDGET_REQUESTS=5` + `HTMX_BATCHED_REVEAL_ENABLED=1` with low timeout, gated by same thresholds.

---

## Wave 3 Addendum (2026-03-26)

Wave 3 extends the assessment surface with correlated nav-trace telemetry, route-level abort/timeout gates, and mixed-route API ramp/soak runs.

### New benchmark artifacts

- `htmx/docs/benchmark-runs/wave3-api-ramp-soak.json`
- `htmx/docs/benchmark-runs/wave3-api-baseline-critical.json`
- `htmx/docs/benchmark-runs/wave3-api-tuned-critical.json`
- `htmx/docs/benchmark-runs/wave3-smoke-header-health.json`

### Key takeaways

- Mixed-route soak uncovered persistent `global-ecosystem` 5xx hotspots (`ge-activity-vol-usx`, `ge-tvl-share-usx`), so global-route promotion remains blocked.
- Critical-route reliability (`risk-analysis`, `system-health`) passes in API baseline and tuned runs with `fail_on_errors`.
- Frontend phase/stress runs pass timeout and 5xx gates with new route timeout/abort-ratio assertions enabled.
- Parallel API profile (`parallel=3`) materially lowers many cold and warm latencies on critical routes, but still shows tail spikes in selected health/risk widgets; keep as stage-only until repeated soak remains clean.
