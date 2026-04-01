-- v_last: Schema-compatible read from mat_klend_last_* tables
-- Outputs the SAME column names as the Solstice production v_last so the
-- Python page service (kamino.py) works identically for both pipelines.
-- Uses dynamic array aggregation — no hardcoded reserve addresses.

DROP VIEW IF EXISTS kamino_lend.v_last CASCADE;
CREATE OR REPLACE VIEW kamino_lend.v_last AS
WITH borrow_reserves AS (
    SELECT
        r.reserve_address, r.symbol, r.supply_total, r.supply_available,
        r.supply_borrowed, r.utilization_ratio, r.supply_apy, r.borrow_apy,
        r.market_price, r.oracle_price, r.vault_liquidity_marketvalue,
        r.market_address, r.last_updated
    FROM kamino_lend.mat_klend_last_reserves r
    WHERE r.reserve_type = 'borrow'
),
collateral_reserves AS (
    SELECT
        r.reserve_address, r.symbol, r.collateral_total_supply,
        r.vault_collateral_marketvalue, r.market_address
    FROM kamino_lend.mat_klend_last_reserves r
    WHERE r.reserve_type = 'collateral'
),
obl AS (
    SELECT * FROM kamino_lend.mat_klend_last_obligations LIMIT 1
),
brw_agg AS (
    SELECT
        SUM(supply_borrowed * market_price)   AS total_borrowed_mktval,
        SUM(vault_liquidity_marketvalue)       AS total_available_mktval,
        SUM(supply_total * market_price)       AS total_supply_mktval
    FROM borrow_reserves
),
brw_arr AS (
    SELECT
        array_agg(ROUND(b.utilization_ratio * 100, 1) ORDER BY b.symbol)
            AS utilization_pct_arr,
        array_agg(b.symbol ORDER BY b.symbol)
            AS symbols_arr,
        array_agg(
            ROUND(CASE WHEN agg.total_borrowed_mktval > 0
                THEN b.supply_borrowed * b.market_price
                     / agg.total_borrowed_mktval * 100
                ELSE 0 END::NUMERIC, 1)
            ORDER BY b.symbol
        ) AS shares_pct_arr,
        array_agg(ROUND(b.borrow_apy * 100, 2) ORDER BY b.symbol)
            AS borrow_apy_arr,
        array_agg(ROUND(b.supply_apy * 100, 2) ORDER BY b.symbol)
            AS supply_apy_arr,
        array_agg(ROUND(COALESCE(a.borrow_vol_24h, 0)::NUMERIC, 0) ORDER BY b.symbol)
            AS borrow_vol_24h_arr,
        array_agg(ROUND(COALESCE(a.repay_vol_24h, 0)::NUMERIC, 0) ORDER BY b.symbol)
            AS repay_vol_24h_arr,
        array_agg(ROUND(COALESCE(a.liquidate_vol_30d, 0)::NUMERIC, 0) ORDER BY b.symbol)
            AS liquidated_vol_30d_arr,
        array_agg(ROUND(COALESCE(a.withdraw_vol_24h, 0)::NUMERIC, 0) ORDER BY b.symbol)
            AS withdraw_vol_24h_arr,
        array_agg(ROUND(COALESCE(a.deposit_vol_24h, 0)::NUMERIC, 0) ORDER BY b.symbol)
            AS deposit_vol_24h_arr,
        array_agg(NULL::NUMERIC ORDER BY b.symbol)
            AS liquidated_count_30d_arr,
        array_agg(NULL::NUMERIC ORDER BY b.symbol)
            AS liquidated_avg_size_arr
    FROM borrow_reserves b
    LEFT JOIN kamino_lend.mat_klend_last_activities a ON b.symbol = a.symbol
    CROSS JOIN brw_agg agg
),
coll_agg AS (
    SELECT
        SUM(vault_collateral_marketvalue) AS total_coll_mktval
    FROM collateral_reserves
),
coll_arr AS (
    SELECT
        array_agg(
            ROUND(CASE WHEN agg.total_coll_mktval > 0
                THEN c.vault_collateral_marketvalue / agg.total_coll_mktval * 100
                ELSE 0 END::NUMERIC, 1)
            ORDER BY c.symbol
        ) AS shares_pct_arr,
        array_agg(c.symbol ORDER BY c.symbol) AS symbols_arr
    FROM collateral_reserves c
    CROSS JOIN coll_agg agg
)
SELECT
    brw_arr.utilization_pct_arr         AS reserve_brw_all_utilization_pct_array,
    brw_arr.symbols_arr                 AS reserve_brw_all_symbols_array,
    ROUND(ba.total_borrowed_mktval::NUMERIC, 0)
                                        AS reserve_brw_all_borrowed,
    obl.obligations_with_debt           AS obl_debt_borrow_nonzero_count,
    ROUND((obl.total_borrow_value
           / NULLIF(obl.obligations_with_debt, 0))::NUMERIC, 0)
                                        AS obl_loan_avg_size,
    brw_arr.shares_pct_arr              AS reserve_brw_all_shares_pct_array,
    ROUND(obl.weighted_avg_loan_to_value_sig, 1)
                                        AS obl_ltv_weighted_avg_sig,
    ROUND(obl.weighted_avg_health_factor_sig, 2)
                                        AS obl_hf_weighted_avg_sig,
    ROUND(ca.total_coll_mktval::NUMERIC, 0)
                                        AS reserve_coll_all_collateral,
    ROUND(obl.unhealthy_debt_pct, 2)    AS obl_debt_total_unhealthy_pct,
    coll_arr.shares_pct_arr             AS reserve_coll_all_shares_pct_array,
    coll_arr.symbols_arr                AS reserve_coll_all_symbols_array,
    COALESCE(obl.zero_borrow_count, 0::BIGINT)
                                        AS obl_debt_borrow_zero_use_count,
    COALESCE(obl.zero_borrow_capacity, 0::NUMERIC)
                                        AS obl_debt_borrow_zero_use_capacity,
    brw_arr.borrow_apy_arr              AS reserve_brw_all_borrow_apy_array,
    brw_arr.supply_apy_arr              AS reserve_brw_all_supply_apy_array,
    brw_arr.borrow_vol_24h_arr          AS reserve_brw_all_borrow_vol_24h_array,
    brw_arr.repay_vol_24h_arr           AS reserve_brw_all_repay_vol_24h_array,
    brw_arr.liquidated_vol_30d_arr      AS reserve_brw_all_liquidated_vol_30d_array,
    brw_arr.liquidated_count_30d_arr    AS reserve_brw_all_liquidated_count_30d_array,
    brw_arr.withdraw_vol_24h_arr        AS reserve_brw_all_withdraw_vol_24h_array,
    brw_arr.deposit_vol_24h_arr         AS reserve_brw_all_deposit_vol_24h_array,
    brw_arr.liquidated_avg_size_arr     AS reserve_brw_all_liquidated_avg_size_array,
    obl.last_liquidation_days_ago       AS last_liquidation_days_ago,
    ROUND((ca.total_coll_mktval
           - COALESCE(obl.total_liquidatable_value, 0))::NUMERIC, 0)
                                        AS reserve_coll_all_collateral_less_liquidatable_mktval,
    ROUND(obl.total_liquidatable_value::NUMERIC, 0)
                                        AS obl_liquidatable_value,
    ROUND((ba.total_borrowed_mktval
           - COALESCE(obl.total_unhealthy_debt, 0)
           - COALESCE(obl.total_bad_debt, 0))::NUMERIC, 0)
                                        AS reserve_brw_all_borrowed_less_debt_at_risk_mktval,
    ROUND(ba.total_available_mktval::NUMERIC, 0)
                                        AS reserve_brw_all_available_mktval,
    ROUND(obl.total_unhealthy_debt::NUMERIC, 0)
                                        AS obl_debt_total_unhealthy,
    ROUND(obl.total_bad_debt::NUMERIC, 0)
                                        AS obl_debt_total_bad,
    NULL::NUMERIC                       AS reserve_eusx_price_stddev_7d_pct,
    NULL::NUMERIC                       AS reserve_eusx_price_2sigma_7d_pct,
    NULL::NUMERIC                       AS reserve_usx_price_stddev_7d_pct,
    NULL::NUMERIC                       AS reserve_usx_price_2sigma_7d_pct
FROM brw_agg ba
CROSS JOIN coll_agg ca
CROSS JOIN brw_arr
CROSS JOIN coll_arr
LEFT JOIN obl ON TRUE;
