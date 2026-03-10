-- Kamino Lend Obligations Aggregates - 5 Second Continuous Aggregate
-- Point-in-time snapshots of market-wide obligation statistics
-- Uses LAST() aggregation since all fields are already aggregated point-in-time measurements
-- Excludes parameter columns (mkt_*, resrv_*) as they're calculation inputs, not outputs
--
-- MIGRATION NOTE (2025-12-06): Updated to use new explicit column naming from src_obligations_agg:
--   - Count columns now use n_*_all (e.g., n_obligations_all, n_deposit_positions_all)
--   - Risk metrics use *_sig suffixes (e.g., avg_health_factor_sig, median_ltv_sig)
--   - Output column names preserved for backwards compatibility with existing dashboards/queries

CREATE MATERIALIZED VIEW kamino_lend.cagg_obligations_agg_5s
WITH (timescaledb.continuous) AS
SELECT
    -- Time bucket with 5-second intervals (using block_time)
    time_bucket('5 seconds', block_time) AS bucket,

    -- Market identification
    LAST(market_address, block_time) AS market_address,

    -- Query ID (renamed for clarity)
    LAST(query_id, block_time) AS obligation_query_id,

    -- Temporal metadata
    LAST(time, block_time) AS time,
    LAST(slot, block_time) AS slot,

    -- ========================================================================
    -- COUNTS - Number of obligations by category (using _all columns)
    -- ========================================================================
    LAST(n_obligations_all, block_time) AS total_obligations,
    LAST(n_obligations_active_all, block_time) AS active_obligations,
    LAST(n_obligations_with_debt_all, block_time) AS obligations_with_debt,
    LAST(n_obligations_deposit_only_all, block_time) AS obligations_deposit_only,

    -- Position counts
    LAST(n_deposit_positions_all, block_time) AS total_deposits_outstanding,
    LAST(n_borrow_positions_all, block_time) AS total_borrows_outstanding,

    -- ========================================================================
    -- PORTFOLIO VALUES - Total values across all obligations
    -- ========================================================================
    LAST(total_collateral_value, block_time) AS total_collateral_value,
    LAST(total_borrow_value, block_time) AS total_borrow_value,
    LAST(total_net_value, block_time) AS total_net_value,

    -- ========================================================================
    -- AVERAGE POSITION SIZES (using _all columns for backwards compatibility)
    -- ========================================================================
    LAST(avg_collateral_per_obligation_all, block_time) AS avg_collateral_per_obligation,
    LAST(avg_borrow_per_obligation_all, block_time) AS avg_borrow_per_obligation,
    LAST(avg_collateral_per_deposit_all, block_time) AS avg_collateral_per_deposit,
    LAST(avg_borrow_per_loan_all, block_time) AS avg_borrow_per_loan,

    -- ========================================================================
    -- AVERAGE RISK METRICS (using _sig columns - filtered by significance)
    -- ========================================================================
    LAST(avg_health_factor_sig, block_time) AS avg_health_factor,
    LAST(avg_loan_to_value_sig, block_time) AS avg_loan_to_value,
    LAST(avg_unhealthy_ltv_sig, block_time) AS avg_unhealthy_ltv_for_obligations,
    LAST(avg_liquidation_buffer_pct_sig, block_time) AS avg_liquidation_buffer_pct,
    LAST(avg_leverage_sig, block_time) AS avg_leverage,
    LAST(avg_borrow_utilization_pct_sig, block_time) AS avg_borrow_utilization_pct,

    -- ========================================================================
    -- MEDIAN RISK METRICS (using _sig columns - filtered by significance)
    -- ========================================================================
    LAST(median_health_factor_sig, block_time) AS median_health_factor,
    LAST(median_loan_to_value_sig, block_time) AS median_loan_to_value,

    -- ========================================================================
    -- RISK CATEGORY COUNTS (Protocol-defined thresholds, mutually exclusive, using _all)
    -- ========================================================================
    LAST(n_bad_debt_all, block_time) AS bad_debt_count,
    LAST(n_unhealthy_all, block_time) AS unhealthy_count,

    -- ========================================================================
    -- RISK EXPOSURE - Total debt (Protocol-defined thresholds, mutually exclusive)
    -- ========================================================================
    LAST(total_bad_debt, block_time) AS total_bad_debt,
    LAST(total_unhealthy_debt, block_time) AS total_unhealthy_debt,

    -- ========================================================================
    -- RISK EXPOSURE - Percentage of loan book (Protocol-defined thresholds, mutually exclusive)
    -- ========================================================================
    LAST(bad_debt_pct, block_time) AS bad_debt_pct,
    LAST(unhealthy_debt_pct, block_time) AS unhealthy_debt_pct,

    -- ========================================================================
    -- LIQUIDATABLE VALUE METRICS
    -- ========================================================================
    LAST(total_liquidatable_value, block_time) AS total_liquidatable_value,
    LAST(liquidatable_value_pct_of_deposits, block_time) AS liquidatable_value_pct_of_deposits,

    -- ========================================================================
    -- CAPACITY METRICS
    -- ========================================================================
    LAST(total_borrow_capacity_remaining, block_time) AS total_borrow_capacity_remaining,
    LAST(market_capacity_utilization_pct, block_time) AS market_capacity_utilization_pct,

    -- ========================================================================
    -- WEIGHTED AVERAGE RISK METRICS (weighted by loan size, filtered by significance)
    -- ========================================================================
    LAST(weighted_avg_health_factor_sig, block_time) AS weighted_avg_health_factor_sig,
    LAST(weighted_avg_loan_to_value_sig, block_time) AS weighted_avg_loan_to_value_sig,
    LAST(weighted_avg_liquidation_buffer_pct_sig, block_time) AS weighted_avg_liquidation_buffer_pct_sig,

    -- ========================================================================
    -- CONCENTRATION METRICS - Loan concentration risk
    -- ========================================================================
    LAST(top_10_debt_concentration_pct, block_time) AS top_10_debt_concentration_pct,
    LAST(top_5_debt_concentration_pct, block_time) AS top_5_debt_concentration_pct,
    LAST(top_1_debt_concentration_pct, block_time) AS top_1_debt_concentration_pct,
    LAST(herfindahl_index_debt, block_time) AS herfindahl_index_debt,
    LAST(largest_single_obligation_debt, block_time) AS largest_single_obligation_debt,
    LAST(largest_unhealthy_obligation, block_time) AS largest_unhealthy_obligation,

    -- ========================================================================
    -- RISK CATEGORY THRESHOLD COUNT (UI metric, using _all)
    -- ========================================================================
    LAST(n_danger_zone_all, block_time) AS hf_healthy_below_1_1_count,

    -- ========================================================================
    -- LENDING MARKET PARAMETERS
    -- ========================================================================
    LAST(mkt_liquidation_max_debt_close_factor_pct, block_time) AS mkt_liquidation_max_debt_close_factor_pct,
    LAST(mkt_insolvency_risk_unhealthy_ltv_pct, block_time) AS mkt_insolvency_risk_unhealthy_ltv_pct,
    LAST(mkt_max_liquidatable_debt_market_value_at_once, block_time) AS mkt_max_liquidatable_debt_market_value_at_once,

    -- ========================================================================
    -- RESERVE PARAMETERS (Arrays - one element per reserve)
    -- ========================================================================
    LAST(resrv_address, block_time) AS resrv_address,
    LAST(resrv_symbol, block_time) AS resrv_symbol,
    LAST(resrv_loan_to_value_pct, block_time) AS resrv_loan_to_value_pct,
    LAST(resrv_liquidation_threshold_pct, block_time) AS resrv_liquidation_threshold_pct,
    LAST(resrv_borrow_factor_pct, block_time) AS resrv_borrow_factor_pct,

    -- ========================================================================
    -- AGGREGATE BORROW POSITIONS BY ASSET (Market-wide totals)
    -- ========================================================================
    LAST(borrow_reserve_by_asset, block_time) AS borrow_reserve_by_asset,
    LAST(borrow_market_value_sf_by_asset, block_time) AS borrow_market_value_sf_by_asset,
    LAST(borrowed_amount_sf_by_asset, block_time) AS borrowed_amount_sf_by_asset,
    LAST(borrow_factor_adjusted_market_value_sf_by_asset, block_time) AS borrow_factor_adjusted_market_value_sf_by_asset,

    -- ========================================================================
    -- AGGREGATE DEPOSIT POSITIONS BY ASSET (Market-wide totals)
    -- ========================================================================
    LAST(deposit_reserve_by_asset, block_time) AS deposit_reserve_by_asset,
    LAST(deposit_market_value_sf_by_asset, block_time) AS deposit_market_value_sf_by_asset,
    LAST(deposited_amount_by_asset, block_time) AS deposited_amount_by_asset,

    -- ========================================================================
    -- CALCULATED MARKET-LEVEL METRICS (Scalar bad debt threshold)
    -- ========================================================================
    LAST(c_hf_bad_debt_threshold, block_time) AS c_hf_bad_debt_threshold,

    -- ========================================================================
    -- METADATA (block_time for hypertable compatibility)
    -- ========================================================================
    LAST(block_time, block_time) AS last_block_time

