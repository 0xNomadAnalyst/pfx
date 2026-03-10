# ONyc Mid-Level ETL: Optimised Intermediate Processing

## Overview

This layer sits between the 5-second continuous aggregates (CAGGs) and the frontend-serving view functions. It pre-computes expensive operations—multi-CAGG joins, LOCF fills, snapshot computations—into materialised tables at 1-minute granularity, so that frontend queries become thin re-bucketing reads instead of heavyweight computations.

```
src_* → cagg_*_5s → mat_*_1m / mat_*_last / mat_*_config → get_view_*()
                         ↑                                       ↑
                   this layer                            frontend-views/
```

## Key Design Decisions

### 1-Minute Materialised Grain

All timeseries materialised tables (`mat_*_timeseries_1m`) store data at 1-minute buckets. This single grain supports every frontend time-range/aggregation pair through re-bucketing at query time:

| Frontend Range | Aggregation | Re-bucket from 1m |
|:--------------:|:-----------:|:------------------:|
| 2H             | 2 min       | 2 buckets          |
| 4H             | 5 min       | 5 buckets          |
| 1D             | 30 min      | 30 buckets         |
| 7D             | 3 hours     | 180 buckets        |
| 30D            | 12 hours    | 720 buckets        |
| 90D            | 1 day       | 1440 buckets       |

This avoids maintaining 6 separate materialisation levels and keeps storage bounded while still delivering sub-100ms frontend response times for all ranges.

### Narrowed CAGG Refresh Window

The CAGG refresh trailing window is narrowed from 2 hours (in the USX/eUSX pipeline) to 30 minutes. Since ingestion latency is typically under 30 seconds, a 30-minute window provides ~60x safety margin while scanning 75% less data per refresh cycle.

### Uniform Hot-Path Refresh Cadence

All materialised tables across all domains refresh at the same configurable cadence (default: 30 seconds). This ensures consistent data freshness across the dashboard during market stress events, when variable staleness between domains would be unacceptable for a real-time risk monitoring tool. The cadence is configurable via `MAT_REFRESH_INTERVAL_S`.

### `refreshed_at` Columns

Every materialised table includes a `refreshed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()` column, enabling operational monitoring of data staleness and alerting on refresh failures.

### Views Unchanged Where Not Worth Materialising

Point-in-time views, distribution analyses, and ranked-event tables that operate on raw event data with small result sets remain as direct CAGG/source reads. Materialising them would add refresh overhead without meaningful latency improvement.

## Domain Details

### Dexes (`mid-level-tables/dexes/`)

**Problem**: `get_view_dex_timeseries` joined 4 CAGGs (events, poolstate, vaults, tickarrays) with LOCF fill across all columns at query time (~1380 lines). `get_view_dex_last` ran a similar ~580-line computation per request.

**Solution**:
- **`mat_dex_timeseries_1m`**: Pre-joins all 4 CAGGs at 1-minute grain with LOCF applied during refresh. Seeding window extends 5 minutes before the refresh boundary to ensure LOCF has seed values.
- **`mat_dex_ohlcv_1m`**: Pre-computes OHLCV candles from `cagg_events_5s` at 1-minute grain.
- **`mat_dex_last`**: Snapshot table with latest state per pool, refreshed by calling the original heavy view logic and caching the result.

**Unchanged views** (remain on CAGG/source reads):
- `get_view_tick_dist_simple` — tick distribution analysis
- `get_view_dex_table_ranked_events` — ranked event table
- `get_view_sell_swaps_distribution` — swap distribution analysis
- `get_view_sell_pressure_t0_distribution` — sell pressure distribution
- `get_view_liquidity_depth_table` — liquidity depth table

### Kamino Lending (`mid-level-tables/kamino/`)

**Problem**: `get_view_klend_timeseries` used LATERAL joins on source tables with hardcoded reserve addresses for USX/eUSX. `v_last` and `v_config` ran ~600 and ~300 lines of DISTINCT ON subqueries respectively.

