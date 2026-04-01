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
--   p_invert: When TRUE, display prices as t0/t1 and negate BPS targets
--
-- RETURNS: One row per BPS level (both positive and negative)
-- ============================================================================

DROP FUNCTION IF EXISTS dexes.get_view_liquidity_depth_table(TEXT, TEXT);
CREATE OR REPLACE FUNCTION dexes.get_view_liquidity_depth_table(
    p_protocol TEXT,
    p_pair TEXT,
    p_invert BOOLEAN DEFAULT FALSE
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
    v_display_price DOUBLE PRECISION;
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
    WHERE q.protocol = p_protocol
      AND q.token_pair = p_pair
    ORDER BY q.block_time DESC
    LIMIT 1;

    IF v_pool_address IS NULL THEN
        RETURN;
    END IF;

    -- Calculate current price (always in canonical t1/t0 basis internally)
    v_decimal_adjustment := POWER(10, v_mint_decimals_0 - v_mint_decimals_1);
    v_current_price := POWER(v_sqrt_price_x64::DOUBLE PRECISION / POWER(2::DOUBLE PRECISION, 64), 2) * v_decimal_adjustment;

    -- Display price: inverted when requested
    v_display_price := CASE WHEN p_invert THEN 1.0 / NULLIF(v_current_price, 0) ELSE v_current_price END;

    -- Get vault reserves
    SELECT
        v.token_0_value,
        v.token_1_value
    INTO
        v_t0_reserve,
        v_t1_reserve
    FROM dexes.cagg_vaults_5s v
    WHERE v.pool_address = v_pool_address
    ORDER BY v.bucket_time DESC
    LIMIT 1;

    -- Return results for predefined BPS levels
    -- Normal:   Positive BPS = selling t1 (price goes UP);   Negative BPS = selling t0 (price goes DOWN)
    -- Inverted: signs are negated in the output so the consumer sees the inverted perspective
    RETURN QUERY
    WITH bps_levels AS (
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
                    dexes.impact_qsell_from_bps_latest(v_pool_address, 't1', ABS(bl.bps))
                ELSE
                    dexes.impact_qsell_from_bps_latest(v_pool_address, 't0', ABS(bl.bps))
            END AS swap_qty
        FROM bps_levels bl
    ),
    base_result AS (
        SELECT
            v_pool_address AS pool_address,
            v_protocol AS protocol,
            v_token_pair AS token_pair,
            ROUND(v_current_price::NUMERIC, 4) AS raw_current_price,
            c.bps::DOUBLE PRECISION AS raw_bps,
            c.swap_qty,
            -- Calculated price at target BPS (canonical basis)
            ROUND((v_current_price * (1 + c.bps / 10000.0))::NUMERIC, 4) AS raw_calculated_price,
            -- Liquidity in band
            ROUND((COALESCE(c.swap_qty, 0) - COALESCE(
                LAG(c.swap_qty) OVER (
                    PARTITION BY SIGN(c.bps)
                    ORDER BY ABS(c.bps)
                ), 0
            ))::NUMERIC, 0)::DOUBLE PRECISION AS raw_liquidity_in_band,
            -- Pct of reserve (canonical basis)
            ROUND(
                CASE
                    WHEN c.bps > 0 AND v_t0_reserve > 0 AND v_current_price > 0 THEN
                        (COALESCE(c.swap_qty, 0) / v_current_price / v_t0_reserve) * 100
                    WHEN c.bps < 0 AND v_t1_reserve > 0 THEN
                        (COALESCE(c.swap_qty, 0) * v_current_price / v_t1_reserve) * 100
                    ELSE NULL
                END::NUMERIC,
                2
            ) AS raw_pct_of_reserve
        FROM computed c
    )
    SELECT
        br.pool_address,
        br.protocol,
        br.token_pair,
        CASE WHEN p_invert THEN ROUND((1.0 / NULLIF(br.raw_current_price, 0))::NUMERIC, 4)
             ELSE br.raw_current_price END,
        CASE WHEN p_invert THEN -br.raw_bps ELSE br.raw_bps END,
        -- Format price change percentage label (negate BPS when inverted)
        CASE
            WHEN (CASE WHEN p_invert THEN -br.raw_bps ELSE br.raw_bps END) > 0
            THEN '+' || TRIM(TO_CHAR(ABS(br.raw_bps) / 100.0, '990.99')) || '%'
            ELSE '-' || TRIM(TO_CHAR(ABS(br.raw_bps) / 100.0, '990.99')) || '%'
        END,
        CASE WHEN p_invert THEN ROUND((1.0 / NULLIF(br.raw_calculated_price, 0))::NUMERIC, 4)
             ELSE br.raw_calculated_price END,
        ROUND(COALESCE(br.swap_qty, 0)::NUMERIC, 0)::DOUBLE PRECISION,
        br.raw_liquidity_in_band,
        -- When inverted, swap the reserve reference:
        -- positive BPS (was negative, selling t0 drains t1) → use t1_reserve denominator
        -- negative BPS (was positive, selling t1 drains t0) → use t0_reserve denominator
        CASE WHEN p_invert THEN
            ROUND(
                CASE
                    WHEN br.raw_bps > 0 AND v_t1_reserve > 0 THEN
                        (COALESCE(br.swap_qty, 0) * v_current_price / v_t1_reserve) * 100
                    WHEN br.raw_bps < 0 AND v_t0_reserve > 0 AND v_current_price > 0 THEN
                        (COALESCE(br.swap_qty, 0) / v_current_price / v_t0_reserve) * 100
                    ELSE NULL
                END::NUMERIC,
                2
            )
        ELSE br.raw_pct_of_reserve END
    FROM base_result br
    ORDER BY (CASE WHEN p_invert THEN -br.raw_bps ELSE br.raw_bps END) DESC;
END;
$$ LANGUAGE plpgsql STABLE
SET search_path TO dexes, public;

COMMENT ON FUNCTION dexes.get_view_liquidity_depth_table(TEXT, TEXT, BOOLEAN) IS
'Returns Liquidity Depth Table data for a specific pool.
For each predefined BPS level (±1, ±2, ±5, ±10, ±20, ±50, ±100 bps),
calculates the exact swap quantity needed to move the price by that amount
using impact_qsell_from_bps_latest (CLMM math with proper tick traversal).

When p_invert = TRUE, prices are displayed as t0/t1 (inverted) and BPS targets
are negated so that the consumer sees the correct directional interpretation.

Positive BPS levels = price increase = selling token1 (quantity in t1 units)
Negative BPS levels = price decrease = selling token0 (quantity in t0 units)

Returns:
  - pool_address, protocol, token_pair: Pool identifiers
  - current_price_t1_per_t0: Current pool price (inverted when p_invert=TRUE)
  - bps_target: Signed BPS target (+ve = up, -ve = down; negated when p_invert=TRUE)
  - price_change_pct: Formatted percentage label (e.g., "+0.01%", "-0.05%")
  - calculated_price: Target price at BPS level (inverted when p_invert=TRUE)
  - swap_size_equivalent: Cumulative token quantity needed to reach this BPS level
  - liquidity_in_band: Marginal token quantity in this BPS band
  - pct_of_reserve: approximate % of the counter-token reserve drained by this swap';