FROM kamino_lend.src_obligations_agg
GROUP BY bucket
WITH NO DATA;

-- Add index on bucket for efficient time-range queries
CREATE INDEX IF NOT EXISTS idx_cagg_obligations_agg_5s_bucket
    ON kamino_lend.cagg_obligations_agg_5s (bucket DESC);

-- Add index on market for filtering
CREATE INDEX IF NOT EXISTS idx_cagg_obligations_agg_5s_market
    ON kamino_lend.cagg_obligations_agg_5s (market_address, bucket DESC);


-- Table comment
COMMENT ON MATERIALIZED VIEW kamino_lend.cagg_obligations_agg_5s IS
'5-second continuous aggregate of obligation statistics. Point-in-time snapshots using LAST() aggregation. Now includes market parameters (mkt_*), reserve parameters (resrv_*), and aggregate positions by asset (borrow/deposit arrays). Refreshed externally via cron job.';

-- Column comments
COMMENT ON COLUMN kamino_lend.cagg_obligations_agg_5s.bucket IS
'5-second time bucket. Use this for time-range queries.';

COMMENT ON COLUMN kamino_lend.cagg_obligations_agg_5s.obligation_query_id IS
'Query ID from source table (renamed from query_id). Links to individual obligations in src_obligations.';

COMMENT ON COLUMN kamino_lend.cagg_obligations_agg_5s.time IS
'Capture timestamp (TIMESTAMPTZ). When this snapshot was taken.';