**Solution**:
- **`mat_klend_reserve_ts_1m`**: Stores reserve metrics in a flat format (one row per reserve per bucket) using generic `reserve_address` and `symbol` columns instead of hardcoded tokens.
- **`mat_klend_obligation_ts_1m`**: Obligation aggregate metrics at 1-minute grain.
- **`mat_klend_activity_ts_1m`**: Market activity metrics at 1-minute grain.
- **`mat_klend_last_reserves` / `mat_klend_last_obligations` / `mat_klend_last_activities`**: Snapshot tables for latest state per reserve/market.
- **`mat_klend_config` / `mat_klend_config_market`**: Pre-computed configuration snapshots.

**Dynamic pivoting**: The rewritten view functions (`get_view_klend_timeseries`, `v_last`, `v_config`) dynamically look up `aux_market_reserve_tokens` to determine which reserves map to borrow1/borrow2/collateral1 slots, then pivot the flat materialised data to match the expected output schema. This makes the pipeline fully token-agnostic—no hardcoded addresses.

**Unchanged views**:
- `v_rate_curve` — interest rate curve
- `v_market_assets` — market asset listing
- `get_view_klend_obligations` — obligation details
- `get_view_klend_sensitivities` — sensitivity analysis

### Exponent (`mid-level-tables/exponent/`)

**Problem**: `get_view_exponent_timeseries` joined 5+ CAGGs via LATERAL joins (~870 lines). `get_view_exponent_last` used ~40 CTEs across 8+ source tables (~1860 lines), including trailing APY calculations, AMM impact function calls, and SY supply analytics.

**Solution**:
- **`mat_exp_timeseries_1m`**: Pre-joins vault, market, SY meta, YT escrow, and transaction event CAGGs at 1-minute grain with LOCF. Looped per vault to handle multi-market scenarios.
- **`mat_exp_last`**: One row per vault with pre-computed metrics (vault state, market pricing, pool depth, YT staking, trailing APYs, 24h volume). Eliminates ~30 DISTINCT ON subqueries.

**Retained live computations** (in `get_view_exponent_last`):
- AMM price/yield impact — requires live domain function calls (`get_amm_price_impact`, `get_amm_yield_impact`)
- SY supply analytics — requires live `src_sy_token_account` data
- Base token escrow / collateralization — requires live `src_base_token_escrow` data
- Array columns spanning all vaults — dynamic assembly from `aux_key_relations`

### System Health (`mid-level-tables/health/`)

**Problem**: The health monitoring page runs expensive live queries on every request:
- `v_health_queue_table` computes `PERCENTILE_CONT(0.95)` over 7 days of queue_health data per schema (3 separate scans of large time-series tables).
- `v_health_trigger_table` scans 7 days of `dexes.src_tx_events` (potentially millions of swap rows) with FILTER aggregation.
- `v_health_base_table` loops over 21 base tables, running `MAX()` + `COUNT()` + `COUNT(DISTINCT time_bucket)` on each — 63+ individual queries per request.
- `v_health_cagg_table` loops over 15 CAGG/source pairs with `MAX()` + `COUNT(DISTINCT)` on each — 45 individual queries per request.
- `v_health_base_chart` scans multiple base tables per schema for hourly row counts.

**Solution**:
- **`mat_health_queue_benchmarks`**: Pre-computes 7-day P95 benchmarks (staleness, utilization, failures) per domain/queue. Eliminates PERCENTILE_CONT scans.
- **`mat_health_trigger_stats`**: Pre-computes trigger function health metrics (7-day MAX timestamps + 1-hour row counts) from `src_tx_events`. Eliminates the full 7-day swap scan.
- **`mat_health_base_activity`**: Pre-computes per-table stats (latest_time, rows_last_hour, rows_last_24h, sample_count, expected_gap). Replaces 63+ live queries with a single table read.
- **`mat_health_cagg_status`**: Pre-computes per-CAGG stats (cagg_latest, source_latest, refresh_lag, expected_gap). Replaces 45 live queries with a single table read.
- **`mat_health_base_hourly`**: Pre-aggregated hourly row counts per base table (hypertable with 8-day retention). Supports `v_health_base_chart` without multi-table scans.
- **`refresh_mat_health_all()`**: Unified procedure calling all five sub-procedures in dependency order.

**Unchanged views**:
- `v_health_master_table` — thin aggregator over the other 4 health views (now all fast)
- `v_health_queue_chart` — already optimised with schema-specific branches on compact queue_health tables

### Cross-Protocol (`mid-level-tables/cross-protocol/`)

