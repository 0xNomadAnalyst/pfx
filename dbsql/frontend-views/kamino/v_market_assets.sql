-- Kamino Lend - Market Assets View
-- Returns the latest state of all reserve assets in the lending market
-- Joins aux_market_reserve_tokens (static metadata) with the latest src_reserves snapshot

CREATE OR REPLACE VIEW kamino_lend.v_market_assets AS
WITH latest_reserves AS (
    SELECT DISTINCT ON (r.reserve_address)
        r.reserve_address,
        r.reserve_status,
        r.loan_to_value_pct,
        r.liquidation_threshold_pct,
        r.borrow_factor_pct,
        r.oracle_price,
        r.liquidity_available_amount,
        r.liquidity_borrowed_amount_sf,
        r.liquidity_total_supply,
        r.collateral_mint_total_supply,
        r.utilization_ratio,
        r.supply_apy,
        r.borrow_apy,
        r.deposit_limit,
        r.borrow_limit,
        r.min_liquidation_bonus_bps,
        r.max_liquidation_bonus_bps,
        r.bad_debt_liquidation_bonus_bps,
        r.utilization_limit_block_borrowing_above_pct,
        r.env_decimals,
        r.time AS last_updated
    FROM kamino_lend.src_reserves r
    JOIN kamino_lend.aux_market_reserve_tokens rm ON r.reserve_address = rm.reserve_address
    ORDER BY r.reserve_address,
        CASE WHEN r.deposit_limit > 0 AND r.min_liquidation_bonus_bps > 0 THEN 0 ELSE 1 END,
        r.time DESC
)
SELECT
    rm.token_symbol,
    rm.reserve_type,
    lr.reserve_status,
    rm.reserve_address,
    rm.token_mint,
    rm.token_decimals,
    lr.loan_to_value_pct,
    lr.liquidation_threshold_pct,
    lr.borrow_factor_pct,
    lr.oracle_price,
    ROUND((lr.liquidity_available_amount / POWER(10, lr.env_decimals))::NUMERIC, 2)   AS available_tokens,
    ROUND((lr.liquidity_borrowed_amount_sf / POWER(2, 60) / POWER(10, lr.env_decimals))::NUMERIC, 2) AS borrowed_tokens,
    ROUND((lr.liquidity_total_supply / POWER(10, lr.env_decimals))::NUMERIC, 2)       AS total_supply,
    ROUND((lr.collateral_mint_total_supply / POWER(10, lr.env_decimals))::NUMERIC, 2) AS collateral_supply,
    ROUND(lr.utilization_ratio * 100, 1) AS utilization_pct,
    ROUND(lr.supply_apy * 100, 2)        AS supply_apy_pct,
    ROUND(lr.borrow_apy * 100, 2)        AS borrow_apy_pct,
    ROUND((lr.deposit_limit / POWER(10, lr.env_decimals))::NUMERIC, 0)               AS deposit_limit,
    ROUND((lr.borrow_limit / POWER(10, lr.env_decimals))::NUMERIC, 0)                AS borrow_limit,
    lr.min_liquidation_bonus_bps,
    lr.max_liquidation_bonus_bps,
    lr.bad_debt_liquidation_bonus_bps,
    lr.utilization_limit_block_borrowing_above_pct,
    lr.last_updated
FROM kamino_lend.aux_market_reserve_tokens rm
LEFT JOIN latest_reserves lr ON rm.reserve_address = lr.reserve_address
ORDER BY
    CASE rm.reserve_type WHEN 'borrow' THEN 0 WHEN 'collateral' THEN 1 ELSE 2 END,
    rm.token_symbol;

COMMENT ON VIEW kamino_lend.v_market_assets IS
'Latest state of all reserve assets in the lending market.
Combines static metadata from aux_market_reserve_tokens with the most recent
snapshot from src_reserves. All token amounts are human-readable (divided by
10^decimals), rates are percentages, and scaled-fraction fields are decoded.';
