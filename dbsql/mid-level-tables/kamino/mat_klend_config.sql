-- mat_klend_config: Pre-computed lending market configuration
-- Eliminates the expensive DISTINCT ON + multi-source joins in v_config
-- Stores one row per reserve with all config parameters.

CREATE TABLE IF NOT EXISTS kamino_lend.mat_klend_config (
    reserve_address                          TEXT PRIMARY KEY,
    market_address                           TEXT,
    symbol                                   TEXT,
    reserve_type                             TEXT,
    reserve_type_evaluated                   TEXT,
    decimals                                 INTEGER,

    -- Supply state
    supply_total                             NUMERIC,
    supply_available                         NUMERIC,
    supply_borrowed                          NUMERIC,
    collateral_total_supply                  NUMERIC,

    -- Risk parameters
    loan_to_value_pct                        INTEGER,
    liquidation_threshold_pct                INTEGER,
    borrow_factor_pct                        INTEGER,

    -- Liquidation parameters
    min_liquidation_bonus_bps                INTEGER,
    max_liquidation_bonus_bps                INTEGER,
    bad_debt_liquidation_bonus_bps           INTEGER,

    -- Limits
    deposit_limit                            NUMERIC,
    borrow_limit                             NUMERIC,

    -- Withdrawal caps
    deposit_withdrawal_cap_capacity          BIGINT,
    deposit_withdrawal_cap_current           BIGINT,
    debt_withdrawal_cap_capacity             BIGINT,
    debt_withdrawal_cap_current              BIGINT,
    utilization_limit_block_borrowing_pct    INTEGER,

    last_updated                             TIMESTAMPTZ,
    refreshed_at                             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Market-level config (one row per lending market)
CREATE TABLE IF NOT EXISTS kamino_lend.mat_klend_config_market (
    market_address                                  TEXT PRIMARY KEY,
    quote_currency                                  TEXT,
    liquidation_max_debt_close_factor_pct            INTEGER,
    insolvency_risk_unhealthy_ltv_pct                INTEGER,
    min_full_liquidation_value_threshold              NUMERIC,
    max_liquidatable_debt_market_value_at_once        NUMERIC,
    global_allowed_borrow_value                       NUMERIC,

    last_updated                                     TIMESTAMPTZ,
    refreshed_at                                     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- Refresh procedure: full recompute
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE kamino_lend.refresh_mat_klend_config()
LANGUAGE plpgsql AS $$
BEGIN
    -- Reserve config
    TRUNCATE kamino_lend.mat_klend_config;

    INSERT INTO kamino_lend.mat_klend_config (
        reserve_address, market_address, symbol, reserve_type, reserve_type_evaluated, decimals,
        supply_total, supply_available, supply_borrowed, collateral_total_supply,
        loan_to_value_pct, liquidation_threshold_pct, borrow_factor_pct,
        min_liquidation_bonus_bps, max_liquidation_bonus_bps, bad_debt_liquidation_bonus_bps,
        deposit_limit, borrow_limit,
        deposit_withdrawal_cap_capacity, deposit_withdrawal_cap_current,
        debt_withdrawal_cap_capacity, debt_withdrawal_cap_current,
        utilization_limit_block_borrowing_pct,
        last_updated, refreshed_at
    )
    SELECT DISTINCT ON (r.reserve_address)
        r.reserve_address,
        r.market_address,
        r.env_symbol,
        r.env_reserve_type,
        r.c_reserve_type_evaluated,
        r.env_decimals,
        r.liquidity_total_supply / POWER(10, r.env_decimals),
        r.liquidity_available_amount / POWER(10, r.env_decimals),
        r.liquidity_borrowed_amount_sf / POWER(2, 60) / POWER(10, r.env_decimals),
        r.collateral_mint_total_supply / POWER(10, r.env_decimals),
        r.loan_to_value_pct,
        r.liquidation_threshold_pct,
        r.borrow_factor_pct,
        r.min_liquidation_bonus_bps,
        r.max_liquidation_bonus_bps,
        r.bad_debt_liquidation_bonus_bps,
        r.deposit_limit / POWER(10, r.env_decimals),
        r.borrow_limit / POWER(10, r.env_decimals),
        r.deposit_withdrawal_cap_config_capacity,
        r.deposit_withdrawal_cap_current_total,
        r.debt_withdrawal_cap_config_capacity,
        r.debt_withdrawal_cap_current_total,
        r.utilization_limit_block_borrowing_above_pct,
        r.time,
        NOW()
    FROM kamino_lend.src_reserves r
    ORDER BY r.reserve_address,
        CASE WHEN r.deposit_limit > 0 AND r.min_liquidation_bonus_bps > 0 THEN 0 ELSE 1 END,
        r.time DESC;

    -- Market config
    TRUNCATE kamino_lend.mat_klend_config_market;

    INSERT INTO kamino_lend.mat_klend_config_market (
        market_address, quote_currency,
        liquidation_max_debt_close_factor_pct,
        insolvency_risk_unhealthy_ltv_pct,
        min_full_liquidation_value_threshold,
        max_liquidatable_debt_market_value_at_once,
        global_allowed_borrow_value,
        last_updated, refreshed_at
    )
    SELECT DISTINCT ON (m.market_address)
        m.market_address,
        m.quote_currency,
        m.liquidation_max_debt_close_factor_pct,
        m.insolvency_risk_unhealthy_ltv_pct,
        m.min_full_liquidation_value_threshold,
        m.max_liquidatable_debt_market_value_at_once,
        m.global_allowed_borrow_value,
        m.time,
        NOW()
    FROM kamino_lend.src_lending_market m
    ORDER BY m.market_address, m.time DESC;
END;
$$;
