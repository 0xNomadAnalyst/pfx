-- v_config: Schema-compatible read from mat_klend_config tables
-- Outputs the SAME column names as the Solstice production v_config so the
-- Python page service (kamino.py) works identically for both pipelines.

DROP VIEW IF EXISTS kamino_lend.v_config CASCADE;
CREATE OR REPLACE VIEW kamino_lend.v_config AS
WITH reserve_config AS (
    SELECT c.*
    FROM kamino_lend.mat_klend_config c
),
mkt AS (
    SELECT * FROM kamino_lend.mat_klend_config_market LIMIT 1
),
brw_arr AS (
    SELECT
        array_agg(c.symbol ORDER BY c.symbol)
            AS symbols,
        array_agg(
            ROUND(c.borrow_factor_pct::NUMERIC, 1) ORDER BY c.symbol
        ) AS risk_weight_arr,
        array_agg(
            ROUND(COALESCE(c.min_liquidation_bonus_bps, 0)::NUMERIC, 0) ORDER BY c.symbol
        ) AS liq_fee_unhealthy_min_arr,
        array_agg(
            ROUND(COALESCE(c.max_liquidation_bonus_bps, 0)::NUMERIC, 0) ORDER BY c.symbol
        ) AS liq_fee_unhealthy_max_arr,
        array_agg(
            ROUND(COALESCE(c.bad_debt_liquidation_bonus_bps, 0)::NUMERIC, 0) ORDER BY c.symbol
        ) AS liq_fee_bad_arr,
        array_agg(
            ROUND(COALESCE(c.deposit_limit, 0)::NUMERIC, 0) ORDER BY c.symbol
        ) AS deposit_max_limit_arr,
        array_agg(
            ROUND(COALESCE(c.borrow_limit, 0)::NUMERIC, 0) ORDER BY c.symbol
        ) AS borrow_max_limit_arr,
        array_agg(
            ROUND(COALESCE(c.deposit_withdrawal_cap_capacity, 0)::NUMERIC, 0) ORDER BY c.symbol
        ) AS withdrawal_cap_24hr_arr,
        array_agg(
            ROUND(COALESCE(c.debt_withdrawal_cap_capacity, 0)::NUMERIC, 0) ORDER BY c.symbol
        ) AS borrow_cap_24hr_arr,
        array_agg(
            ROUND(COALESCE(c.utilization_limit_block_borrowing_pct, 0)::NUMERIC, 1) ORDER BY c.symbol
        ) AS util_borrow_limit_arr
    FROM reserve_config c
    WHERE c.reserve_type = 'borrow'
),
coll_arr AS (
    SELECT
        array_agg(c.symbol ORDER BY c.symbol) AS symbols,
        array_agg(
            ROUND(c.loan_to_value_pct::NUMERIC, 1) ORDER BY c.symbol
        ) AS ltv_new_loan_arr,
        array_agg(
            ROUND(c.liquidation_threshold_pct::NUMERIC, 1) ORDER BY c.symbol
        ) AS ltv_unhealthy_arr
    FROM reserve_config c
    WHERE c.reserve_type = 'collateral'
)
SELECT
    brw_arr.symbols                             AS reserve_brw_all_symbols_array,
    coll_arr.symbols                            AS reserve_coll_all_symbols_array,
    mkt.quote_currency                          AS market_quote_currency,
    ROUND(mkt.global_allowed_borrow_value::NUMERIC, 0)
                                                AS market_user_borrow_limit,
    brw_arr.risk_weight_arr                     AS reserve_brw_all_risk_weight_array,
    coll_arr.ltv_new_loan_arr                   AS reserve_coll_all_ltv_new_loan_array,
    coll_arr.ltv_unhealthy_arr                  AS reserve_coll_all_ltv_unhealthy_array,
    ROUND(mkt.insolvency_risk_unhealthy_ltv_pct::NUMERIC, 1)
                                                AS market_ltv_bad,
    ROUND(mkt.liquidation_max_debt_close_factor_pct::NUMERIC, 1)
                                                AS market_liquidatable_unhealthy_share,
    ROUND(mkt.min_full_liquidation_value_threshold::NUMERIC, 0)
                                                AS market_liquidatable_small_loan_full,
    ROUND(mkt.max_liquidatable_debt_market_value_at_once::NUMERIC, 0)
                                                AS market_liquidatable_max_value,
    brw_arr.liq_fee_unhealthy_min_arr           AS reserve_brw_all_liquidation_fee_unhealthy_min_array,
    brw_arr.liq_fee_unhealthy_max_arr           AS reserve_brw_all_liquidation_fee_unhealthy_max_array,
    brw_arr.liq_fee_bad_arr                     AS reserve_brw_all_liquidation_fee_bad_array,
    brw_arr.deposit_max_limit_arr               AS reserve_brw_all_deposit_max_limit_array,
    brw_arr.borrow_max_limit_arr                AS reserve_brw_all_borrow_max_limit_array,
    brw_arr.withdrawal_cap_24hr_arr             AS reserve_brw_all_withdrawal_cap_24hr_array,
    brw_arr.borrow_cap_24hr_arr                 AS reserve_brw_all_borrow_cap_24hr_array,
    brw_arr.util_borrow_limit_arr               AS reserve_brw_all_utilization_borrow_limit_array
FROM mkt
CROSS JOIN brw_arr
CROSS JOIN coll_arr;