COMMENT ON COLUMN kamino_lend.cagg_obligations_agg_5s.slot IS
'Blockchain slot number for this snapshot.';

COMMENT ON COLUMN kamino_lend.cagg_obligations_agg_5s.last_block_time IS
'Blockchain timestamp (TIMESTAMPTZ). Same as block_time from source table.';

COMMENT ON COLUMN kamino_lend.cagg_obligations_agg_5s.mkt_liquidation_max_debt_close_factor_pct IS
'[MARKET PARAM] Maximum percentage of debt that can be closed in a single liquidation event.';

COMMENT ON COLUMN kamino_lend.cagg_obligations_agg_5s.mkt_insolvency_risk_unhealthy_ltv_pct IS
'[MARKET PARAM] LTV threshold percentage at which position is considered unhealthy for insolvency risk.';

COMMENT ON COLUMN kamino_lend.cagg_obligations_agg_5s.mkt_max_liquidatable_debt_market_value_at_once IS
'[MARKET PARAM] Maximum debt value (in quote currency) that can be liquidated in a single transaction.';

COMMENT ON COLUMN kamino_lend.cagg_obligations_agg_5s.resrv_address IS
'[RESERVE PARAM] Array of reserve addresses, ordered consistently across all reserve parameter arrays.';

COMMENT ON COLUMN kamino_lend.cagg_obligations_agg_5s.resrv_symbol IS
'[RESERVE PARAM] Array of reserve symbols from RESERVE_ATTRIBUTES config, matching order of resrv_address array.';

COMMENT ON COLUMN kamino_lend.cagg_obligations_agg_5s.resrv_loan_to_value_pct IS
'[RESERVE PARAM] Array of loan-to-value percentages for each reserve. Maximum LTV allowed for borrowing.';

COMMENT ON COLUMN kamino_lend.cagg_obligations_agg_5s.resrv_liquidation_threshold_pct IS
'[RESERVE PARAM] Array of liquidation threshold percentages for each reserve. LTV at which liquidation occurs.';

COMMENT ON COLUMN kamino_lend.cagg_obligations_agg_5s.resrv_borrow_factor_pct IS
'[RESERVE PARAM] Array of borrow factor percentages for each reserve. Risk weighting applied to borrows.';

COMMENT ON COLUMN kamino_lend.cagg_obligations_agg_5s.borrow_reserve_by_asset IS
'[AGGREGATE] Array of unique reserve addresses with active borrows across all obligations, sorted alphanumerically.';

