-- mat_klend_timeseries_1m: Pre-joined reserve + obligation + activity data at 1-minute grain
-- Stores data in FLAT format (one row per reserve per bucket) for flexibility.
-- The view function pivots and formats this data into the frontend column layout.
-- Eliminates expensive LATERAL joins on src_reserves/src_obligations_agg at query time.

-- ========================
-- Reserve timeseries (flat: one row per reserve per bucket)
-- ========================
CREATE TABLE IF NOT EXISTS kamino_lend.mat_klend_reserve_ts_1m (
    bucket_time             TIMESTAMPTZ NOT NULL,
    reserve_address         TEXT        NOT NULL,
    market_address          TEXT,
    symbol                  TEXT,
    reserve_type            TEXT,       -- 'borrow' or 'collateral'

    -- Supply metrics (decimal-adjusted, human-readable)
    supply_total            NUMERIC,
    supply_available        NUMERIC,
    supply_borrowed         NUMERIC,
    collateral_total_supply NUMERIC,

    -- Rates
    utilization_ratio       NUMERIC,
    supply_apy              NUMERIC,
    borrow_apy              NUMERIC,

    -- Pricing
    market_price            NUMERIC,    -- liquidity_market_price_sf / 2^60
    oracle_price            NUMERIC,

    -- Market values (vault-based, in USD)
    vault_liquidity_marketvalue   NUMERIC,
    vault_collateral_marketvalue  NUMERIC,

    refreshed_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (reserve_address, bucket_time)
);

