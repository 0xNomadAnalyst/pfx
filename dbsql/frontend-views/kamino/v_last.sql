-- v_last: Direct read from mat_klend_last_* tables
-- Same output pattern as the original (kamino/dbsql/views/v_last.sql)
-- Reads from pre-computed snapshot tables instead of scanning source tables.
-- Uses dynamic reserve pivoting (no hardcoded addresses).

CREATE OR REPLACE VIEW kamino_lend.v_last AS
WITH borrow_reserves AS (
    SELECT
        r.reserve_address,
        r.symbol,
        r.supply_total,
        r.supply_available,
        r.supply_borrowed,
        r.utilization_ratio,
        r.supply_apy,
        r.borrow_apy,
        r.market_price,
        r.oracle_price,
        r.vault_liquidity_marketvalue,
        r.deposit_tvl,
        r.borrow_tvl,
        r.market_address,
        r.last_updated,
        ROW_NUMBER() OVER (ORDER BY r.symbol) AS rn
    FROM kamino_lend.mat_klend_last_reserves r
    WHERE r.reserve_type = 'borrow'
),
collateral_reserves AS (
    SELECT
        r.reserve_address,
        r.symbol,
        r.collateral_total_supply,
        r.vault_collateral_marketvalue,
        r.market_address,
        ROW_NUMBER() OVER (ORDER BY r.symbol) AS rn
    FROM kamino_lend.mat_klend_last_reserves r
    WHERE r.reserve_type = 'collateral'
),
obl AS (
    SELECT * FROM kamino_lend.mat_klend_last_obligations LIMIT 1
),
act AS (
    SELECT * FROM kamino_lend.mat_klend_last_activities
),
brw1 AS (SELECT * FROM borrow_reserves WHERE rn = 1),
brw2 AS (SELECT * FROM borrow_reserves WHERE rn = 2),
coll1 AS (SELECT * FROM collateral_reserves WHERE rn = 1),
brw_agg AS (
    SELECT
        SUM(supply_total) AS total_supply,
        SUM(supply_available) AS total_available,
        SUM(supply_borrowed) AS total_borrowed,
        SUM(supply_total * market_price) AS total_supply_mktval,
        SUM(supply_borrowed * market_price) AS total_borrowed_mktval,
        SUM(vault_liquidity_marketvalue) AS total_available_mktval
    FROM borrow_reserves
),
coll_agg AS (
    SELECT SUM(collateral_total_supply) AS total_collateral
    FROM collateral_reserves
)
SELECT
    -- Borrow reserve 1
    brw1.symbol AS reserve_brw1_symbol,
    brw1.reserve_address AS reserve_brw1_address,
    ROUND(brw1.supply_total::NUMERIC, 0) AS reserve_brw1_supply_total,
    ROUND(brw1.utilization_ratio * 100, 1) AS reserve_brw1_utilization_pct,
    ROUND(brw1.supply_apy * 100, 2) AS reserve_brw1_supply_apy,
    ROUND(brw1.borrow_apy * 100, 2) AS reserve_brw1_borrow_apy,
    ROUND(brw1.supply_available::NUMERIC, 0) AS reserve_brw1_available,
    ROUND(brw1.supply_borrowed::NUMERIC, 0) AS reserve_brw1_borrowed,
    ROUND((brw1.supply_borrowed * brw1.market_price)::NUMERIC, 0) AS reserve_brw1_borrowed_mktvalue,
    ROUND(brw1.vault_liquidity_marketvalue::NUMERIC, 0) AS reserve_brw1_available_mktvalue,
    ROUND(brw1.oracle_price::NUMERIC, 6) AS reserve_brw1_oracle_price,
    -- Borrow reserve 2
    brw2.symbol AS reserve_brw2_symbol,
    brw2.reserve_address AS reserve_brw2_address,
    ROUND(brw2.supply_total::NUMERIC, 0) AS reserve_brw2_supply_total,
    ROUND(brw2.utilization_ratio * 100, 1) AS reserve_brw2_utilization_pct,
    ROUND(brw2.supply_apy * 100, 2) AS reserve_brw2_supply_apy,
    ROUND(brw2.borrow_apy * 100, 2) AS reserve_brw2_borrow_apy,
    ROUND(brw2.supply_available::NUMERIC, 0) AS reserve_brw2_available,
    ROUND(brw2.supply_borrowed::NUMERIC, 0) AS reserve_brw2_borrowed,
    ROUND((brw2.supply_borrowed * brw2.market_price)::NUMERIC, 0) AS reserve_brw2_borrowed_mktvalue,
    ROUND(brw2.vault_liquidity_marketvalue::NUMERIC, 0) AS reserve_brw2_available_mktvalue,
    ROUND(brw2.oracle_price::NUMERIC, 6) AS reserve_brw2_oracle_price,
    -- Aggregate borrow
    ROUND(ba.total_supply::NUMERIC, 0) AS reserve_brw_all_supply_total,
    ROUND(ba.total_available_mktval::NUMERIC, 0) AS reserve_brw_all_available_mktvalue,
    ROUND(ba.total_borrowed_mktval::NUMERIC, 0) AS reserve_brw_all_borrowed_mktvalue,
    ROUND(ba.total_supply_mktval::NUMERIC, 0) AS reserve_brw_all_supply_total_mktvalue,
    ROUND((ba.total_borrowed_mktval / NULLIF(ba.total_supply_mktval, 0) * 100)::NUMERIC, 1) AS reserve_brw_all_utilization_pct,
    -- Collateral
    coll1.symbol AS reserve_coll1_symbol,
    coll1.reserve_address AS reserve_coll1_address,
    ROUND(coll1.collateral_total_supply::NUMERIC, 0) AS reserve_coll1_collateral,
    ROUND(ca.total_collateral::NUMERIC, 0) AS reserve_coll_all_collateral,
    -- Obligations
    ROUND(obl.total_collateral_value::NUMERIC, 0) AS obl_total_collateral_value,
    ROUND(obl.total_borrow_value::NUMERIC, 0) AS obl_total_borrow_value,
    obl.obligations_with_debt,
    ROUND(obl.weighted_avg_health_factor_sig, 2) AS obl_wtd_avg_health_factor,
    ROUND(obl.weighted_avg_loan_to_value_sig, 1) AS obl_wtd_avg_ltv,
    ROUND(obl.total_unhealthy_debt::NUMERIC, 0) AS obl_total_unhealthy_debt,
    ROUND(obl.total_bad_debt::NUMERIC, 0) AS obl_total_bad_debt,
    ROUND((COALESCE(obl.total_unhealthy_debt, 0) + COALESCE(obl.total_bad_debt, 0))::NUMERIC, 0) AS obl_total_at_risk_debt,
    ROUND(obl.unhealthy_debt_pct, 1) AS obl_unhealthy_debt_pct,
    ROUND(obl.bad_debt_pct, 1) AS obl_bad_debt_pct,
    ROUND(obl.total_liquidatable_value::NUMERIC, 0) AS obl_total_liquidatable_value,
    ROUND(obl.top_10_debt_concentration_pct, 1) AS obl_top_10_debt_concentration_pct,
    -- 24h activities
    ROUND(COALESCE((SELECT deposit_vol_24h FROM act WHERE symbol = brw1.symbol), 0)::NUMERIC, 0) AS reserve_brw1_deposit_vol_24h,
    ROUND(COALESCE((SELECT withdraw_vol_24h FROM act WHERE symbol = brw1.symbol), 0)::NUMERIC, 0) AS reserve_brw1_withdraw_vol_24h,
    ROUND(COALESCE((SELECT borrow_vol_24h FROM act WHERE symbol = brw1.symbol), 0)::NUMERIC, 0) AS reserve_brw1_borrow_vol_24h,
    ROUND(COALESCE((SELECT repay_vol_24h FROM act WHERE symbol = brw1.symbol), 0)::NUMERIC, 0) AS reserve_brw1_repay_vol_24h,
    ROUND(COALESCE((SELECT deposit_vol_24h FROM act WHERE symbol = brw2.symbol), 0)::NUMERIC, 0) AS reserve_brw2_deposit_vol_24h,
    ROUND(COALESCE((SELECT withdraw_vol_24h FROM act WHERE symbol = brw2.symbol), 0)::NUMERIC, 0) AS reserve_brw2_withdraw_vol_24h,
    ROUND(COALESCE((SELECT borrow_vol_24h FROM act WHERE symbol = brw2.symbol), 0)::NUMERIC, 0) AS reserve_brw2_borrow_vol_24h,
    ROUND(COALESCE((SELECT repay_vol_24h FROM act WHERE symbol = brw2.symbol), 0)::NUMERIC, 0) AS reserve_brw2_repay_vol_24h,
    -- Metadata
    brw1.market_address,
    GREATEST(brw1.last_updated, brw2.last_updated) AS last_updated
FROM brw1
FULL OUTER JOIN brw2 ON TRUE
LEFT JOIN coll1 ON TRUE
LEFT JOIN obl ON TRUE
CROSS JOIN brw_agg ba
CROSS JOIN coll_agg ca;
