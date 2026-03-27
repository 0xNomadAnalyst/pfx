# Performance Wave 3 Run Report (2026-03-26)

## Goal Order

1. Observability depth (frontend + API + SQL correlation)
2. Reliability gates (timeouts/errors/abort bounds)
3. Tail-latency reduction experiments

## Implemented Scope

- Frontend nav-trace propagation and correlation fields in `window.__softNavDebug`.
- API telemetry expansion with:
  - per-page and per-widget latency rollups (`avg/p50/p95/p99/max`)
  - status family counters
  - nav-trace counters
- SQL telemetry expansion with query fingerprint rollups (`avg/p95/p99/max`) keyed by page/widget context.
- Frontend benchmark gate expansion:
  - `--max-route-timeouts`
  - `--max-route-abort-ratio`
- API benchmark load expansion:
  - `--parallel-ramp`
  - `--soak-seconds`
  - `--soak-pause-seconds`
  - per-profile telemetry before/after snapshots in output JSON.

## Reliability Test Results

### Frontend phase benchmark

Command:

```bash
python "scripts/soft_nav_phase_benchmark.py" \
  --url http://127.0.0.1:8002/global-ecosystem \
  --cycles 1 \
  --max-timeouts 0 \
  --max-route-errors 2 \
  --max-route-5xx 0 \
  --max-route-timeouts 0 \
  --max-route-abort-ratio 1.0 \
  --headless
```

Result: **PASS**

- Settled targets: `6/6`
- Timeout count: `0`
- Route 5xx max: `0`
- Route timeout max: `0`

### Frontend stress benchmark

Command:

```bash
python "scripts/sidebar_nav_stress_test.py" \
  --url http://127.0.0.1:8002/global-ecosystem \
  --bursts 2 \
  --clicks-per-burst 20 \
  --interval-ms 40 \
  --max-timeouts 0 \
  --max-route-errors 2 \
  --max-route-5xx 0 \
  --max-route-timeouts 0 \
  --max-route-abort-ratio 1.0 \
  --headless
```

Result: **PASS**

- Timed-out bursts: `0`
- Route 5xx max: `0`
- Route timeout max: `0`

### API regression/unit suites

Command:

```bash
python -m unittest \
  tests.test_query_cache_singleflight \
  tests.test_benchmark_load_profiles \
  tests.test_data_service_telemetry_rollup \
  tests.test_pipeline_switch_concurrency \
  tests.test_benchmark_risk_analysis_coverage
```

Result: **PASS** (`12` tests)

## Load Expansion Runs

### Mixed-route ramp + soak

Artifact: `htmx/docs/benchmark-runs/wave3-api-ramp-soak.json`

Profile: `risk-analysis,health,global-ecosystem`, `parallel-ramp=1,3`, `soak-seconds=20`

Result: **FAIL (promotion gate)**

- Soak surfaced repeatable 5xx on:
  - `global-ecosystem/ge-activity-vol-usx`
  - `global-ecosystem/ge-tvl-share-usx`
- Failures observed: `120` scenario failures in mixed-route soak.

## Tuning Experiments (post reliability)

### Critical routes baseline

Artifact: `htmx/docs/benchmark-runs/wave3-api-baseline-critical.json`

- Pages: `risk-analysis,health`
- Parallel: `1`
- Result: **PASS** (`0` failures)

### Critical routes tuned profile

Artifact: `htmx/docs/benchmark-runs/wave3-api-tuned-critical.json`

- Pages: `risk-analysis,health`
- Parallel: `3`
- Result: **PASS** (`0` failures)
- Observed behavior: significantly faster many cold paths, but some p95 spikes remain on selected widgets.

## Promotion Decision

### Candidate winning profile (stage)

- API benchmark profile: `parallel=3` for critical routes (`risk-analysis`, `health`) only.
- Frontend gate profile: keep route timeout/5xx gates enabled in phase + stress scripts.

### Production promotion status

- **Not approved for full-route production promotion yet** due to mixed-route soak failures on `global-ecosystem`.

## Rollback Runbook

1. Revert API concurrency profile to baseline:
   - use benchmark baseline profile (`parallel=1`) as the fallback envelope.
2. Keep frontend reliability gates active while rolling back:
   - `--max-timeouts 0`
   - `--max-route-5xx 0`
   - `--max-route-timeouts 0`
3. Re-run quick validation:
   - `wave3-smoke-header-health.json` workflow
   - one phase + one stress benchmark cycle
4. Verify telemetry reset and re-capture:
   - `POST /api/v1/telemetry/reset`
   - `GET /api/v1/telemetry`

## Next Actions

- Fix `global-ecosystem` query-path failures for `ge-activity-vol-usx` and `ge-tvl-share-usx`.
- Re-run mixed-route ramp/soak after fixes.
- Promote tuned profile only when mixed-route soak reports zero 5xx/timeout regressions.
