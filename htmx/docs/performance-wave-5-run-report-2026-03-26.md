# Performance Wave 5 Run Report (Navigation-First Data Readiness)

## Objective

- Unify UI+API refresh cadence under `DASH_REFRESH_INTERVAL_SECONDS`.
- Add robust `localStorage + TTL` persistence with stale-while-revalidate semantics.
- Expand telemetry and benchmark gates for persistence and cadence compliance.

## Implementation Delivered

- Unified cadence control:
  - `htmx/app/main.py` now derives UI refresh defaults from `DASH_REFRESH_INTERVAL_SECONDS` while preserving explicit `HTMX_REFRESH_*` overrides.
  - `api-w-caching/app/services/cache_config.py` derives API TTL/SWR defaults from the same cadence variable (override-safe).
  - `api-w-caching/app/main.py` seeds API prewarm/cache defaults from cadence before service bootstrap.
- Browser persistence hardening:
  - `htmx/app/static/js/charts.js` upgraded to versioned persistence namespace (`v3`) with TTL metadata, bounded size, LRU-style trimming, stale-served behavior, and background refresh scheduling.
  - Persistence telemetry added to `window.__softNavDebug` (`persistRestoreHits`, `persistRestoreMisses`, `persistExpired`, `persistEvictions`, `persistStaleServed`, `persistStaleRefreshed`, `persistRestoreToVisibleMs`).
- Navigation-first readiness:
  - Added periodic navigation readiness scheduler (cadence-aligned shell prefetch + rewarmup scheduling).
  - Health polling cadence now derives from unified refresh interval.
- Bench/test gating expansion:
  - `htmx/scripts/soft_nav_phase_benchmark.py` and `htmx/scripts/sidebar_nav_stress_test.py` now support:
    - `--min-restore-hit-rate`
    - `--max-persist-expired`
    - `--expected-refresh-interval-seconds`
    - `--refresh-interval-tolerance-seconds`
  - `api-w-caching/scripts/benchmark_dashboard.py` now supports cadence compliance gates from API telemetry.
- Env/container alignment:
  - Added/propagated `DASH_REFRESH_INTERVAL_SECONDS` across `htmx/.env.example`, `api-w-caching/.env.example`, root `Dockerfile`, and `start-prod.sh`.

## Validation Matrix

### 1) Static and unit validation

- Python syntax check passed for all modified Python modules (`py_compile`).
- Unit tests passed:
  - `api-w-caching/tests/test_cache_config_refresh_unification.py`
  - `api-w-caching/tests/test_benchmark_widget_gates.py`
  - `api-w-caching/tests/test_benchmark_load_profiles.py`
  - `api-w-caching/tests/test_data_service_telemetry_rollup.py`

### 2) Frontend benchmark validation

- Soft-nav phase benchmark (cadence gates) passed:
  - Output: `htmx/docs/benchmark-runs/wave5-soft-nav-phase-cadence.txt`
  - Key results:
    - `timeout_count = 0`
    - `shell_visible_ms_p95 = 5.45`
    - `hydration_ms_p95 = 364.10`
    - `widget_settle_ms_p95 = 364.10`
    - `refresh_interval_seconds = 30.0` (cadence compliant)
- Sidebar stress benchmark (cadence gates) passed:
  - Output: `htmx/docs/benchmark-runs/wave5-sidebar-stress-cadence.txt`
  - Key results:
    - both bursts settled
    - route-level `errors_5xx = 0`, `errors_total = 0`, `timeouts = 0`
    - `refresh_interval_seconds = 30.0` (cadence compliant)

### 3) API benchmark validation

- Quick API benchmark completed:
  - Output: `htmx/docs/benchmark-runs/wave5-api-quick-relaxed.json`
- Observed risk:
  - `global-ecosystem/ge-activity-vol-usx` and `global-ecosystem/ge-tvl-share-usx` still return recurrent `500` responses in this local run profile.
  - Hotspot summary in report: `errors=12`, `errors_5xx=12` for each tracked hotspot.
- Cadence telemetry note:
  - API telemetry capture was unavailable in this local run (`"captured": false`), so API-side cadence assertion could not be empirically enforced from telemetry payloads in this run.

### 4) API telemetry-enabled cadence assertion (follow-up)

- Dedicated telemetry-enabled API run completed on a separate API instance (`API_TELEMETRY_ENABLED=1`, port `8013`):
  - Output: `htmx/docs/benchmark-runs/wave5-api-cadence-check-8013.json`
- Cadence assertion status:
  - Telemetry capture is now present (`"captured": true`).
  - `telemetry_after.refresh_interval_seconds = 30.0` with `expected_refresh_interval_seconds = 30.0` and tolerance `2.0` seconds.
  - This confirms API-side cadence coherence for `DASH_REFRESH_INTERVAL_SECONDS=30`.
- Hotspot reliability snapshot under telemetry-enabled run:
  - `global-ecosystem/ge-activity-vol-usx`: `errors=0`, `errors_5xx=0`, `timeouts=0`.
  - `global-ecosystem/ge-tvl-share-usx`: `errors=0`, `errors_5xx=0`, `timeouts=0`.
- Remaining caveat:
  - One scenario still showed a cold-start timeout envelope in this run (`health/health-master` cold path), while warm-path and cadence assertions remained valid.

## Recommendation for `DASH_REFRESH_INTERVAL_SECONDS`

- **Primary recommendation: `30` seconds** for production baseline.
  - Matches current ingestion-aware objective and keeps frontend/API cadence coherent.
  - Preserves responsive shell/hydration behavior under stress while limiting over-refresh pressure.
- Optional tuning bands:
  - **`20` seconds** when ingestion intensity increases and API headroom is confirmed.
  - **`45` seconds** for lower-ingestion / cost-sensitive windows.

## Follow-up Actions

- Keep API telemetry enabled in stage/perf benchmark environments so cadence gates remain enforceable end-to-end.
- Investigate cold-start timeout envelope on `health/health-master` before tightening strict zero-timeout cold-start gates.
- Add a dedicated reload-focused persistence benchmark scenario to enforce non-zero restore-hit expectations across browser restart/reload paths.