COMMENT ON COLUMN kamino_lend.cagg_obligations_agg_5s.borrow_market_value_sf_by_asset IS
'[AGGREGATE] Array of total borrow market values (scaled fractions) per reserve, matching order of borrow_reserve_by_asset.';

COMMENT ON COLUMN kamino_lend.cagg_obligations_agg_5s.borrowed_amount_sf_by_asset IS
'[AGGREGATE] Array of total borrowed amounts (scaled fractions) per reserve, matching order of borrow_reserve_by_asset.';

COMMENT ON COLUMN kamino_lend.cagg_obligations_agg_5s.borrow_factor_adjusted_market_value_sf_by_asset IS
'[AGGREGATE] Array of total risk-adjusted borrow values (scaled fractions) per reserve, matching order of borrow_reserve_by_asset.';

COMMENT ON COLUMN kamino_lend.cagg_obligations_agg_5s.deposit_reserve_by_asset IS
'[AGGREGATE] Array of unique reserve addresses with active deposits across all obligations, sorted alphanumerically.';

COMMENT ON COLUMN kamino_lend.cagg_obligations_agg_5s.deposit_market_value_sf_by_asset IS
'[AGGREGATE] Array of total deposit market values (scaled fractions) per reserve, matching order of deposit_reserve_by_asset.';

COMMENT ON COLUMN kamino_lend.cagg_obligations_agg_5s.deposited_amount_by_asset IS
'[AGGREGATE] Array of total deposited amounts per reserve, matching order of deposit_reserve_by_asset.';

COMMENT ON COLUMN kamino_lend.cagg_obligations_agg_5s.c_hf_bad_debt_threshold IS
'[CALCULATED] Market-level bad debt health factor threshold derived from mkt_insolvency_risk_unhealthy_ltv_pct.';

-- Example queries:
--
-- Get latest 5s snapshot:
-- SELECT * FROM kamino_lend.cagg_obligations_agg_5s ORDER BY bucket DESC LIMIT 1;
--
-- Get last hour of 5s snapshots:
-- SELECT * FROM kamino_lend.cagg_obligations_agg_5s
-- WHERE bucket >= NOW() - INTERVAL '1 hour'
-- ORDER BY bucket DESC;
--
-- Compare current vs 1 minute ago:
-- SELECT
--     NOW() as current_bucket,
--     unhealthy_count as current_unhealthy,
--     LAG(unhealthy_count) OVER (ORDER BY bucket) as prev_unhealthy
-- FROM kamino_lend.cagg_obligations_agg_5s
-- WHERE bucket >= NOW() - INTERVAL '1 minute'
-- ORDER BY bucket DESC;
--
-- Get borrow positions by asset (unnest arrays):
-- SELECT
--     bucket,
--     UNNEST(borrow_reserve_by_asset) AS reserve_address,
--     UNNEST(resrv_symbol) AS symbol,
--     UNNEST(borrow_market_value_sf_by_asset) / POWER(2, 60) AS borrow_market_value,
--     UNNEST(borrowed_amount_sf_by_asset) / POWER(2, 60) AS borrowed_amount
-- FROM kamino_lend.cagg_obligations_agg_5s
-- WHERE bucket >= NOW() - INTERVAL '1 hour'
-- ORDER BY bucket DESC, reserve_address;
--
-- Get deposit positions by asset (unnest arrays):
-- SELECT
--     bucket,
--     UNNEST(deposit_reserve_by_asset) AS reserve_address,
--     UNNEST(deposit_market_value_sf_by_asset) / POWER(2, 60) AS deposit_market_value,
--     UNNEST(deposited_amount_by_asset) AS deposited_amount
-- FROM kamino_lend.cagg_obligations_agg_5s
-- WHERE bucket >= NOW() - INTERVAL '1 hour'
-- ORDER BY bucket DESC, reserve_address;
--
-- Get reserve parameters:
-- SELECT
--     UNNEST(resrv_address) AS reserve_address,
--     UNNEST(resrv_symbol) AS symbol,
--     UNNEST(resrv_loan_to_value_pct) AS ltv_pct,
--     UNNEST(resrv_liquidation_threshold_pct) AS liq_threshold_pct,
--     UNNEST(resrv_borrow_factor_pct) AS borrow_factor_pct
-- FROM kamino_lend.cagg_obligations_agg_5s
-- ORDER BY bucket DESC
-- LIMIT 1;