SELECT create_hypertable(
    'kamino_lend.mat_klend_reserve_ts_1m', 'bucket_time',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_mat_klend_reserve_ts_1m_reserve
    ON kamino_lend.mat_klend_reserve_ts_1m (reserve_address, bucket_time DESC);

CREATE INDEX IF NOT EXISTS idx_mat_klend_reserve_ts_1m_symbol
    ON kamino_lend.mat_klend_reserve_ts_1m (symbol, bucket_time DESC);

CREATE INDEX IF NOT EXISTS idx_mat_klend_reserve_ts_1m_type
    ON kamino_lend.mat_klend_reserve_ts_1m (reserve_type, bucket_time DESC);

-- ========================
-- Obligation timeseries (one row per bucket — market-level aggregates)
-- ========================
CREATE TABLE IF NOT EXISTS kamino_lend.mat_klend_obligation_ts_1m (
    bucket_time                  TIMESTAMPTZ NOT NULL PRIMARY KEY,
    market_address               TEXT,
    obligation_query_id          BIGINT,

    -- Risk metrics
    market_capacity_utilization_pct  NUMERIC,
    weighted_avg_loan_to_value_sig   NUMERIC,
    median_loan_to_value_sig         NUMERIC,
    weighted_avg_health_factor_sig   NUMERIC,

    -- Debt exposure
    total_unhealthy_debt         NUMERIC,
    total_bad_debt               NUMERIC,
    total_collateral_value       NUMERIC,
    total_borrow_value           NUMERIC,

    refreshed_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

SELECT create_hypertable(
    'kamino_lend.mat_klend_obligation_ts_1m', 'bucket_time',
    if_not_exists => TRUE
);

-- ========================
-- Activity timeseries (flat: one row per symbol per bucket)
-- ========================
CREATE TABLE IF NOT EXISTS kamino_lend.mat_klend_activity_ts_1m (
    bucket_time              TIMESTAMPTZ NOT NULL,
    symbol                   TEXT        NOT NULL,
    reserve_address          TEXT,

    deposit_vault_sum        NUMERIC     DEFAULT 0,
    deposit_vault_count      BIGINT      DEFAULT 0,
    withdraw_vault_sum       NUMERIC     DEFAULT 0,
    withdraw_vault_count     BIGINT      DEFAULT 0,
    borrowing_sum            NUMERIC     DEFAULT 0,
    borrowing_count          BIGINT      DEFAULT 0,
    repay_borrowing_sum      NUMERIC     DEFAULT 0,
    repay_borrowing_count    BIGINT      DEFAULT 0,
    liquidate_borrowing_sum  NUMERIC     DEFAULT 0,
    liquidate_borrowing_count BIGINT     DEFAULT 0,
    total_volume             NUMERIC     DEFAULT 0,

    refreshed_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (symbol, reserve_address, bucket_time)
);

SELECT create_hypertable(
    'kamino_lend.mat_klend_activity_ts_1m', 'bucket_time',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_mat_klend_activity_ts_1m_symbol
    ON kamino_lend.mat_klend_activity_ts_1m (symbol, bucket_time DESC);

-- ---------------------------------------------------------------------------
-- Refresh procedure: incremental for all three sub-tables
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE kamino_lend.refresh_mat_klend_timeseries_1m()
LANGUAGE plpgsql AS $$
DECLARE
    v_refresh_from TIMESTAMPTZ := NOW() - INTERVAL '30 minutes';
    v_seed_from    TIMESTAMPTZ := NOW() - INTERVAL '35 minutes';
BEGIN
    -- 1. Reserve timeseries: LOCF from cagg_reserves_5s
    DELETE FROM kamino_lend.mat_klend_reserve_ts_1m
    WHERE bucket_time >= v_refresh_from;

    INSERT INTO kamino_lend.mat_klend_reserve_ts_1m (
        bucket_time, reserve_address, market_address, symbol, reserve_type,
        supply_total, supply_available, supply_borrowed, collateral_total_supply,
        utilization_ratio, supply_apy, borrow_apy,
        market_price, oracle_price,
        vault_liquidity_marketvalue, vault_collateral_marketvalue,
        refreshed_at
    )
    SELECT
        time_bucket('1 minute', r.bucket) AS bucket_time,
        r.reserve_address,
        LAST(r.market_address, r.bucket),
        LAST(r.symbol, r.bucket),
        LAST(r.reserve_type_config, r.bucket),
        LAST(r.supply_total, r.bucket),
        LAST(r.supply_available, r.bucket),
        LAST(r.supply_borrowed, r.bucket),
        LAST(r.collateral_total_supply, r.bucket),
        LAST(r.utilization_ratio, r.bucket),
        LAST(r.supply_apy, r.bucket),
        LAST(r.borrow_apy, r.bucket),
        LAST(r.market_price, r.bucket),
        LAST(r.oracle_price, r.bucket),
        LAST(r.vault_liquidity_marketvalue, r.bucket),
        LAST(r.vault_collateral_marketvalue, r.bucket),
        NOW()
    FROM kamino_lend.cagg_reserves_5s r
    WHERE r.bucket >= v_seed_from
    GROUP BY time_bucket('1 minute', r.bucket), r.reserve_address
    HAVING time_bucket('1 minute', r.bucket) >= v_refresh_from;

    -- 2. Obligation timeseries: LAST from cagg_obligations_agg_5s
    DELETE FROM kamino_lend.mat_klend_obligation_ts_1m
    WHERE bucket_time >= v_refresh_from;

    INSERT INTO kamino_lend.mat_klend_obligation_ts_1m (
        bucket_time, market_address, obligation_query_id,
        market_capacity_utilization_pct, weighted_avg_loan_to_value_sig,
        median_loan_to_value_sig, weighted_avg_health_factor_sig,
        total_unhealthy_debt, total_bad_debt,
        total_collateral_value, total_borrow_value,
        refreshed_at
    )
    SELECT
        time_bucket('1 minute', o.bucket) AS bucket_time,
        LAST(o.market_address, o.bucket),
        LAST(o.obligation_query_id, o.bucket),
        LAST(o.market_capacity_utilization_pct, o.bucket),
        LAST(o.weighted_avg_loan_to_value_sig, o.bucket),
        LAST(o.median_loan_to_value, o.bucket),
        LAST(o.weighted_avg_health_factor_sig, o.bucket),
        LAST(o.total_unhealthy_debt, o.bucket),
        LAST(o.total_bad_debt, o.bucket),
        LAST(o.total_collateral_value, o.bucket),
        LAST(o.total_borrow_value, o.bucket),
        NOW()
    FROM kamino_lend.cagg_obligations_agg_5s o
    WHERE o.bucket >= v_seed_from
    GROUP BY time_bucket('1 minute', o.bucket)
    HAVING time_bucket('1 minute', o.bucket) >= v_refresh_from;

    -- 3. Activity timeseries: SUM from cagg_activities_5s
    DELETE FROM kamino_lend.mat_klend_activity_ts_1m
    WHERE bucket_time >= v_refresh_from;

    INSERT INTO kamino_lend.mat_klend_activity_ts_1m (
        bucket_time, symbol, reserve_address,
        deposit_vault_sum, deposit_vault_count,
        withdraw_vault_sum, withdraw_vault_count,
        borrowing_sum, borrowing_count,
        repay_borrowing_sum, repay_borrowing_count,
        liquidate_borrowing_sum, liquidate_borrowing_count,
        total_volume, refreshed_at
    )
    SELECT
        time_bucket('1 minute', a.bucket) AS bucket_time,
        a.symbol,
        a.reserve_address,
        SUM(a.deposit_vault_sum),
        SUM(a.deposit_vault_count),
        SUM(a.withdraw_vault_sum),
        SUM(a.withdraw_vault_count),
        SUM(a.borrowing_sum),
        SUM(a.borrowing_count),
        SUM(a.repay_borrowing_sum),
        SUM(a.repay_borrowing_count),
        SUM(a.liquidate_borrowing_sum),
        SUM(a.liquidate_borrowing_count),
        SUM(a.total_volume),
        NOW()
    FROM kamino_lend.cagg_activities_5s a
    WHERE a.bucket >= v_seed_from
    GROUP BY time_bucket('1 minute', a.bucket), a.symbol, a.reserve_address
    HAVING time_bucket('1 minute', a.bucket) >= v_refresh_from;
END;
$$;
