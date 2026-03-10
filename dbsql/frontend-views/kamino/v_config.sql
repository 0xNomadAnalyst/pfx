-- v_config: Direct read from mat_klend_config tables
-- Same output pattern as the original (kamino/dbsql/views/v_config.sql)
-- Reads from pre-computed config tables instead of scanning source tables.

CREATE OR REPLACE VIEW kamino_lend.v_config AS
WITH reserve_config AS (
    SELECT
        c.*,
        ROW_NUMBER() OVER (
            PARTITION BY c.reserve_type ORDER BY c.symbol
        ) AS rn
    FROM kamino_lend.mat_klend_config c
),
brw1 AS (SELECT * FROM reserve_config WHERE reserve_type = 'borrow' AND rn = 1),
brw2 AS (SELECT * FROM reserve_config WHERE reserve_type = 'borrow' AND rn = 2),
coll1 AS (SELECT * FROM reserve_config WHERE reserve_type = 'collateral' AND rn = 1),
mkt AS (SELECT * FROM kamino_lend.mat_klend_config_market LIMIT 1),
brw_agg AS (
    SELECT
        SUM(supply_total) AS total_supply,
        SUM(supply_available) AS total_available,
        SUM(supply_borrowed) AS total_borrowed
    FROM reserve_config
    WHERE reserve_type = 'borrow'
),
coll_agg AS (
    SELECT SUM(collateral_total_supply) AS total_collateral
    FROM reserve_config
    WHERE reserve_type = 'collateral'
),
brw_arrays AS (
    SELECT
        array_agg(symbol ORDER BY symbol) AS symbols,
        array_agg(reserve_address ORDER BY symbol) AS addresses,
        array_agg(loan_to_value_pct ORDER BY symbol) AS ltv_pcts,
        array_agg(liquidation_threshold_pct ORDER BY symbol) AS liq_threshold_pcts,
        array_agg(borrow_factor_pct ORDER BY symbol) AS borrow_factor_pcts
    FROM reserve_config
    WHERE reserve_type = 'borrow'
),
coll_arrays AS (
    SELECT
        array_agg(symbol ORDER BY symbol) AS symbols,
        array_agg(reserve_address ORDER BY symbol) AS addresses,
        array_agg(loan_to_value_pct ORDER BY symbol) AS ltv_pcts,
        array_agg(liquidation_threshold_pct ORDER BY symbol) AS liq_threshold_pcts
    FROM reserve_config
    WHERE reserve_type = 'collateral'
)
SELECT
    -- Borrow reserve 1
    brw1.symbol AS reserve_brw1_symbol,
    brw1.reserve_address AS reserve_brw1_address,
    brw1.loan_to_value_pct AS reserve_brw1_ltv_pct,
    brw1.liquidation_threshold_pct AS reserve_brw1_liq_threshold_pct,
    brw1.borrow_factor_pct AS reserve_brw1_borrow_factor_pct,
    brw1.min_liquidation_bonus_bps AS reserve_brw1_min_liq_bonus_bps,
    brw1.max_liquidation_bonus_bps AS reserve_brw1_max_liq_bonus_bps,
    brw1.bad_debt_liquidation_bonus_bps AS reserve_brw1_bad_debt_liq_bonus_bps,
    ROUND(brw1.deposit_limit::NUMERIC, 0) AS reserve_brw1_deposit_limit,
    ROUND(brw1.borrow_limit::NUMERIC, 0) AS reserve_brw1_borrow_limit,
    brw1.deposit_withdrawal_cap_capacity AS reserve_brw1_deposit_cap,
    brw1.debt_withdrawal_cap_capacity AS reserve_brw1_debt_cap,
    brw1.utilization_limit_block_borrowing_pct AS reserve_brw1_util_block_pct,
    -- Borrow reserve 2
    brw2.symbol AS reserve_brw2_symbol,
    brw2.reserve_address AS reserve_brw2_address,
    brw2.loan_to_value_pct AS reserve_brw2_ltv_pct,
    brw2.liquidation_threshold_pct AS reserve_brw2_liq_threshold_pct,
    brw2.borrow_factor_pct AS reserve_brw2_borrow_factor_pct,
    brw2.min_liquidation_bonus_bps AS reserve_brw2_min_liq_bonus_bps,
    brw2.max_liquidation_bonus_bps AS reserve_brw2_max_liq_bonus_bps,
    brw2.bad_debt_liquidation_bonus_bps AS reserve_brw2_bad_debt_liq_bonus_bps,
    ROUND(brw2.deposit_limit::NUMERIC, 0) AS reserve_brw2_deposit_limit,
    ROUND(brw2.borrow_limit::NUMERIC, 0) AS reserve_brw2_borrow_limit,
    brw2.deposit_withdrawal_cap_capacity AS reserve_brw2_deposit_cap,
    brw2.debt_withdrawal_cap_capacity AS reserve_brw2_debt_cap,
    brw2.utilization_limit_block_borrowing_pct AS reserve_brw2_util_block_pct,
    -- Collateral reserve 1
    coll1.symbol AS reserve_coll1_symbol,
    coll1.reserve_address AS reserve_coll1_address,
    coll1.loan_to_value_pct AS reserve_coll1_ltv_pct,
    coll1.liquidation_threshold_pct AS reserve_coll1_liq_threshold_pct,
    -- Aggregate borrow
    ROUND(ba.total_supply::NUMERIC, 0) AS reserve_brw_all_supply_total,
    ROUND(ba.total_available::NUMERIC, 0) AS reserve_brw_all_available,
    ROUND(ba.total_borrowed::NUMERIC, 0) AS reserve_brw_all_borrowed,
    -- Aggregate collateral
    ROUND(ca.total_collateral::NUMERIC, 0) AS reserve_coll_all_collateral,
    -- Market params
    mkt.liquidation_max_debt_close_factor_pct AS mkt_liquidation_max_debt_close_factor_pct,
    mkt.insolvency_risk_unhealthy_ltv_pct AS mkt_insolvency_risk_unhealthy_ltv_pct,
    ROUND(mkt.min_full_liquidation_value_threshold::NUMERIC, 0) AS mkt_min_full_liq_value_threshold,
    ROUND(mkt.max_liquidatable_debt_market_value_at_once::NUMERIC, 0) AS mkt_max_liq_debt_at_once,
    ROUND(mkt.global_allowed_borrow_value::NUMERIC, 0) AS mkt_global_allowed_borrow_value,
    -- Arrays
    brw_arr.symbols AS borrow_reserve_symbols,
    brw_arr.addresses AS borrow_reserve_addresses,
    brw_arr.ltv_pcts AS borrow_reserve_ltv_pcts,
    brw_arr.liq_threshold_pcts AS borrow_reserve_liq_threshold_pcts,
    brw_arr.borrow_factor_pcts AS borrow_reserve_borrow_factor_pcts,
    coll_arr.symbols AS collateral_reserve_symbols,
    coll_arr.addresses AS collateral_reserve_addresses,
    coll_arr.ltv_pcts AS collateral_reserve_ltv_pcts,
    coll_arr.liq_threshold_pcts AS collateral_reserve_liq_threshold_pcts,
    -- Metadata
    mkt.market_address,
    GREATEST(brw1.last_updated, brw2.last_updated) AS last_updated
FROM brw1
FULL OUTER JOIN brw2 ON TRUE
LEFT JOIN coll1 ON TRUE
LEFT JOIN mkt ON TRUE
CROSS JOIN brw_agg ba
CROSS JOIN coll_agg ca
CROSS JOIN brw_arrays brw_arr
CROSS JOIN coll_arrays coll_arr;
