# Performance Wave 4 Run Report (2026-03-27)

## Objective

- Stabilize `global-ecosystem` hotspot widgets (`ge-activity-vol-usx`, `ge-tvl-share-usx`) and unblock promotion by adding hotspot-level telemetry and per-widget reliability gates.

## Wave 4 Implementation Highlights

- Added hotspot widget handlers and cache keys in `GlobalEcosystemPageService`.
- Added hotspot prewarm controls in `DataService` (`API_PREWARM_GLOBAL_HOTSPOTS_ENABLED`).
- Added hotspot telemetry summary in API telemetry output:
  - per-widget latency rollups,
  - per-widget status family counts,
  - top SQL fingerprint entries and pool-wait context.
- Added benchmark hotspot gate flags:
  - `--max-widget-errors`
  - `--max-widget-5xx`
  - `--max-widget-timeouts`
  - `--hotspot-widgets`
- Added regression tests for hotspot handlers, hotspot summary logic, and benchmark hotspot aggregation.

## Validation Matrix

### 1) API critical baseline (updated service)

Artifact: `htmx/docs/benchmark-runs/wave4-api-baseline-critical-8011-rerun.json`

- Pages: `risk-analysis,health`
- Profile: `parallel=1`
- Result: **PASS**
- Scenario failures: `0`

### 2) API critical tuned (updated service)

Artifact: `htmx/docs/benchmark-runs/wave4-api-tuned-critical-8011.json`

- Pages: `risk-analysis,health`
- Profile: `parallel=3`
- Result: **PASS**
- Scenario failures: `0`

### 3) API mixed-route ramp + soak with hotspot gates

Artifact: `htmx/docs/benchmark-runs/wave4-api-ramp-soak-8011.json`

- Pages: `risk-analysis,health,global-ecosystem`
- Profiles: `parallel-ramp=1,3`
- Soak duration: `120s`
- Hotspot gates:
  - `max-widget-errors=0`
  - `max-widget-5xx=0`
  - `max-widget-timeouts=0`
- Result: **PASS**
- Scenario failures: `0`
- Hotspot summary:
  - `global-ecosystem/ge-activity-vol-usx`: `errors=0`, `5xx=0`, `timeouts=0`, `warm_p95_max_ms=27.38`
  - `global-ecosystem/ge-tvl-share-usx`: `errors=0`, `5xx=0`, `timeouts=0`, `warm_p95_max_ms=27.22`

### 4) Frontend reliability re-check (existing gates)

- `htmx/scripts/soft_nav_phase_benchmark.py`: **PASS**
- `htmx/scripts/sidebar_nav_stress_test.py`: **PASS**

## Promotion Decision

- **Stage recommendation:** promote Wave 4 hotspot handler + gate changes.
- **Production recommendation:** promote with hotspot widget gates retained in validation pipeline.
- **Reason:** mixed-route soak now passes hotspot reliability envelopes that blocked Wave 3 promotion.

## Rollback Checklist

1. Revert service-side hotspot aliases/cache behavior (Wave 4 changes in `global_ecosystem.py` and `data_service.py`).
2. Keep benchmark hotspot gates in place but temporarily relax thresholds if rollback is active.
3. Re-run:
   - critical baseline (`parallel=1`),
   - mixed-route quick ramp (`parallel-ramp=1,3`, no soak),
   - frontend phase + stress scripts.
4. Confirm no route-level timeout/5xx regressions before closing rollback.

## Known Caveats

- Telemetry snapshots in benchmark JSON require `API_TELEMETRY_ENABLED=1`; runs against instances with telemetry disabled will omit telemetry snapshots.
- Reload-mode local servers can transiently drop requests during restart windows; use stable process mode for strict benchmark reproducibility.