**Problem**: The global ecosystem page in the USX/eUSX pipeline used `v_prop_last` (~1180 lines) and `get_view_prop_timeseries` (~1800+ lines), which each performed 20+ `DISTINCT ON` subqueries across 5 schemas (solstice proprietary, dexes, kamino, exponent, pyth). The ONyc pipeline has no Solstice proprietary programs, but still needs to understand ONyc token distribution and activity across the three monitored protocols (DEXes, Kamino, Exponent). Without materialisation, this would require live multi-schema joins on every request.

**Solution**:
- **`mat_xp_ts_1m`** (schema: `cross_protocol`): Pre-computes 1-minute timeseries combining:
  - **TVL tracking**: ONyc reserves in DEX pools (from `mat_dex_timeseries_1m` + `pool_tokens_reference`), ONyc in Kamino lending (from `mat_klend_reserve_ts_1m` + `aux_market_reserve_tokens`), ONyc in Exponent escrow (from `cagg_base_token_escrow_5s`). TVL percentages derived per bucket.
  - **Activity flows**: DEX swap/LP volumes (ONyc-side), Kamino deposit/withdraw/borrow/repay/liquidate volumes (ONyc reserves), Exponent PT trading + LP flows (summed across all vaults). Cross-protocol totals and percentage shares.
  - **Yields**: Kamino supply APY for ONyc reserves, Exponent depth-weighted implied APY across active markets.
- **`mat_xp_last`**: Singleton snapshot with latest TVL distribution, current yields, DEX price, and Kamino market risk summary. Eliminates the need for live multi-schema `DISTINCT ON` scans.
- **`refresh_mat_xp_all()`**: Unified procedure calling both sub-procedures; placed last in the Tier 1 hot-path since it depends on domain mat tables having been refreshed first.

**Key design choice**: Reads from already-materialised domain tables (`mat_dex_*`, `mat_klend_*`, `mat_exp_*`) rather than raw CAGGs, leveraging the pre-computed LOCF and decimal adjustment. Only the Exponent base token escrow is read from the 5s CAGG directly (no domain mat table covers this field at the cross-protocol level).

**Frontend views**:
- `v_xp_last` — thin view over `mat_xp_last` with APY/utilization formatted as percentages
- `get_view_xp_timeseries(bucket_interval, from_ts, to_ts)` — re-buckets from `mat_xp_ts_1m`; TVL uses LAST, activity uses SUM, yields use LAST
- `get_view_xp_activity(interval_literal)` — single-row aggregation of activity flows over a given interval with percentage breakdown (serves pie-chart widgets)

## File Layout

