# API with Caching (Scaffold)

This service provides a frontend-agnostic widget API for the HTMX dashboard.

## Run

1. Copy `.env.example` to `.env` and fill values.
2. Install dependencies:
   - `pip install -r requirements.txt`
3. Start API:
   - `python -m app.main`
   - or `python -m uvicorn app.main:app --host 0.0.0.0 --port 8001`

Default URL: `http://localhost:8001`

## Benchmark routine (API + SQL/caching behavior)

Use the benchmark script to compare endpoint performance before/after SQL or caching changes.

Run from `pfx/api-w-caching`:

- `python scripts/benchmark_dashboard.py --protocol raydium --pair USX-USDC --windows 1h,24h,7d,30d --repeats 5`
- `python scripts/benchmark_dashboard.py --page kamino --windows 24h,7d --repeats 5`
- `python scripts/benchmark_dashboard.py --page exponent --windows 24h,7d --repeats 5`
- `python scripts/benchmark_dashboard.py --page health --windows 24h,7d --repeats 5`
- `python scripts/benchmark_dashboard.py --page global-ecosystem --windows 24h,7d --repeats 5`
- `python scripts/benchmark_dashboard.py --page header-health --windows 24h --repeats 10`
- `python scripts/benchmark_dashboard.py --base-url http://127.0.0.1:8002 --page header-health-proxy --windows 24h --repeats 10`
- `python scripts/benchmark_dashboard.py --page all --parallel 4 --output-json reports/bench-all-pages.json`

Useful options:

- `--widgets liquidity-distribution,liquidity-depth,usdc-lp-flows` (focus on a subset)
- `--quick` (run a small representative subset per page)
- `--parallel 4` (simulate concurrent widget loads)
- `--output-json reports/bench-2026-02-25.json` (persist run for diffing)
- `--base-url http://127.0.0.1:8001` (target a different API instance)

Cache tuning env vars (API process):

- `API_CACHE_TTL_SECONDS` (default `30`)
- `API_CACHE_MAX_ENTRIES` (default `256`)
- `DB_POOL_PREWARM` (default `1`, run `SELECT 1` during pool init)
- `API_PREWARM_ENABLED` (default `1`, warms selected Kamino widgets on startup)
- `API_PREWARM_WINDOWS` (default `1h,24h,7d`)
- `API_PREWARM_ROWS` (default `20,120`, warms both watchlist page sizes)
- `API_PREWARM_DEX_ENABLED` (default `1`, warms selected dex-liquidity/dex-swaps widgets on startup)
- `API_PREWARM_DEX_WINDOWS` (default `24h`)
- `API_PREWARM_EXPONENT_ENABLED` (default `1`, warms selected exponent widgets on startup)
- `API_PREWARM_EXPONENT_WINDOWS` (default `24h`)
- `API_PREWARM_EXPONENT_MKT1` (default empty, optional explicit market for warmup mkt1)
- `API_PREWARM_EXPONENT_MKT2` (default empty, optional explicit market for warmup mkt2)
- `API_PREWARM_EXPONENT_FIRST` (default `1`, run exponent warmup before Kamino/Dex jobs)
- `API_PREWARM_HEALTH_ENABLED` (default `1`, warms selected health widgets on startup)
- `API_PREWARM_HEALTH_WINDOWS` (default `24h,7d`)
- `API_PREWARM_HEALTH_SCHEMA` (default `dexes`, schema for health queue chart warmup)
- `API_PREWARM_HEALTH_ATTRIBUTE` (default `Write Rate`, queue attribute for warmup)
- `API_PREWARM_HEALTH_BASE_SCHEMA` (default `dexes`, schema for base chart warmup)
- `API_PREWARM_HEALTH_INCLUDE_HEAVY` (default `0`, set `1` to also prewarm `health-master` + `health-cagg-table`)
- `API_PREWARM_HEALTH_FIRST` (default `0`, set `1` to prioritize health warmup before other jobs)
- `API_PREWARM_GLOBAL_ENABLED` (default `1`, warms selected global-ecosystem shared caches on startup)
- `API_PREWARM_GLOBAL_WINDOWS` (default `24h,7d`)
- `API_PREWARM_GLOBAL_FIRST` (default `0`, set `1` to prioritize global warmup before other jobs)
- `API_PREWARM_MAX_SECONDS` (default `30`, prewarm time budget during startup)
- `KAMINO_V_LAST_TTL_SECONDS` (default `120`)
- `KAMINO_CONFIG_TTL_SECONDS` (default `300`)
- `KAMINO_RATE_CURVE_TTL_SECONDS` (default `300`)
- `KAMINO_MARKET_ASSETS_TTL_SECONDS` (default `300`)
- `KAMINO_SENSITIVITY_TTL_SECONDS` (default `120`)
- `KAMINO_OBLIGATION_TTL_SECONDS` (default `120`)
- `KAMINO_LOAN_SIZE_TTL_SECONDS` (default `120`)
- `DEX_LIQUIDITY_META_TTL_SECONDS` (default `300`)
- `DEX_LIQUIDITY_TICK_DIST_TTL_SECONDS` (default `120`)
- `DEX_LIQUIDITY_DEX_LAST_TTL_SECONDS` (default `120`)
- `DEX_LIQUIDITY_DEX_LAST_TIMEOUT_MS` (default `8000`)
- `DEX_LIQUIDITY_TIMESERIES_TTL_SECONDS` (default `120`)
- `DEX_LIQUIDITY_DEPTH_TABLE_TTL_SECONDS` (default `300`)
- `DEX_LIQUIDITY_RANKED_LP_TTL_SECONDS` (default `120`)
- `DEX_LIQUIDITY_RANKED_LP_TIMEOUT_MS` (default `5000`)
- `DEX_LIQUIDITY_RANKED_LP_FALLBACK_LOOKBACK` (default `12 hours`)
- `DEX_SWAPS_DEX_LAST_TTL_SECONDS` (default `120`)
- `DEX_SWAPS_DEX_LAST_TIMEOUT_MS` (default `8000`)
- `DEX_SWAPS_TIMESERIES_TTL_SECONDS` (default `120`)
- `DEX_SWAPS_OHLCV_TTL_SECONDS` (default `120`)
- `DEX_SWAPS_TICK_DIST_TTL_SECONDS` (default `120`)
- `DEX_SWAPS_DISTRIBUTION_TTL_SECONDS` (default `120`)
- `DEX_SWAPS_RANKED_EVENTS_TTL_SECONDS` (default `120`)
- `DEX_SWAPS_RANKED_EVENTS_MAX_LOOKBACK` (default `24 hours`, used for long-window ranked events)
- `DEX_SWAPS_RANKED_EVENTS_TIMEOUT_MS` (default `5000`)
- `DEX_SWAPS_RANKED_EVENTS_FALLBACK_LOOKBACK` (default `12 hours`)
- `EXPONENT_V_LAST_TTL_SECONDS` (default `120`)
- `EXPONENT_TIMESERIES_TTL_SECONDS` (default `120`)
- `EXPONENT_MARKET_ASSETS_TTL_SECONDS` (default `300`)
- `HEALTH_TABLE_TTL_SECONDS` (default `60`)
- `HEALTH_CHART_TTL_SECONDS` (default `120`)
- `HEALTH_STATUS_TTL_SECONDS` (default `15`, cache TTL for the always-on header health check)
- `HEALTH_STATUS_TIMEOUT_MS` (default `2000`, statement timeout for header health check query)
- `API_LOG_SLOW_WIDGETS` (default `0`, set `1` to log slow widget handlers)
- `API_SLOW_WIDGET_THRESHOLD_MS` (default `150`)
- `DB_LOG_SLOW_QUERIES` (default `0`, set `1` to log slow SQL calls)
- `DB_SLOW_QUERY_THRESHOLD_MS` (default `200`)

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

