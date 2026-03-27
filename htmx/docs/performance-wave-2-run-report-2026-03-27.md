# Performance Wave 2 Run Report (2026-03-27)

## Goal Order Followed

1. Observability and measurement fidelity
2. Reliability/error containment
3. Speed tuning under explicit gates

## Scope Implemented

- Frontend telemetry upgrades in `htmx/app/static/js/charts.js`
- Frontend benchmark fidelity upgrades in:
  - `htmx/scripts/soft_nav_phase_benchmark.py`
  - `htmx/scripts/sidebar_nav_stress_test.py`
- API telemetry surface upgrades in:
  - `api-w-caching/app/services/sql_adapter.py`
  - `api-w-caching/app/services/data_service.py`
  - `api-w-caching/app/api/routes.py`
- API benchmark coverage additions in:
  - `api-w-caching/scripts/benchmark_dashboard.py`
  - `api-w-caching/tests/test_benchmark_risk_analysis_coverage.py`
- Reliability regression tests in:
  - `api-w-caching/tests/test_query_cache_singleflight.py`
  - `api-w-caching/tests/test_pipeline_switch_concurrency.py`

## Executed Runs

### Frontend phase benchmark (baseline profile)

Command:

```bash
python "htmx/scripts/soft_nav_phase_benchmark.py" \
  --url http://127.0.0.1:8002/global-ecosystem \
  --cycles 1 \
  --settle-timeout-s 60 \
  --headless
```

Observed:

- `timeout_count`: `0`
- `shell_visible_ms_p95`: `7.95`
- `hydration_ms_p95`: `408.35`
- `widget_settle_ms_p95`: `408.35`
- route-level `errors_5xx`: `0` across targets
- route-level `errors_total`: `0` across targets

### Frontend phase benchmark (tuned experiment: batched reveal)

Command:

```bash
python "htmx/scripts/soft_nav_phase_benchmark.py" \
  --url http://127.0.0.1:8003/global-ecosystem \
  --cycles 1 \
  --settle-timeout-s 60 \
  --headless
```

Observed:

- `timeout_count`: `1` (regression against reliability gate)
- `shell_visible_ms_p95`: `6.94`
- `hydration_ms_p95`: `355.32`
- `widget_settle_ms_p95`: `355.32`
- route-level `errors_5xx`: `0`
- route-level `errors_total`: `0`

Interpretation:

- The tuned profile improved latency distribution but violated reliability (`timeout_count > 0`).
- Per gate order, this profile is rejected for rollout until timeout behavior is resolved.

### Sidebar stress benchmark (baseline)

Command:

```bash
python "htmx/scripts/sidebar_nav_stress_test.py" \
  --url http://127.0.0.1:8002/global-ecosystem \
  --bursts 2 \
  --clicks-per-burst 20 \
  --interval-ms 30 \
  --settle-timeout-s 45 \
  --headless
```

Observed:

- both bursts settled
- route-level `errors_5xx`: `0`
- route-level `errors_total`: `0`
- timeout bursts: `0`

### Sidebar stress benchmark (tuned experiment)

Command:

```bash
python "htmx/scripts/sidebar_nav_stress_test.py" \
  --url http://127.0.0.1:8003/global-ecosystem \
  --bursts 2 \
  --clicks-per-burst 20 \
  --interval-ms 30 \
  --settle-timeout-s 45 \
  --headless
```

Observed:

- both bursts settled
- route-level `errors_5xx`: `0`
- route-level `errors_total`: `0`
- timeout bursts: `0`

### API telemetry surface smoke capture

Command:

```bash
python "api-w-caching/scripts/benchmark_dashboard.py" \
  --base-url http://127.0.0.1:8005 \
  --page header-health \
  --windows 24h \
  --repeats 1 \
  --quick \
  --capture-telemetry \
  --reset-telemetry \
  --output-json "htmx/docs/perf-wave2-api-telemetry-sample.json"
```

Artifact:

- `htmx/docs/perf-wave2-api-telemetry-sample.json`

Notes:

- Confirmed telemetry endpoint shape and benchmark capture integration.

## Gate Evaluation

- Measurement integrity
  - PASS: phase and stress scripts completed and returned structured telemetry summaries.
  - PASS: route-level error summaries and terminal hydration reasons captured per target.
- Reliability
  - BASELINE PASS: `timeout_count = 0`, no route 5xx.
  - TUNED FAIL: phase benchmark timeout detected (`timeout_count = 1`).
- Performance
  - TUNED looked faster in p95 hydration/data settle, but reliability failed, so not promoted.

## Recommendation

- Keep baseline profile as current candidate:
  - `HTMX_CACHE_MODE=balanced`
  - `HTMX_MAX_CONCURRENT_WIDGET_REQUESTS=5`
- Do not enable `HTMX_BATCHED_REVEAL_ENABLED` in rollout until timeout regression is eliminated.
- Use new assertion flags in CI:
  - phase: `--max-timeouts 0 --max-route-errors 0 --max-route-5xx 0`
  - stress: `--max-timeouts 0 --max-route-errors 0 --max-route-5xx 0`

## Rollback Checklist

- Revert to baseline env profile above.
- Re-run:
  - one phase benchmark cycle
  - one stress benchmark run
- Confirm:
  - `timeout_count == 0`
  - route-level `errors_5xx == 0`
  - no benchmark script assertion failures
