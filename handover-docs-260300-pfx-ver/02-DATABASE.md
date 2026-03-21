# In-Database ETL and Schema Design

This document covers the database-side processing that transforms raw ingested data into queryable analytics. All SQL definitions live in `<service>/dbsql/` directories and are richly self-documented -- the SQL files themselves are the authoritative schema reference. This document provides the high-level architecture and shared patterns.

The database is built on TimescaleDB (hosted on Timescale Cloud). Further details on the hosting platform and service dependencies will be covered in **05-DEPENDENCIES.md**.

Related companion documents:

- **01-INGESTION.md** -- Python ingestion services that write to the source tables described here.
- **04-RESILIENCE.md** -- operational monitoring, health checks, queue health telemetry.
- **05-DEPENDENCIES.md** -- external service/API dependencies, database hosting, credentials.

---

## Schema Isolation

Each protocol domain writes to its own PostgreSQL schema, isolating table namespaces, permissions, and enabling independent test deployments:

| Schema | Domain | Source Directory |
|---|---|---|
| `dexes` | Orca Whirlpool, Raydium CLMM | `dexes/dbsql/` |
| `exponent` | Exponent PT/YT yield markets | `exponent/dbsql/` |
| `kamino_lend` | Kamino Lending | `kamino/dbsql/` |
| `solstice_proprietary` | Solstice USX / eUSX | `solstice-prop/dbsql/` |
| `health` | Cross-domain health monitoring | `health/dbsql/` |

The `src_test/` subdirectory within each service's `dbsql/` folder contains duplicated DDL scripts used to deploy identical table structures to isolated test schemas (e.g. `dexes_test`). These are not production artifacts.

---

## Processing Pipeline Overview

Data flows through a consistent multi-layer pipeline within the database. Each layer builds on the one below it:

```
Ingestion Services (Python)
        │
        ▼
┌─────────────────────────────────────────────────┐
│  Layer 1: Source Tables (src_*)                  │
│  Raw ingested data, one table per account type   │
│  + transaction/event tables                      │
│  TimescaleDB hypertables with time partitioning  │
└───────────────────┬─────────────────────────────┘
                    │
        ┌───────────┼───────────┐
        ▼           ▼           ▼
┌──────────┐ ┌───────────┐ ┌──────────┐
│ Auxiliary │ │ Triggers  │ │ Latest   │
│ Tables   │ │ (DEXes)   │ │ Tables   │
│ (aux_*)  │ │           │ │ (*_last) │
└──────────┘ └───────────┘ └──────────┘
        │           │
        ▼           ▼
┌─────────────────────────────────────────────────┐
│  Layer 2: Continuous Aggregates (cagg_*_5s)      │
│  5-second bucketed materialized views            │
│  Each CAGG reads from exactly one source table   │
│  Externally refreshed every 5 seconds            │
└───────────────────┬─────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────┐
│  Layer 3: View Functions                         │
│  Non-materialized, parameterized SQL functions   │
│  Combine data from CAGGs + aux tables            │
│  Serve the frontend via flexible time/grain/     │
│  filter parameters                               │
└───────────────────┬─────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────┐
│  Supporting Layers                               │
│  Domain functions (risk, sensitivity, pricing)   │
│  Risk policy tables, statistical distributions   │
│  Queue health monitoring tables                  │
└─────────────────────────────────────────────────┘
```

---

## Layer 1: Source Tables (`src_*`)

Source tables receive raw ingested data from the Python services. Each on-chain account type gets its own table, and transaction/event data is stored separately.

### Conventions

