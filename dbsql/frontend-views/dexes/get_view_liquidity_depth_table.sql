-- ============================================================================
-- FUNCTION: get_view_liquidity_depth_table
-- ============================================================================
-- Returns the Liquidity Depth Table data for a specific pool.
-- For each predefined BPS level, calculates the exact swap quantity needed
-- to move the price by that amount using CLMM math (via impact_qsell_from_bps_latest).
--
-- This replaces the previous approach of reading token1_cumul from
-- get_view_tick_dist, which was inaccurate because:
--   1. Tick boundaries don't align with target BPS levels
--   2. Current price sits mid-tick, so the nearest tick boundary
--      understates the actual swap size (especially for small BPS targets)
--   3. token1_cumul represents USDC depth, not the t0 sell quantity
--
-- PARAMETERS:
--   p_protocol: Protocol filter (e.g., 'raydium')
--   p_pair: Token pair filter (e.g., 'USX-USDC')
--
-- RETURNS: One row per BPS level (both positive and negative)
-- ============================================================================

CREATE OR REPLACE FUNCTION dexes.get_view_liquidity_depth_table(
    p_protocol TEXT,
    p_pair TEXT
)
RETURNS TABLE (
    pool_address TEXT,
    protocol TEXT,
    token_pair TEXT,
    current_price_t1_per_t0 NUMERIC,
    bps_target DOUBLE PRECISION,
    price_change_pct TEXT,
    calculated_price NUMERIC,
    swap_size_equivalent DOUBLE PRECISION,
    liquidity_in_band DOUBLE PRECISION,
    pct_of_reserve NUMERIC
) AS $$
DECLARE
    v_pool_address TEXT;
    v_protocol TEXT;
    v_token_pair TEXT;
    v_sqrt_price_x64 NUMERIC(40,0);
    v_mint_decimals_0 SMALLINT;
    v_mint_decimals_1 SMALLINT;
    v_decimal_adjustment DOUBLE PRECISION;
    v_current_price DOUBLE PRECISION;
    v_t0_reserve DOUBLE PRECISION;
    v_t1_reserve DOUBLE PRECISION;
