-- Kamino Lend - Market Assets View
-- Returns the latest state of all reserve assets in the lending market
-- Joins aux_market_reserve_tokens (static metadata) with the latest src_reserves snapshot
--
-- PERFORMANCE: src_reserves is a TimescaleDB hypertable with tiered (OSM) storage.
-- The previous DISTINCT ON over the full table forced a parallel seq-scan across
-- all chunks INCLUDING the cold OSM chunks (which lack the per-chunk index), then
-- a 35MB external sort. The rewritten version below restricts each LATERAL lookup
-- to the last 24 hours, which keeps the scan inside the hot in-memory chunks where
-- the (reserve_address, time DESC) index is usable. With 5 reserves that have data
-- arriving every minute, 24 hours is a generous safety margin.

CREATE OR REPLACE VIEW kamino_lend.v_market_assets AS
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
    lr.time AS last_updated
FROM kamino_lend.aux_market_reserve_tokens rm
LEFT JOIN LATERAL (
    -- Prefer the latest "fully configured" snapshot (deposit_limit + min_liquidation_bonus_bps both > 0);
    -- fall back to the latest snapshot of any kind. Two LIMIT-1 lookups, then pick the higher-priority one.
    SELECT *
    FROM (
        (
            SELECT r1.*, 0::int AS prio
            FROM kamino_lend.src_reserves r1
            WHERE r1.reserve_address = rm.reserve_address
              AND r1.time >= NOW() - INTERVAL '24 hours'
              AND r1.deposit_limit > 0
              AND r1.min_liquidation_bonus_bps > 0
            ORDER BY r1.time DESC
            LIMIT 1
        )
        UNION ALL
        (
            SELECT r2.*, 1::int AS prio
            FROM kamino_lend.src_reserves r2
            WHERE r2.reserve_address = rm.reserve_address
              AND r2.time >= NOW() - INTERVAL '24 hours'
            ORDER BY r2.time DESC
            LIMIT 1
        )
    ) candidates
    ORDER BY prio
    LIMIT 1
) lr ON true
ORDER BY
    CASE rm.reserve_type WHEN 'borrow' THEN 0 WHEN 'collateral' THEN 1 ELSE 2 END,
    rm.token_symbol;

COMMENT ON VIEW kamino_lend.v_market_assets IS
'Latest state of all reserve assets in the lending market.
Combines static metadata from aux_market_reserve_tokens with the most recent
snapshot from src_reserves (within the last 24 hours, to avoid full-scanning
tiered OSM chunks). All token amounts are human-readable (divided by
10^decimals), rates are percentages, and scaled-fraction fields are decoded.';