Prewarm impact workflow:

1. Run without prewarm:
   - `API_PREWARM_ENABLED=0 DB_POOL_PREWARM=0 python -m uvicorn app.main:app --host 0.0.0.0 --port 8011`
   - `python scripts/benchmark_dashboard.py --base-url http://127.0.0.1:8011 --page kamino --windows 1h,24h,7d --repeats 3 --output-json reports/bench-kamino-baseline.json`
2. Restart with prewarm:
   - `API_PREWARM_ENABLED=1 DB_POOL_PREWARM=1 python -m uvicorn app.main:app --host 0.0.0.0 --port 8011`
   - `python scripts/benchmark_dashboard.py --base-url http://127.0.0.1:8011 --page kamino --windows 1h,24h,7d --repeats 3 --output-json reports/bench-kamino-tuned.json`
3. Compare:
   - `python scripts/compare_benchmarks.py --baseline reports/bench-kamino-baseline.json --candidate reports/bench-kamino-tuned.json --page kamino --sort-by cold_delta_pct`

Optional tuning:

- `--regression-threshold-pct 8` (flag smaller regressions)
- `--improvement-threshold-pct 8`
- `--sort-by p95_delta_pct` (default, also supports `p50_delta_pct`, `avg_delta_pct`, `cold_delta_pct`)

Output is grouped by widget + window (+ impact mode where applicable) with delta percentages and an overall status.

## Endpoint format

- `GET /api/v1/{page}/{widget}`
- `GET /api/v1/widgets`
- `GET /health`

## Supported pages in benchmarks

- `playbook-liquidity` / `dex-liquidity`
- `dex-swaps`
- `kamino`
- `exponent`
- `health`
- `global-ecosystem`
- `header-health` (always-on global header indicator endpoint)
- `header-health-proxy` (HTMX same-origin proxy endpoint used by the header indicator)

Use `--page all` to benchmark the full cross-page widget suite, including Kamino KPIs/charts/tables and modal table endpoints.

## Data sources

The API reads from SQL views/functions under `dexes/dbsql/views`, primarily:

- `get_view_tick_dist_simple`
- `get_view_dex_last`
- `get_view_dex_timeseries`
- `get_view_liquidity_depth_table`
- `get_view_dex_table_ranked_events`