BEGIN
    -- Get the most recent query for this pool
    SELECT
        q.pool_address,
        q.protocol,
        q.token_pair,
        q.sqrt_price_x64,
        q.mint_decimals_0,
        q.mint_decimals_1
    INTO
        v_pool_address,
        v_protocol,
        v_token_pair,
        v_sqrt_price_x64,
        v_mint_decimals_0,
        v_mint_decimals_1
    FROM dexes.src_acct_tickarray_queries q
    WHERE LOWER(q.protocol) = LOWER(p_protocol)
      AND LOWER(q.token_pair) = LOWER(p_pair)
    ORDER BY q.time DESC
    LIMIT 1;

    IF v_pool_address IS NULL THEN
        RETURN;
    END IF;

    -- Calculate current price
    v_decimal_adjustment := POWER(10, v_mint_decimals_0 - v_mint_decimals_1);
    v_current_price := POWER(v_sqrt_price_x64::DOUBLE PRECISION / POWER(2::DOUBLE PRECISION, 64), 2) * v_decimal_adjustment;

    -- Get vault reserves
    SELECT
        v.token_0_value,
        v.token_1_value
    INTO
        v_t0_reserve,
        v_t1_reserve
    FROM dexes.src_acct_vaults v
    WHERE v.pool_address = v_pool_address
    ORDER BY v.time DESC
    LIMIT 1;

    -- Return results for predefined BPS levels
    -- Positive BPS = selling t1 (price goes UP)
    -- Negative BPS = selling t0 (price goes DOWN)
    RETURN QUERY
    WITH bps_levels AS (
        -- Standard liquidity depth table BPS levels
        SELECT unnest(ARRAY[
            100.0, 50.0, 20.0, 10.0, 5.0, 2.0, 1.0,
            -1.0, -2.0, -5.0, -10.0, -20.0, -50.0, -100.0
        ]) AS bps
    ),
    computed AS (
        SELECT
            bl.bps,
            CASE
                WHEN bl.bps > 0 THEN
                    -- Price goes UP: sell t1 to move price up by bps
                    dexes.impact_qsell_from_bps_latest(v_pool_address, 't1', ABS(bl.bps))
                ELSE
                    -- Price goes DOWN: sell t0 to move price down by bps
                    dexes.impact_qsell_from_bps_latest(v_pool_address, 't0', ABS(bl.bps))
            END AS swap_qty
        FROM bps_levels bl
    )
    SELECT
        v_pool_address,
        v_protocol,
        v_token_pair,
        ROUND(v_current_price::NUMERIC, 4),
        c.bps::DOUBLE PRECISION,
        -- Format price change percentage label
        CASE
            WHEN c.bps > 0 THEN '+' || TRIM(TO_CHAR(ABS(c.bps) / 100.0, '990.99')) || '%'
            ELSE '-' || TRIM(TO_CHAR(ABS(c.bps) / 100.0, '990.99')) || '%'
        END,
        -- Calculated price at target BPS
        ROUND((v_current_price * (1 + c.bps / 10000.0))::NUMERIC, 4),
        -- Swap size equivalent (cumulative)
        ROUND(COALESCE(c.swap_qty, 0)::NUMERIC, 0)::DOUBLE PRECISION,
        -- Liquidity in band (difference from previous BPS level)
        ROUND((COALESCE(c.swap_qty, 0) - COALESCE(
            LAG(c.swap_qty) OVER (
                PARTITION BY SIGN(c.bps)
                ORDER BY ABS(c.bps)
            ), 0
        ))::NUMERIC, 0)::DOUBLE PRECISION,
        -- % of counter-token reserve drained
        -- Selling t0 drains t1 from the pool; selling t1 drains t0.
        -- Convert swap_qty to counter-token units via current_price to get
        -- the approximate fraction of the counter-token reserve consumed.
        ROUND(
            CASE
                WHEN c.bps > 0 AND v_t0_reserve > 0 AND v_current_price > 0 THEN
                    -- Selling t1 drains t0: output_t0 ~= swap_qty_t1 / price
                    (COALESCE(c.swap_qty, 0) / v_current_price / v_t0_reserve) * 100
                WHEN c.bps < 0 AND v_t1_reserve > 0 THEN
                    -- Selling t0 drains t1: output_t1 ~= swap_qty_t0 * price
                    (COALESCE(c.swap_qty, 0) * v_current_price / v_t1_reserve) * 100
                ELSE NULL
            END::NUMERIC,
            2
        )
    FROM computed c
    ORDER BY c.bps DESC;
END;
$$ LANGUAGE plpgsql STABLE
SET search_path TO dexes, public;

COMMENT ON FUNCTION dexes.get_view_liquidity_depth_table(TEXT, TEXT) IS
'Returns Liquidity Depth Table data for a specific pool.
For each predefined BPS level (±1, ±2, ±5, ±10, ±20, ±50, ±100 bps),
calculates the exact swap quantity needed to move the price by that amount
using impact_qsell_from_bps_latest (CLMM math with proper tick traversal).

Positive BPS levels = price increase = selling token1 (quantity in t1 units)
Negative BPS levels = price decrease = selling token0 (quantity in t0 units)

Returns:
  - pool_address, protocol, token_pair: Pool identifiers
  - current_price_t1_per_t0: Current pool price
  - bps_target: Signed BPS target (+ve = up, -ve = down)
  - price_change_pct: Formatted percentage label (e.g., "+0.01%", "-0.05%")
  - calculated_price: Target price at BPS level
  - swap_size_equivalent: Cumulative token quantity needed to reach this BPS level
  - liquidity_in_band: Marginal token quantity in this BPS band
  - pct_of_reserve: approximate % of the counter-token reserve drained by this swap
    (selling t0 drains t1, selling t1 drains t0; converted via current_price)

This function replaces the previous approach of using token0_cumul/token1_cumul
from get_view_tick_dist, which was inaccurate for small BPS targets because
tick boundaries do not align with the target BPS levels.';
