# API with Caching (Scaffold)

This service provides a frontend-agnostic widget API for the HTMX dashboard.

## Run

1. Copy `.env.example` to `.env` and fill values.
2. Install dependencies:
   - `pip install -r requirements.txt`
3. Start API:
   - `python -m app.main`

Default URL: `http://localhost:8001`

## Benchmark routine (API + SQL/caching behavior)

Use the benchmark script to compare endpoint performance before/after SQL or caching changes.

Run from `pfx/api-w-caching`:

- `python scripts/benchmark_dashboard.py --protocol raydium --pair USX-USDC --windows 1h,24h,7d,30d --repeats 5`

Useful options:

- `--widgets liquidity-distribution,liquidity-depth,usdc-lp-flows` (focus on a subset)
- `--parallel 4` (simulate concurrent widget loads)
- `--output-json reports/bench-2026-02-25.json` (persist run for diffing)
- `--base-url http://127.0.0.1:8001` (target a different API instance)

Cache tuning env vars (API process):

- `API_CACHE_TTL_SECONDS` (default `30`)
- `API_CACHE_MAX_ENTRIES` (default `256`)

What it reports per widget/window:

- Cold latency (`cold_ms`)
- Warm latency distribution (`warm_p50_ms`, `warm_p95_ms`, `warm_avg_ms`)
- Error count and status behavior
- Typical response payload size

Recommended optimization workflow:

1. Capture a baseline report.
2. Apply one SQL or cache change.
3. Re-run the same benchmark command.
4. Compare p50/p95 and error rates.
5. Keep the change only if it improves the slow widgets/windows without regressions.

## Compare two benchmark runs

Use the comparison script to quantify regressions/improvements:

- `python scripts/compare_benchmarks.py --baseline reports/bench-before.json --candidate reports/bench-after.json`

Optional tuning:

- `--regression-threshold-pct 8` (flag smaller regressions)
- `--improvement-threshold-pct 8`
- `--sort-by p95_delta_pct` (default, also supports `p50_delta_pct`, `avg_delta_pct`, `cold_delta_pct`)

Output is grouped by widget + window (+ impact mode where applicable) with delta percentages and an overall status.

## Endpoint format

- `GET /api/v1/{page}/{widget}`
- `GET /api/v1/widgets`
- `GET /health`

## Supported page/widget

- Page: `playbook-liquidity`
- Widgets:
  - `liquidity-distribution`
  - `liquidity-depth`
  - `liquidity-change-heatmap`
  - `kpi-tvl`
  - `kpi-impact-500k`
  - `kpi-reserves`
  - `kpi-largest-impact`
  - `kpi-pool-balance`
  - `kpi-average-impact`
  - `liquidity-depth-table`
  - `usdc-pool-share-concentration`
  - `trade-size-to-impact`
  - `usdc-lp-flows`
  - `impact-from-trade-size`
  - `ranked-lp-events`

## Data sources

The API reads from SQL views/functions under `dexes/dbsql/views`, primarily:

- `get_view_tick_dist_simple`
- `get_view_dex_last`
- `get_view_dex_timeseries`
- `get_view_liquidity_depth_table`
- `get_view_dex_table_ranked_events`
