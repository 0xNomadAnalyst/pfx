-- mat_klend_last: Pre-computed latest snapshot of lending market state
-- Eliminates the expensive DISTINCT ON + multi-source joins in v_last
-- Stores flat per-reserve data; the view function pivots into the frontend layout.

-- ========================
-- Latest reserve state (one row per reserve)
-- ========================
CREATE TABLE IF NOT EXISTS kamino_lend.mat_klend_last_reserves (
    reserve_address              TEXT PRIMARY KEY,
    market_address               TEXT,
    symbol                       TEXT,
    reserve_type                 TEXT,       -- 'borrow' or 'collateral'
    decimals                     INTEGER,

    -- Supply metrics (human-readable, decimal-adjusted)
    supply_total                 NUMERIC,
    supply_available             NUMERIC,
    supply_borrowed              NUMERIC,
    collateral_total_supply      NUMERIC,

    -- Rates
    utilization_ratio            NUMERIC,
    supply_apy                   NUMERIC,
    borrow_apy                   NUMERIC,

    -- Pricing
    market_price                 NUMERIC,
    oracle_price                 NUMERIC,

    -- Market values
    vault_liquidity_marketvalue  NUMERIC,
    vault_collateral_marketvalue NUMERIC,

    -- Deposit/Borrow TVL
    deposit_tvl                  NUMERIC,
    borrow_tvl                   NUMERIC,

    -- Risk parameters
    loan_to_value_pct            INTEGER,
    liquidation_threshold_pct    INTEGER,
    borrow_factor_pct            INTEGER,

    last_updated                 TIMESTAMPTZ,
    refreshed_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ========================
-- Latest obligation aggregates (single row per market)
-- ========================
CREATE TABLE IF NOT EXISTS kamino_lend.mat_klend_last_obligations (
    market_address                       TEXT PRIMARY KEY,

    -- Counts
    total_obligations                    BIGINT,
    active_obligations                   BIGINT,
    obligations_with_debt                BIGINT,

    -- Portfolio values
    total_collateral_value               NUMERIC,
    total_borrow_value                   NUMERIC,
    total_net_value                      NUMERIC,

    -- Risk metrics
    avg_health_factor                    NUMERIC,
    avg_loan_to_value                    NUMERIC,
    weighted_avg_health_factor_sig       NUMERIC,
    weighted_avg_loan_to_value_sig       NUMERIC,

    -- Debt exposure
    unhealthy_count                      BIGINT,
    bad_debt_count                       BIGINT,
    total_unhealthy_debt                 NUMERIC,
    total_bad_debt                       NUMERIC,
    unhealthy_debt_pct                   NUMERIC,
    bad_debt_pct                         NUMERIC,
    total_liquidatable_value             NUMERIC,

    -- Concentration
    top_10_debt_concentration_pct        NUMERIC,
    top_5_debt_concentration_pct         NUMERIC,
    top_1_debt_concentration_pct         NUMERIC,
    largest_single_obligation_debt       NUMERIC,

    -- Capacity
    total_borrow_capacity_remaining      NUMERIC,
    market_capacity_utilization_pct      NUMERIC,

    last_updated                         TIMESTAMPTZ,
    refreshed_at                         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ========================
-- Latest activity summary (one row per symbol, 24h window)
-- ========================
CREATE TABLE IF NOT EXISTS kamino_lend.mat_klend_last_activities (
    symbol                       TEXT PRIMARY KEY,
    reserve_address              TEXT,

    deposit_vol_24h              NUMERIC DEFAULT 0,
    withdraw_vol_24h             NUMERIC DEFAULT 0,
    borrow_vol_24h               NUMERIC DEFAULT 0,
    repay_vol_24h                NUMERIC DEFAULT 0,
    liquidate_vol_24h            NUMERIC DEFAULT 0,
    liquidate_vol_30d            NUMERIC DEFAULT 0,

    refreshed_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- Refresh procedure: full recompute for all sub-tables
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE kamino_lend.refresh_mat_klend_last()
LANGUAGE plpgsql AS $$
BEGIN
    -- 1. Reserves: latest per reserve from cagg_reserves_5s
    TRUNCATE kamino_lend.mat_klend_last_reserves;

    INSERT INTO kamino_lend.mat_klend_last_reserves (
        reserve_address, market_address, symbol, reserve_type, decimals,
        supply_total, supply_available, supply_borrowed, collateral_total_supply,
        utilization_ratio, supply_apy, borrow_apy,
        market_price, oracle_price,
        vault_liquidity_marketvalue, vault_collateral_marketvalue,
        deposit_tvl, borrow_tvl,
        loan_to_value_pct, liquidation_threshold_pct, borrow_factor_pct,
        last_updated, refreshed_at
    )
    SELECT DISTINCT ON (r.reserve_address)
        r.reserve_address,
        r.market_address,
        r.symbol,
        r.reserve_type_config,
        r.decimals,
        r.supply_total,
        r.supply_available,
        r.supply_borrowed,
        r.collateral_total_supply,
        r.utilization_ratio,
        r.supply_apy,
        r.borrow_apy,
        r.market_price,
        r.oracle_price,
        r.vault_liquidity_marketvalue,
        r.vault_collateral_marketvalue,
        r.deposit_tvl,
        r.borrow_tvl,
        mrt.loan_to_value_pct,
        mrt.liquidation_threshold_pct,
        mrt.borrow_factor_pct,
        r.last_updated,
        NOW()
    FROM kamino_lend.cagg_reserves_5s r
    LEFT JOIN kamino_lend.aux_market_reserve_tokens mrt
        ON r.reserve_address = mrt.reserve_address
    WHERE r.bucket >= NOW() - INTERVAL '1 hour'
    ORDER BY r.reserve_address, r.bucket DESC;

    -- 2. Obligations: latest from cagg_obligations_agg_5s
    TRUNCATE kamino_lend.mat_klend_last_obligations;

    INSERT INTO kamino_lend.mat_klend_last_obligations (
        market_address,
        total_obligations, active_obligations, obligations_with_debt,
        total_collateral_value, total_borrow_value, total_net_value,
        avg_health_factor, avg_loan_to_value,
        weighted_avg_health_factor_sig, weighted_avg_loan_to_value_sig,
        unhealthy_count, bad_debt_count,
        total_unhealthy_debt, total_bad_debt,
        unhealthy_debt_pct, bad_debt_pct,
        total_liquidatable_value,
        top_10_debt_concentration_pct, top_5_debt_concentration_pct,
        top_1_debt_concentration_pct, largest_single_obligation_debt,
        total_borrow_capacity_remaining, market_capacity_utilization_pct,
        last_updated, refreshed_at
    )
    SELECT
        o.market_address,
        o.total_obligations, o.active_obligations, o.obligations_with_debt,
        o.total_collateral_value, o.total_borrow_value, o.total_net_value,
        o.avg_health_factor, o.avg_loan_to_value,
        o.weighted_avg_health_factor_sig, o.weighted_avg_loan_to_value_sig,
        o.unhealthy_count, o.bad_debt_count,
        o.total_unhealthy_debt, o.total_bad_debt,
        o.unhealthy_debt_pct, o.bad_debt_pct,
        o.total_liquidatable_value,
        o.top_10_debt_concentration_pct, o.top_5_debt_concentration_pct,
        o.top_1_debt_concentration_pct, o.largest_single_obligation_debt,
        o.total_borrow_capacity_remaining, o.market_capacity_utilization_pct,
        o.time,
        NOW()
    FROM kamino_lend.cagg_obligations_agg_5s o
    WHERE o.bucket = (SELECT MAX(bucket) FROM kamino_lend.cagg_obligations_agg_5s);

    -- 3. Activities: 24h and 30d rollups
    TRUNCATE kamino_lend.mat_klend_last_activities;

    INSERT INTO kamino_lend.mat_klend_last_activities (
        symbol, reserve_address,
        deposit_vol_24h, withdraw_vol_24h, borrow_vol_24h, repay_vol_24h,
        liquidate_vol_24h, liquidate_vol_30d, refreshed_at
    )
    SELECT
        a24.symbol,
        a24.reserve_address,
        COALESCE(a24.deposit_vol, 0),
        COALESCE(a24.withdraw_vol, 0),
        COALESCE(a24.borrow_vol, 0),
        COALESCE(a24.repay_vol, 0),
        COALESCE(a24.liquidate_vol, 0),
        COALESCE(a30d.liquidate_vol, 0),
        NOW()
    FROM (
        SELECT
            symbol, MAX(reserve_address) AS reserve_address,
            SUM(deposit_vault_sum) AS deposit_vol,
            SUM(withdraw_vault_sum) AS withdraw_vol,
            SUM(borrowing_sum) AS borrow_vol,
            SUM(repay_borrowing_sum) AS repay_vol,
            SUM(liquidate_borrowing_sum) AS liquidate_vol
        FROM kamino_lend.cagg_activities_5s
        WHERE bucket >= NOW() - INTERVAL '24 hours'
        GROUP BY symbol
    ) a24
    LEFT JOIN (
        SELECT
            symbol,
            SUM(liquidate_borrowing_sum) AS liquidate_vol
        FROM kamino_lend.cagg_activities_5s
        WHERE bucket >= NOW() - INTERVAL '30 days'
        GROUP BY symbol
    ) a30d ON a24.symbol = a30d.symbol;
END;
$$;