```
pfx/dbsql/
├── mid-level-tables/
│   ├── dexes/
│   │   ├── cagg_events_5s.sql           (copied from existing)
│   │   ├── cagg_poolstate_5s.sql        (copied from existing)
│   │   ├── cagg_vaults_5s.sql           (copied from existing)
│   │   ├── cagg_tickarrays_5s.sql       (copied from existing)
│   │   ├── aux_pool_tokens_reference.sql (copied from existing)
│   │   ├── mat_dex_timeseries_1m.sql    (NEW: table + refresh procedure)
│   │   ├── mat_dex_ohlcv_1m.sql         (NEW: table + refresh procedure)
│   │   └── mat_dex_last.sql             (NEW: table + refresh procedure)
│   ├── kamino/
│   │   ├── cagg_reserves_5s.sql         (copied from existing)
│   │   ├── cagg_obligations_agg_5s.sql  (copied from existing)
│   │   ├── cagg_activities_5s.sql       (copied from existing)
│   │   ├── aux_market_reserve_tokens.sql (copied from existing)
│   │   ├── mat_klend_timeseries_1m.sql  (NEW: 3 sub-tables + refresh)
│   │   ├── mat_klend_last.sql           (NEW: 3 sub-tables + refresh)
│   │   └── mat_klend_config.sql         (NEW: 2 tables + refresh)
│   └── exponent/
│       ├── cagg_vaults_5s.sql           (copied from existing)
│       ├── cagg_market_twos_5s.sql      (copied from existing)
│       ├── cagg_sy_meta_account_5s.sql  (copied from existing)
│       ├── cagg_tx_events_5s.sql        (copied from existing)
│       ├── cagg_vault_yt_escrow_5s.sql  (copied from existing)
│       ├── cagg_sy_token_account_5s.sql (copied from existing)
│       ├── cagg_base_token_escrow_5s.sql (copied from existing)
│       ├── cagg_vault_yield_position_5s.sql (copied from existing)
│       ├── aux_key_relations.sql        (copied from existing)
│       ├── mat_exp_timeseries_1m.sql    (NEW: table + refresh procedure)
│       └── mat_exp_last.sql             (NEW: table + refresh procedure)
│   ├── health/
│   │   ├── deploy_health_indexes.sql    (indexes for health queries)
│   │   ├── mat_health_queue_benchmarks.sql (NEW: P95 benchmarks)
│   │   ├── mat_health_trigger_stats.sql (NEW: trigger health stats)
│   │   ├── mat_health_base_activity.sql (NEW: base table activity)
│   │   ├── mat_health_cagg_status.sql   (NEW: CAGG refresh status)
│   │   ├── mat_health_base_hourly.sql   (NEW: hourly row counts, hypertable)
│   │   └── refresh_mat_health_all.sql   (NEW: unified refresh procedure)
│   └── cross-protocol/
│       ├── mat_xp_ts_1m.sql             (NEW: cross-protocol timeseries, hypertable)
│       ├── mat_xp_last.sql              (NEW: cross-protocol snapshot)
│       └── refresh_mat_xp_all.sql       (NEW: unified refresh procedure)
├── frontend-views/
│   ├── dexes/    (8 view functions: 3 rewritten, 5 unchanged)
│   ├── kamino/   (7 view functions: 3 rewritten, 4 unchanged)
│   ├── exponent/ (2 view functions: both rewritten)
│   ├── health/   (7 view functions: 5 rewritten, 2 unchanged)
│   └── cross-protocol/ (3 view functions: 1 view, 2 functions)
└── cronjobs/
    └── onyc_refresh.sh   (tiered refresh orchestration)
```

## Refresh Architecture

| Tier | What                          | Cadence                        | Configurable Via           |
|:----:|-------------------------------|--------------------------------|----------------------------|
| 1    | 15 CAGGs + 8 domain mat tables + 5 health mat tables + 2 cross-protocol mat tables | Every cycle (default 30s) | `MAT_REFRESH_INTERVAL_S` |
| 2    | Aux/discovery tables          | Every 10 cycles (~5 min)       | `AUX_REFRESH_MULT`        |
| 3    | Health check + stats          | Every 60 cycles (~30 min)      | `HEALTH_CHECK_MULT`       |
| Daily| Retention cleanup + VACUUM    | Midnight UTC                   | `MAT_RETENTION_DAYS`      |

## Expected Performance Gains (Summary)