- **TimescaleDB hypertables** -- all `src_*` time-series tables are converted to hypertables partitioned on a time column (`time`, `block_time`, or `meta_block_time`), enabling chunk-level optimisations.
- **Chunk intervals** -- tuned per table based on write volume (e.g. 1-hour chunks for high-frequency pool state, 1-day chunks for transaction events, TimescaleDB defaults for lower-frequency account snapshots).
- **Composite primary keys** -- typically `(time_column, entity_identifier)` to enforce uniqueness per snapshot.
- **Column naming** -- original IDL fields use `snake_case` (direct conversion from `camelCase`). Calculated/derived fields are prefixed with `c_` to distinguish them from raw on-chain data.
- **Inline documentation** -- every table and most columns carry `COMMENT ON` annotations explaining data source, units, and scaling conventions.
- **Decimal handling** -- raw on-chain values (u64/u128) are stored alongside or instead of decimal-adjusted values. Scaled fraction fields (Kamino's `_sf` convention, dividing by 2^60) are documented per column.

### Source Tables by Domain

**DEXes** (8 tables):

| Table | Content |
|---|---|
| `src_acct_pool` | Pool state snapshots (price, liquidity, ticks) |
| `src_acct_vaults` | SPL token vault reserve balances |
| `src_acct_tickarray_queries` | Tick array query results (historical) |
| `src_acct_tickarray_tokendist` | Token depth distribution per tick interval (historical) |
| `src_acct_tickarray_tokendist_latest` | Latest-only token depth (non-hypertable, upserted) |
| `src_acct_position` | LP position snapshots |
| `src_transactions` | Raw transaction records |
| `src_tx_events` | Instruction-level event records with decoded fields |

**Exponent** (9 tables):

| Table | Content |
|---|---|
| `src_vaults` | Vault state (PT/YT supply, SY escrow, exchange rates, maturity) |
| `src_market_twos` | MarketTwo AMM state (balances, implied rates, LP supply) |
| `src_vault_yield_position` | Vault robot YT position tracking |
| `src_vault_yt_escrow` | Vault YT escrow SPL token account |
| `src_sy_meta_account` | SY exchange rates, supply caps, emissions |
| `src_sy_token_account` | SY token mint supply |
| `src_base_token_escrow` | Underlying asset escrow balances |
| `src_txns` | Raw transaction records |
| `src_tx_events` | Instruction-level event records |

**Kamino** (7 tables):

| Table | Content |
|---|---|
| `src_lendingmarket` | Lending market configuration snapshots |
| `src_reserves` | Per-reserve metrics (utilization, APY, TVL, risk params) |
| `src_obligations` | Individual obligation snapshots (historical) |
| `src_obligations_last` | Latest-only obligation state (non-hypertable, upserted) |
| `src_obligations_agg` | Market-wide obligation aggregates per poll cycle |
| `src_txn` | Raw transaction records |
| `src_txn_events` | Instruction-level event records |

**Solstice Proprietary** (9 tables):

| Table | Content |
|---|---|
| `src_usx_controller` | USX protocol controller state |
| `src_usx_stabledepository` | Per-collateral depository state (solvency, oracle) |
| `src_usx_txns` / `src_usx_tx_events` | USX transaction and event records |
| `src_eusx_controller` | eUSX yield vault controller state |
| `src_eusx_yieldpool` | eUSX yield pool state (TVL, exchange rate) |
| `src_eusx_vestingschedule` | eUSX vesting schedule state |
| `src_eusx_txns` / `src_eusx_tx_events` | eUSX transaction and event records |

### Auxiliary Tables (`aux_*`)

Two auxiliary reference tables provide denormalized lookup data that CAGGs and view functions need but cannot derive inline (TimescaleDB continuous aggregates do not support CTEs, subqueries, or joins to non-hypertables at definition time):

- **`kamino_lend.aux_market_reserve_tokens`** -- maps reserve addresses to token metadata (symbol, decimals, type, risk params). Populated from `src_reserves` and `src_lendingmarket`.
- **`exponent.aux_key_relations`** -- maps vault addresses to the full related account graph (market, escrows, SY meta, token mints). Populated from `src_vaults`, `src_market_twos`, `src_sy_meta_account`, `src_base_token_escrow`.

A similar pattern exists in DEXes with `pool_tokens_reference`, which maps pool addresses to their canonical token0/token1 addresses and metadata.

These tables are refreshed by the external CAGG refresh service (see below) every ~5 minutes.

### Latest-State Tables

Two tables use a non-hypertable "latest only" pattern, maintaining a single current-state row per entity via upsert:

- **`kamino_lend.src_obligations_last`** -- one row per obligation (PK: `obligation_address`). Far smaller than the historical `src_obligations` hypertable, enabling fast analytics over current portfolio state.
- **`dexes.src_acct_tickarray_tokendist_latest`** -- one row per `(pool_address, tick_lower)`. Provides the current liquidity depth snapshot used by trigger functions and price impact calculations.

### Triggers (DEXes only)

Two `BEFORE INSERT` triggers on `dexes.src_tx_events` enrich swap event rows at write time:

- **`trg_fill_raydium_pre_price`** -- Raydium swap events only emit post-swap price. This trigger carries forward the previous event's post-price as the new event's pre-price, then calculates `evt_swap_impact_bps` from the price delta. Skips Orca events (which have native pre/post prices).
- **`trg_calculate_swap_impact`** -- calculates `c_swap_est_impact_bps` for all swap events by looking up the pool's latest liquidity depth from `src_acct_tickarray_tokendist_latest` and simulating the swap through the CLMM tick traversal. Fires `BEFORE INSERT` only (not on `UPDATE`), allowing manual overrides.

---

## Layer 2: Continuous Aggregates (`cagg_*_5s`)

TimescaleDB continuous aggregates (CAGGs) provide the primary query-time optimisation layer. They materialise aggregated data from source hypertables into 5-second time buckets.

### Design Rules

- **One source per CAGG** -- each CAGG reads from exactly one source hypertable (a TimescaleDB constraint on continuous aggregates).
- **5-second bucket size** -- all CAGGs use `time_bucket('5 seconds', ...)`, providing a uniform grain across all domains that balances query performance with time resolution.
- **Two aggregation styles**:
  - **State CAGGs** use `LAST(column, block_time)` to capture point-in-time state at the end of each bucket (pool state, reserve metrics, controller state, account balances).
  - **Event CAGGs** use `SUM`, `COUNT`, `MAX`, `AVG`, and `FILTER` to aggregate activity within each bucket (swap volumes, lending operations, mint/redeem flows).
- **Blockchain time alignment** -- CAGGs bucket on blockchain time (`block_time` or `meta_block_time`), not ingestion time, to ensure events and state align correctly for downstream joins.
- **Decimal adjustment** -- performed within the CAGG definition where possible (e.g. `/ POWER(10, decimals)`, `/ POWER(2, 60)` for scaled fractions), so downstream views receive human-readable values.
- **Indexes** -- each CAGG has targeted indexes for common access patterns (entity + time DESC, protocol + time DESC, etc.).

### CAGG Inventory (21 total)

**DEXes (4):**
- `cagg_events_5s` -- swap/LP volumes, token flows, VWAP, price impact (from `src_tx_events`)
- `cagg_poolstate_5s` -- pool state, tick crossing metrics (from `src_acct_pool`)
- `cagg_vaults_5s` -- token vault reserve balances (from `src_acct_vaults`)
- `cagg_tickarrays_5s` -- liquidity depth, concentration metrics (from `src_acct_tickarray_queries`)

**Exponent (8):**
- `cagg_vaults_5s` -- vault state, collateral, maturity, yield (from `src_vaults`)
- `cagg_market_twos_5s` -- market AMM state, implied yields (from `src_market_twos`)
- `cagg_sy_meta_account_5s` -- SY exchange rates, protocol state (from `src_sy_meta_account`)
- `cagg_sy_token_account_5s` -- SY token supply (from `src_sy_token_account`)
- `cagg_vault_yield_position_5s` -- vault robot YT positions (from `src_vault_yield_position`)
- `cagg_vault_yt_escrow_5s` -- vault YT escrow balances (from `src_vault_yt_escrow`)
- `cagg_base_token_escrow_5s` -- backing asset reserves (from `src_base_token_escrow`)
- `cagg_tx_events_5s` -- economic events: strip/merge, PT trading (from `src_tx_events`)

**Kamino (3):**
- `cagg_reserves_5s` -- reserve supply, utilization, APY, TVL, risk params (from `src_reserves`)
- `cagg_obligations_agg_5s` -- market-wide obligation statistics (from `src_obligations_agg`)
- `cagg_activities_5s` -- lending instruction events (from `src_txn_events`)

**Solstice (6):**
- `cagg_usx_controller_5s` -- USX protocol state and supply (from `src_usx_controller`)
- `cagg_usx_stabledepository_5s` -- collateral management, solvency (from `src_usx_stabledepository`)
- `cagg_usx_events_5s` -- mint/redeem/collateral event flows (from `src_usx_tx_events`)
- `cagg_eusx_controller_5s` -- eUSX controller state (from `src_eusx_controller`)
- `cagg_eusx_yieldpool_5s` -- eUSX yield pool TVL and supply (from `src_eusx_yieldpool`)
- `cagg_eusx_events_5s` -- lock/unlock/withdraw/yield events (from `src_eusx_tx_events`)

### External Refresh Service

TimescaleDB's built-in CAGG refresh policies were found to be unreliable early in development (silent stalls, skipped windows). All 21 CAGGs and 2 auxiliary tables are instead refreshed by an external service:

- **Location:** `cronjobs/cagg_refresh/railway_cagg_refresh.sh`
- **Platform:** Deployed on Railway as a continuous container.
- **Cycle:** Every 5 seconds, refreshing a 2-hour trailing window (to 10 seconds ago).
- **Parallelism:** CAGGs are refreshed in 4 concurrent `psql` sessions (one per domain: dexes, kamino, exponent, solstice). Wall-clock time equals the slowest domain, not the sum.
- **Auxiliary tables:** Refreshed every ~5 minutes (every 60 cycles), not every cycle -- they contain reference/lookup data that changes infrequently.
- **Scheduled tasks:** Daily risk p-value refresh (midnight UTC), hourly MM proxy discovery.
- **Failure handling:** Exits after 10 consecutive failures; Railway restart policy re-launches.

See `cronjobs/cagg_refresh/README.md` for deployment and configuration detail.

---

## Layer 3: View Functions (Frontend Interface)

The frontend consumes data through parameterized SQL functions that return non-materialized result sets. These functions are the primary API between the database and the dashboard/UI layer.

### Shared Patterns

All view functions follow consistent conventions:

- **Parameterized time control** -- accept interval strings (e.g. `'1 minute'`, `'5 seconds'`, `'1 hour'`), date ranges, and/or row limits so the frontend can request different time windows and granularities from the same function.
- **Read from CAGGs, not source tables** -- view functions query the 5-second CAGG layer (and auxiliary tables) rather than raw source tables, leveraging the materialised aggregation for performance.
- **Re-bucketing** -- functions use `time_bucket()` with the caller's requested interval to re-aggregate the 5-second CAGG data up to the requested grain. This allows a single CAGG to serve 5-second, 1-minute, 5-minute, or hourly views.
- **LOCF (Last Observation Carried Forward)** -- state metrics (prices, balances, utilization ratios) are carried forward across empty buckets using window functions, so timeseries charts do not show gaps when no new data arrived in a given interval.
- **DISTINCT ON for "latest" views** -- `SELECT DISTINCT ON (entity) ... ORDER BY entity, time DESC` extracts the most recent row per entity from a CAGG, used for single-point-in-time dashboard panels.
- **Dynamic SQL** -- some functions (e.g. `get_view_dex_timeseries`) use `format()` / `EXECUTE` for interval-parameterised queries where static SQL cannot accept interval literals as parameters.

### View Function Categories

**"Last" views** -- return the single most recent state for display in dashboard summary panels:

| Function / View | Domain | Content |
|---|---|---|
| `dexes.get_view_dex_last()` | DEXes | Latest pool metrics, swap/LP volumes, VWAP, price impact |
| `exponent.get_view_exponent_last()` | Exponent | Latest vault/market state, PT pricing, yield metrics |
| `kamino_lend.v_last` | Kamino | Latest reserve and obligation metrics |
| `solstice_proprietary.v_prop_last` | Solstice | USX/eUSX supply chain state (USX -> eUSX -> SY -> PT/YT) |

**Timeseries views** -- return multi-row time-bucketed data for charts:

| Function | Domain | Content |
|---|---|---|
| `dexes.get_view_dex_timeseries()` | DEXes | Swap/LP flows, VWAP, reserves, tick depth, price impact over time |
| `exponent.get_view_exponent_timeseries()` | Exponent | Vault/market metrics, yields, supply over time |
| `kamino_lend.get_view_klend_timeseries()` | Kamino | Reserve metrics, obligation aggregates, activity volumes over time |
| `solstice_proprietary.v_prop_get_timeseries()` | Solstice | USX/eUSX protocol metrics over time |

**Specialised views** -- serve specific dashboard panels or analyses:

| Function / View | Domain | Purpose |
|---|---|---|
| `dexes.get_view_dex_risk_last()` | DEXes | Risk dashboard: policies, p-values, impact at reference levels |
| `dexes.get_view_dex_table_liquidity_depth()` | DEXes | Liquidity depth table for tick distribution panels |
| `dexes.get_view_dex_table_ranked_events()` | DEXes | Ranked swap/LP events table |
| `kamino_lend.get_view_klend_obligations()` | Kamino | Obligation browser with risk filters |
| `kamino_lend.get_view_klend_sensitivities()` | Kamino | LTV/health factor sensitivity analysis |
| `kamino_lend.v_rate_curve_usx()` | Kamino | Borrow rate curve visualisation |
| `solstice_proprietary.v_prop_get_last_interval()` | Solstice | Cross-domain activity summary over a given interval |
| `solstice_proprietary.v_prop_redeem_queue()` | Solstice | USX redemption queue state |
| `solstice_proprietary.v_prop_get_user_leaders()` | Solstice | Top user activity leaderboard |

### Cross-Domain Views

Some views span multiple schemas to produce composite metrics. For example, `v_prop_last` reads from `solstice_proprietary`, `exponent`, `kamino_lend`, and `dexes` CAGGs to assemble the full USX -> eUSX -> SY -> PT/YT supply chain. Similarly, `v_prop_get_last_interval` aggregates activity across DEX swaps, Kamino lending operations, and Exponent trading within a configurable interval.

---

## Domain Functions

Each domain defines SQL functions that encapsulate protocol-specific calculations. These are called by view functions, triggers, or directly by the frontend.

### DEXes -- Liquidity and Price Impact

- **`impact_bps_from_qsell()`** / **`impact_bps_from_qsell_latest()`** -- simulate selling a quantity of token through a CLMM pool's tick-level liquidity depth, returning price impact in basis points. The `_latest` variant uses the current-state `tokendist_latest` table; the non-latest variant accepts a historical `query_id`.
- **`impact_qsell_from_bps()`** / **`impact_qsell_from_bps_latest()`** -- inverse: given a target BPS impact, find the sell quantity that would produce it.
- **`get_concentration_at_active_tick()`** / **`get_concentration_at_peg()`** -- calculate the percentage of total pool liquidity concentrated within N ticks of the current price or peg.
- **`get_price_from_tick()`**, **`get_tick_float_from_sqrtPriceXQQ()`**, **`get_decimal_price_from_sqrtPriceXQQ()`** -- CLMM math primitives for tick/price conversions.
- **`discover_mm_proxy_addresses()`** -- identifies market-maker proxy addresses from swap patterns (hourly scheduled task).

### Kamino -- Risk Sensitivity

- **`sensitize_ltv()`** -- generates arrays of LTV values under stepped asset or liability shocks for stress testing.
- **`sensitize_deposit_value()`** / **`sensitize_borrow_value()`** -- project deposit and borrow values across sensitivity steps.
- **`sensitize_liquidation_distance()`** -- computes liquidation distance across sensitivity scenarios.
- **`calculate_health_factor_array()`** -- derives health factor arrays from deposit/borrow arrays and liquidation LTV.
- **`is_unhealthy_from_values()`** / **`is_bad_from_values()`** -- predicate functions for risk classification at each sensitivity step.
- **`liquidatable_value_from_values()`** -- calculates liquidatable debt at each sensitivity step.
- **`rate_curve_all()`** / **`rate_curve_up()`** / **`rate_curve_down()`** -- generate borrow rate curves from 0-100% utilization for each reserve, grouping reserves with identical curve shapes.
- **`sum_array_elementwise()`** / **`average_array_elementwise()`** -- utility functions for array-level aggregation across sensitivity scenarios.

### Exponent -- AMM Pricing

- **`calculate_pt_price()`** -- implements the Pendle V2 Notional AMM formula to derive PT price in SY units from market state. Two overloads: by market address (with DB lookup) or by direct parameters.
- **`get_amm_price_impact()`** -- calculates price impact for buying PT on the Pendle AMM.
- **`get_amm_yield_impact()`** -- calculates implied yield impact for PT trades.

### Solstice -- Cross-Pool Impact

- **`calculate_tvl_weighted_price_impact()`** -- distributes a sell quantity across multiple DEX pools by TVL weight, calls `impact_bps_from_qsell_latest()` for each, and returns the weighted average BPS impact. Used to estimate market-wide slippage for USX or eUSX sells.
- **`calculate_tvl_weighted_qsell_from_bps()`** -- inverse: given a target BPS, find the sell quantity using TVL-weighted pool allocation.
- **`get_price_impact_reference_levels()`** -- returns pre-defined BPS reference levels with corresponding USX and eUSX quantities for dashboard display.

---

## Risk Tables (DEXes)

The DEXes domain maintains two specialised tables for risk policy management:

- **`risk_policies`** -- versioned risk policy configurations defining three price zones (normal, elevated stress, tail risk) with liquidity share allocations, extreme event parameters, and intervention/recovery thresholds. Timestamp-keyed for audit history.
- **`risk_pvalues`** -- empirical percentile distributions for sell event magnitudes and net sell pressure across multiple time intervals (5m, 15m, 30m, 1h, 6h, 24h). Refreshed daily at midnight UTC via the CAGG refresh service calling `refresh_risk_pvalues()`.

---

## Queue Health Monitoring

Each domain schema includes a `queue_health` hypertable and associated monitoring views that track ingestion queue metrics over time (queue size, utilization, write rate, failure rate). These are covered in detail in **04-RESILIENCE.md**.

---

## Storage and Compression Policies

TimescaleDB automatic policies manage chunk lifecycle across all schemas. Policy definitions live in `dbsql/storage-compression-policies/` and are deployed via a Python script with dry-run, apply, and rollback modes.

### Policy Files

| File | Purpose |
|---|---|
| `00_cagg_refresh_policies.sql` | Lightweight CAGG refresh policies (12-hour safety net; prerequisite for CAGG compression) |
| `01_source_compression.sql` | Columnstore compression on all source hypertables |
| `02_cagg_compression.sql` | Columnstore compression on all continuous aggregates |
| `03_retention_policies.sql` | Data retention (CAGGs and queue_health only) |
| `deploy.py` | Deployment script (`--dry-run`, `--apply`, `--rollback`) |

### Compression

All source hypertables and CAGGs have columnstore compression policies. Chunks older than the `compress_after` threshold are automatically converted to compressed columnar storage by TimescaleDB's background scheduler.

| Layer | compress_after | segmentby strategy |
|---|---|---|
| Source hypertables | 12 hours | Entity identifier where cardinality is low (`pool_address`, `account_address`, `reserve_address`, `vault_address`, `market_address`, `mint_sy`). Event/transaction tables use orderby-only. |
| CAGGs | 1 day | Matches the source table's entity column. Event-aggregate CAGGs use orderby-only. |
| Queue health | 1 day | Orderby-only (no entity column). |
| Queue health hourly (CAGGs) | 7 days | Orderby-only. |

Compression is lossless — compressed chunks remain fully queryable via standard SQL. The `segmentby` column enables segment-skip pruning on entity-filtered queries (the dominant access pattern for all frontend views).

### Retention

Source tables have **no retention policy** — this is deliberately deferred until a long-term data warehousing strategy is decided. Compression keeps storage growth manageable in the interim.

| Layer | drop_after | Scope |
|---|---|---|
| CAGGs | 90 days | Matches the longest dashboard lookback window. CAGG data is re-derivable from source tables. |
| Queue health | 90 days | Operational monitoring data. |

### Deployment

The `deploy.py` script reads connection details from `.env.prod.core` and executes all four SQL files in order within a single transaction. All `add_*_policy` calls use `if_not_exists`, making the script idempotent and safe to re-run.

```bash
python dbsql/storage-compression-policies/deploy.py --dry-run   # validate, then rollback
python dbsql/storage-compression-policies/deploy.py --apply     # commit all policies
python dbsql/storage-compression-policies/deploy.py --rollback  # remove all policies
```

The script retries transient deadlocks (caused by concurrent CAGG refresh) with exponential backoff. In `--apply` mode, successful statements are committed even if some fail, so re-running picks up only the remaining tables.

---

## SQL File Organisation

Each service's `dbsql/` directory follows a consistent structure:

```
<service>/dbsql/
  src/              # Source table DDL (CREATE TABLE, hypertable, indexes, comments)
  src_test/         # Duplicate DDL for test schema deployment (not production)
  cagg/             # Continuous aggregate definitions
  functions/        # Domain calculation functions, trigger functions
  views/            # View functions serving the frontend
  monitoring/       # Queue health tables and monitoring views
  risk/             # Risk policy and statistical tables (DEXes only)
```

All SQL files contain detailed inline comments explaining purpose, formula references, parameter descriptions, and performance notes. When in doubt about a column's meaning, scaling, or source, check the `COMMENT ON` annotations in the relevant `src/` file first.

---

## Where to Go Next

- **SQL files** (`<service>/dbsql/src/`) -- authoritative column-level documentation.
- **CAGG refresh service** (`cronjobs/cagg_refresh/README.md`) -- deployment, configuration, troubleshooting.
- **01-INGESTION.md** -- how data arrives in the source tables.
- **04-RESILIENCE.md** -- health monitoring views and queue health telemetry.
- **05-DEPENDENCIES.md** -- TimescaleDB hosting, external services.