Quick-reference per-view speedup estimates. For detailed quantitative analysis including row counts, I/O budgets, and amortisation modelling, see [Computational Intensity Analysis](#computational-intensity-analysis) below.

| View Function                    | Original Cost                    | New Cost                     | Estimated Speedup |
|:---------------------------------|:---------------------------------|:-----------------------------|:-----------------:|
| `get_view_dex_timeseries`        | 4-CAGG join + LOCF (1380 lines) | Single-table re-bucket       | 10–50x            |
| `get_view_dex_last`              | Full computation (579 lines)     | Direct table read             | 50–100x           |
| `get_view_dex_ohlcv`            | CAGG aggregation (127 lines)     | Single-table re-bucket       | 5–10x             |
| `get_view_klend_timeseries`      | LATERAL joins on src_* tables    | Flat-table pivot + re-bucket | 10–50x            |
| `v_last` (Kamino)               | ~600 lines DISTINCT ON           | Snapshot read + pivot         | 50–100x           |
| `v_config` (Kamino)             | ~300 lines DISTINCT ON           | Snapshot read + pivot         | 20–50x            |
| `get_view_exponent_timeseries`   | 5+ LATERAL joins (873 lines)     | Single-table re-bucket       | 10–50x            |
| `get_view_exponent_last`         | ~40 CTEs, 8+ sources (1863 lines)| Mat read + live AMM calls    | 5–20x             |
| `v_health_queue_table`           | 3x PERCENTILE_CONT over 7d       | Mat table lookup + severity  | 10–30x            |
| `v_health_trigger_table`         | 7-day src_tx_events scan          | Mat table read               | 50–200x           |
| `v_health_base_table`            | 63+ live queries across 21 tables | Single mat table read        | 50–100x           |
| `v_health_cagg_table`            | 45 live queries across 15 pairs   | Single mat table read        | 30–60x            |
| `v_health_base_chart`            | Multi-table scans per schema      | Pre-aggregated hourly read   | 10–30x            |
| `v_xp_last`                     | Multi-schema DISTINCT ON (≈v_prop_last) | Singleton table read    | 50–100x           |
| `get_view_xp_timeseries`        | Multi-schema LATERAL joins        | Single-table re-bucket       | 10–50x            |
| `get_view_xp_activity`          | Multi-schema event aggregation    | Single-table interval SUM    | 10–30x            |

## Domain Function Dependencies

The following domain functions are called by frontend views or the refresh cronjob and must be deployed to the ONyc database.

### Exponent (required for `get_view_exponent_last`)

| Function | Source File | Purpose |
|----------|-------------|---------|
| `exponent.get_amm_price_impact` | `exponent/dbsql/functions/get_amm_price_impact.sql` | PT buy price impact (%) via Pendle V2 Notional AMM model |
| `exponent.get_amm_yield_impact` | `exponent/dbsql/functions/get_amm_yield_impact.sql` | Maps price impact to implied APY change; wraps `get_amm_price_impact` |

### Dexes (required for unchanged views)

| Function | Source File | Called By |
|----------|-------------|-----------|
| `dexes.impact_bps_from_qsell_latest` | `dexes/dbsql/functions/impact_bps_from_qsell_latest.sql` | `get_view_sell_swaps_distribution`, `get_view_sell_pressure_t0_distribution` |
| `dexes.impact_qsell_from_bps_latest` | `dexes/dbsql/functions/impact_qsell_from_bps_latest.sql` | `get_view_liquidity_depth_table` |
| `dexes.get_tick_float_from_sqrtPriceXQQ` | `dexes/dbsql/functions/get_tick_float_from_sqrtPriceXQQ.sql` | `get_view_tick_dist_simple` |
| `dexes.get_price_from_tick` | `dexes/dbsql/functions/get_price_from_tick.sql` | `get_view_tick_dist_simple` |

### Kamino Lending (required for unchanged views)

| Function | Source File | Called By |
|----------|-------------|-----------|
| `kamino_lend.rate_curve_all` | `kamino/dbsql/functions/rate_curve_all.sql` | `v_rate_curve` |
| `kamino_lend.rate_curve_up` | `kamino/dbsql/functions/rate_curve_up.sql` | `rate_curve_all` (indirect) |
| `kamino_lend.rate_curve_down` | `kamino/dbsql/functions/rate_curve_down.sql` | `rate_curve_all` (indirect) |
| `kamino_lend.sensitize_deposit_value` | `kamino/dbsql/functions/sensitize_deposit_value.sql` | `get_view_klend_sensitivities` |
| `kamino_lend.sensitize_borrow_value` | `kamino/dbsql/functions/sensitize_borrow_value.sql` | `get_view_klend_sensitivities` |
| `kamino_lend.sensitize_ltv` | `kamino/dbsql/functions/sensitize_ltv.sql` | `get_view_klend_sensitivities` |
| `kamino_lend.is_unhealthy_from_values` | `kamino/dbsql/functions/is_unhealthy_from_values.sql` | `get_view_klend_sensitivities` |
| `kamino_lend.is_bad_from_values` | `kamino/dbsql/functions/is_bad_from_values.sql` | `get_view_klend_sensitivities` |
| `kamino_lend.calculate_health_factor_array` | `kamino/dbsql/functions/calculate_health_factor_array.sql` | `get_view_klend_sensitivities` |
| `kamino_lend.sensitize_liquidation_distance` | `kamino/dbsql/functions/sensitize_liquidation_distance.sql` | `get_view_klend_sensitivities` |
| `kamino_lend.sum_array_elementwise` | `kamino/dbsql/functions/sum_array_elementwise.sql` | `get_view_klend_sensitivities` |
| `kamino_lend.average_array_elementwise` | `kamino/dbsql/functions/average_array_elementwise.sql` | `get_view_klend_sensitivities` |

### Cron-only (optional, deploy if feature needed)

| Function | Source File | Purpose |
|----------|-------------|---------|
| `dexes.refresh_risk_pvalues` | `dexes/dbsql/risk/risk_pvalues_refresh.sql` | Daily percentile stats for risk p-values |
| `dexes.discover_mm_proxy_addresses` | `dexes/dbsql/functions/discover_mm_proxy_addresses.sql` | Hourly MM proxy/delegate address discovery |

## Computational Intensity Analysis

This section quantifies the expected improvements in DB compute cost and frontend latency, comparing the new optimised architecture against the baseline pattern used in the USX/eUSX pipeline.

### 1. CAGG Refresh: Row Volume Reduction

Each CAGG refresh scans a trailing window of 5-second hypertable chunks and re-materialises them. The dominant cost is I/O — reading and aggregating raw 5s rows.

| Parameter                | USX/eUSX Baseline | ONyc Optimised | Reduction |
|--------------------------|------------------:|---------------:|:---------:|
| Refresh window           | 2 hours           | 30 minutes     | 75%       |
| 5s buckets per CAGG/cycle| 1,440             | 360            | 75%       |
| CAGG count               | 21                | 15             | 29%       |
| Total bucket-rows/cycle  | 30,240            | 5,400          | 82%       |
| Cycle interval           | 5 seconds         | 30 seconds     | 6x slower |
| Sustained bucket-rows/s  | 6,048             | 180            | **97%**   |

The 30-minute window provides a ~60x safety margin over typical ingestion latency (<30s), while eliminating three quarters of the I/O per refresh. Combined with the 6x lower cycle frequency (justified by the mat layer absorbing the freshness requirement), sustained CAGG refresh throughput drops by **97%**.

### 2. Join Elimination at Query Time

The heaviest per-request cost in the old pattern is multi-table joins. These are eliminated entirely for the hot-path views.

| View Function | Original Joins | Original Join Rows (2H range) | New: Tables Read | New: Rows Read (2H) | Reduction |
|:---|:---:|---:|:---:|---:|:---:|
| `get_view_dex_timeseries` | 4-way (events + poolstate + vaults + tickarrays) | 4 * 1,440 = **5,760** | 1 (mat_dex_timeseries_1m) | **120** | 48x |
| `get_view_exponent_timeseries` | 14 LATERAL joins across 5+ CAGGs | ~7,200+ | 1 (mat_exp_timeseries_1m) | **120** | 60x |
| `get_view_klend_timeseries` | 8 LATERAL joins on src_* tables | Unbounded (raw tables) | 3 flat mat tables | ~120 per table | N/A (src scan eliminated) |

For longer ranges the absolute numbers scale but the ratio holds constant because both sides grow at the same rate (12:1 for 5s-to-1m bucket density):

| FE Range | 5s Rows/CAGG | 1m Rows in mat | Density Ratio |
|:--------:|-------------:|---------------:|:-------------:|
| 2H       | 1,440        | 120            | 12x           |
| 4H       | 2,880        | 240            | 12x           |
| 1D       | 17,280       | 1,440          | 12x           |
| 7D       | 120,960      | 10,080         | 12x           |
| 30D      | 518,400      | 43,200         | 12x           |
| 90D      | 1,555,200    | 129,600        | 12x           |

However, the effective improvement is multiplicative: 12x fewer rows **and** the join is eliminated (single-table scan vs multi-table hash/merge join). For the 4-CAGG dex join, this means the query planner goes from coordinating 4 sorted merge inputs of 1,440 rows each to scanning 120 rows from one table — an effective **48x** reduction in rows touched, plus elimination of all join CPU overhead.

### 3. Window Function (LOCF) Elimination

Last-observation-carried-forward (LOCF) requires `LAST(value, time) OVER (PARTITION BY ... ORDER BY time ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` window functions across every state column. In the original dex timeseries view:

- **41 window function evaluations** per query (one per LOCF'd column)
- Each requires a full ordered pass over the partition

In the new architecture, LOCF is applied once during the mat table refresh procedure. Frontend queries see pre-filled values and execute **zero window functions**. The saving scales with the number of columns and the partition size:

| View | LOCF Window Functions (Original) | Window Functions (New) | Saving |
|:---|:---:|:---:|:---:|
| `get_view_dex_timeseries` | 41 | 0 | 100% |
| `get_view_exponent_timeseries` | 5 | 0 | 100% |
| `get_view_klend_timeseries` | N/A (LATERAL on src) | 0 | N/A |

For the dex case with a 2H range, this eliminates 41 sorted window passes over 5,760 joined rows (after 4-CAGG join), replacing them with a simple `GROUP BY time_bucket()` over 120 pre-joined, pre-LOCF'd rows.

### 4. DISTINCT ON / Snapshot Subquery Elimination

The "last" views use `DISTINCT ON (key) ... ORDER BY block_time DESC` subqueries to find the latest row per entity from raw source tables. Each subquery requires a full index scan or sort.

| View | DISTINCT ON Subqueries (Original) | Source Tables Scanned | New Approach | Subqueries (New) |
|:---|:---:|:---:|:---|:---:|
| `get_view_exponent_last` | 14 | 8+ (src_vaults, src_market_twos, src_sy_meta_account, src_vault_yt_escrow, etc.) | PK lookup on mat_exp_last (1–2 rows) | 0 |
| `v_last` (Kamino) | 2+ | src_reserves, src_obligations, src_lending_market | Snapshot table reads (mat_klend_last_*) | 0 |
| `v_config` (Kamino) | 2+ | src_reserves, src_lending_market | Snapshot table read (mat_klend_config) | 0 |
| `get_view_dex_last` | 0 (uses view call) | 4 CAGGs via get_view_dex_timeseries | Direct table read (mat_dex_last) | 0 |

The `get_view_exponent_last` view additionally constructs **43 CTEs**, many of which exist solely to feed cross-CTE scalar subselects. The rewritten version replaces these with 2 row lookups from `mat_exp_last` plus a reduced set of live CTEs for data that cannot be pre-computed (SY supply, escrow balances, AMM impact functions).

### 5. Per-Request to Per-Refresh Cost Amortisation

This is the single largest compute reduction mechanism. In the old architecture, every frontend request re-executes the full join/LOCF/DISTINCT ON computation. In the new architecture, this heavy work runs once per refresh cycle and is shared across all concurrent requests.

Let `C` = cost of one full computation for a hot-path view, and `c` = cost of a thin read from a mat table.

From the join/LOCF/row-count analysis above, the thin read is estimated at **C/20 to C/50** depending on the view (single-table scan of 12x fewer rows, no joins, no window functions).

| Scenario | Old: Cost per 30s | New: Cost per 30s | Reduction |
|:---|---:|---:|:---:|
| 1 session, 3 views/refresh, 10s refresh | 9C | 1C + 9 * C/30 = **1.3C** | 7x |
| 5 sessions, 3 views each, 10s refresh | 45C | 1C + 45 * C/30 = **2.5C** | 18x |
| 10 sessions, 3 views each, 10s refresh | 90C | 1C + 90 * C/30 = **4.0C** | 22x |
| 20 sessions (stress test) | 180C | 1C + 180 * C/30 = **7.0C** | 26x |

The amortisation benefit increases with concurrency: at 10 concurrent sessions the effective per-request compute drops by **~22x** because the expensive refresh is shared. At 1 session the benefit is still significant (~7x) because the thin read itself is much cheaper.

### 6. CAGG Refresh I/O Budget

Comparing the total I/O budget between running the old pattern for ONyc vs the optimised pipeline:

| Component | Old Pattern (per hour) | New Pattern (per hour) | Ratio |
|:---|---:|---:|:---:|
| CAGG refresh cycles | 720 (every 5s) | 120 (every 30s) | 6x fewer |
| Bucket-rows scanned per cycle | 21,600 | 5,400 | 4x fewer |
| **Total CAGG bucket-rows/hour** | **15,552,000** | **648,000** | **24x fewer** |
| Mat table refresh cycles | 0 | 120 | (new cost) |
| Mat refresh rows written/cycle | 0 | ~2,000 est. | (new cost) |
| **Mat table rows written/hour** | **0** | **~240,000** | (new cost) |
| **Net I/O budget** | **15.6M rows/hour** | **~888K rows/hour** | **~18x reduction** |

The mat table refresh introduces new write I/O (~240K rows/hour), but this is dwarfed by the 15M row/hour CAGG scan reduction. The net I/O budget drops by approximately **18x**.

### 7. Frontend Query Latency Estimates

Based on the row counts and operation complexity:

| View Function | Old Estimated p95 | New Estimated p95 | Improvement |
|:---|---:|---:|:---:|
| `get_view_dex_timeseries` (2H/2min) | 500–2,000ms | 10–50ms | 10–40x |
| `get_view_dex_timeseries` (90D/1d) | 2,000–10,000ms | 50–200ms | 20–50x |
| `get_view_dex_last` | 500–2,000ms | 1–5ms | 100–400x |
| `get_view_dex_ohlcv` (7D/3h) | 200–500ms | 20–50ms | 5–10x |
| `get_view_klend_timeseries` (2H/2min) | 1,000–5,000ms | 20–80ms | 12–60x |
| `v_last` (Kamino) | 500–2,000ms | 5–20ms | 25–100x |
| `v_config` (Kamino) | 200–500ms | 2–10ms | 20–50x |
| `get_view_exponent_timeseries` (2H/2min) | 1,000–5,000ms | 10–50ms | 20–100x |
| `get_view_exponent_last` | 2,000–8,000ms | 200–800ms | 5–10x |

Note: `get_view_exponent_last` retains live AMM impact function calls and SY supply lookups, limiting the improvement to 5–10x rather than the 50–100x seen for fully pre-computed snapshot views. The AMM functions themselves involve mathematical computation over market state and are inherently per-request.

### 8. Total System Compute Summary

Combining all improvements across the three cost dimensions:

| Cost Dimension | Mechanism | Estimated Reduction |
|:---|:---|:---:|
| CAGG refresh I/O | Narrowed window (2h → 30m) + lower frequency (5s → 30s) | 18–24x |
| Per-request query CPU | Join elimination + LOCF pre-computation + single-table reads | 10–50x per call |
| Aggregate frontend load | Per-refresh amortisation across N sessions | 7–26x (scales with N) |
| Hot-path view latency | All of the above | 5–400x depending on view |

For a typical deployment with 3–5 concurrent dashboard sessions, the expected reduction in total DB CPU attributable to frontend-serving workload is **70–90%**, with the heaviest views (dex timeseries, exponent timeseries) seeing the largest absolute savings.

The remaining compute budget is dominated by:
1. Mat table refresh procedures (~10% of old baseline)
2. CAGG refresh (~4% of old baseline)
3. Unchanged views (tick dist, ranked events, distributions) — these were never the dominant cost
4. Live domain function calls (AMM impact) — irreducible per-request cost

### 9. Cross-Protocol Layer Cost

The cross-protocol layer (`mat_xp_ts_1m`, `mat_xp_last`) adds marginal cost since it reads from already-materialised domain tables rather than raw CAGGs:

| Component | Cost per Refresh Cycle |
|:---|---:|
| `refresh_mat_xp_ts_1m` — reads ~30 rows from 3 domain mat tables + 1 CAGG, writes ~30 rows | ~50ms |
| `refresh_mat_xp_last` — reads latest row from 5 domain mat/CAGG sources, writes 1 row | ~20ms |
| **Total cross-protocol refresh** | **~70ms/cycle** |

Without materialisation, the equivalent cross-protocol queries would require 5+ multi-schema joins on every frontend request. Estimated live query cost: 500–3,000ms. With materialisation: 1–50ms (depending on view and bucket range), yielding **10–100x improvement** for the cross-protocol page.

## Validation Checklist

For each migrated view function:

- [ ] Schema parity: output column names, types, and order match original
- [ ] Bucket boundary parity: for all FE ranges (2H/2min, 4H/5min, 1D/30min, 7D/3h, 30D/12h, 90D/1d), row counts and boundary timestamps match
- [ ] Value parity: numeric values within acceptable tolerance (LOCF edge differences permitted at boundaries)
- [ ] p95 latency improvement confirmed
- [ ] Refresh runtime within ops budget (< 10s per cycle target)
- [ ] `refreshed_at` staleness monitored and within SLA (< 60s for hot-path)
