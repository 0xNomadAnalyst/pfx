-- =====================================================
-- DEX Sell Swap Distribution Function
-- =====================================================
-- Function: get_view_sell_swaps_distribution
-- Purpose: Return density distribution of swaps by token amount (t0 or t1) with cumulative share and percentiles
--
-- Features:
-- - Protocol and token pair filtering
-- - Token selection (t0 or t1)
-- - Configurable lookback period
-- - Configurable number of buckets for distribution
-- - Density distribution (count of swaps per bucket)
-- - Cumulative share of swap activity at bucket midpoints
-- - Percentile constants (10th, 25th, 50th, 75th, 90th)
-- - Sample statistics (count, earliest, latest swap dates)
-- =====================================================

DROP FUNCTION IF EXISTS dexes.get_view_sell_swaps_distribution(TEXT, TEXT, TEXT, TEXT, INTEGER);
CREATE OR REPLACE FUNCTION dexes.get_view_sell_swaps_distribution(
    p_protocol TEXT,                    -- Protocol filter (e.g., 'raydium', 'orca')
    p_pair TEXT,                        -- Token pair filter (e.g., 'USX-USDC', 'eUSX-USX')
    p_token TEXT DEFAULT 't0',         -- Token to analyze: 't0' or 't1' (default: 't0' - first token in pair name)
    p_lookback TEXT DEFAULT '7 days',  -- Lookback period (e.g., '1 day', '7 days', '30 days')
    p_buckets INTEGER DEFAULT 50,      -- Number of buckets for distribution
    p_invert BOOLEAN DEFAULT FALSE     -- When TRUE, negate BPS impact values (inverted price basis)
)
RETURNS TABLE (
    -- Distribution buckets
    bucket_number INTEGER,              -- Bucket number (1 to p_buckets)
    bucket_min DOUBLE PRECISION,       -- Minimum token amount in this bucket
    bucket_max DOUBLE PRECISION,       -- Maximum token amount in this bucket
    bucket_max_in_k DOUBLE PRECISION,  -- bucket_max divided by 1000, rounded to 1 decimal place
    bucket_midpoint DOUBLE PRECISION,   -- Midpoint of bucket (for cumulative share calculation)

    -- Density distribution
    swap_count INTEGER,                 -- Number of 5-second buckets (with largest swaps) in this bucket

    -- Cumulative share
    cumulative_share DOUBLE PRECISION, -- Cumulative share of swap activity at bucket midpoint (%)

    -- Price impact (calculated using current liquidity)
    price_impact_bps DOUBLE PRECISION,  -- Price impact in BPS from selling token at bucket midpoint (using current liquidity)
    price_impact_bps_abs DOUBLE PRECISION,  -- Absolute value of price_impact_bps
    price_impact_bps_inv DOUBLE PRECISION,  -- Inverted price_impact_bps (price_impact_bps * -1)

    -- Percentile constants (same for all rows)
    percentile_10 DOUBLE PRECISION,     -- 10th percentile token amount
    percentile_25 DOUBLE PRECISION,     -- 25th percentile token amount
    percentile_50 DOUBLE PRECISION,     -- 50th percentile (median) token amount
    percentile_75 DOUBLE PRECISION,     -- 75th percentile token amount
    percentile_90 DOUBLE PRECISION,    -- 90th percentile token amount

    -- Sample statistics (same for all rows)
    total_swaps BIGINT,                 -- Total number of 5-second buckets in sample
    earliest_swap TIMESTAMPTZ,          -- Date/time of earliest bucket
    latest_swap TIMESTAMPTZ             -- Date/time of latest bucket
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_lookback_interval INTERVAL;
    v_min_amount DOUBLE PRECISION;
    v_max_amount DOUBLE PRECISION;
    v_pool_address TEXT;
BEGIN
    -- =====================================================
    -- Input Validation and Transformation
    -- =====================================================

    -- Validate token parameter
    IF p_token NOT IN ('t0', 't1') THEN
        RAISE EXCEPTION 'Invalid token parameter: %. Must be either ''t0'' or ''t1''', p_token;
    END IF;

    -- Convert lookback text to INTERVAL
    BEGIN
        v_lookback_interval := p_lookback::INTERVAL;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION 'Invalid lookback period: %. Must be a valid interval (e.g., ''1 day'', ''7 days'', ''30 days'')', p_lookback;
    END;

    -- Validate buckets parameter
    IF p_buckets IS NULL OR p_buckets < 1 OR p_buckets > 1000 THEN
        RAISE EXCEPTION 'Invalid buckets: %. Must be between 1 and 1000', p_buckets;
    END IF;

    -- =====================================================
    -- Get Pool Address for Price Impact Calculation
    -- =====================================================

    -- Get pool address from swap data (using cagg_events_5s)
    SELECT DISTINCT pool_address INTO v_pool_address
    FROM dexes.cagg_events_5s
    WHERE protocol = p_protocol
      AND token_pair = p_pair
      AND activity_category = 'swap'
    LIMIT 1;

    -- Note: Price is not needed for impact calculation - impact_bps_from_qsell_latest handles both t0 and t1 directly

    -- =====================================================
    -- Build and Execute Query
    -- =====================================================

    RETURN QUERY
    WITH swap_data AS (
        -- Get largest single swap amounts from cagg_events_5s for each 5-second bucket
        -- Uses pre-computed maximum single swap amounts (amount0_in_max or amount1_in_max) to avoid querying source table
        -- Each bucket represents the largest swap selling the selected token in that 5-second interval
        SELECT
            c.bucket_time AS time,
            -- Use amount0_in_max for t0, amount1_in_max for t1 (already decimal-adjusted)
            CASE
                WHEN p_token = 't0' THEN c.amount0_in_max
                ELSE c.amount1_in_max
            END AS token_amount
        FROM dexes.cagg_events_5s c
        WHERE c.protocol = p_protocol
          AND c.token_pair = p_pair
          AND c.activity_category = 'swap'
          AND c.bucket_time >= NOW() - v_lookback_interval
          -- Only include buckets with swaps for the selected token (where we have max single swap data)
          AND (
              (p_token = 't0' AND c.amount0_in_max IS NOT NULL)
              OR (p_token = 't1' AND c.amount1_in_max IS NOT NULL)
          )
    ),
    sample_stats AS (
        -- Calculate sample statistics and percentiles
        SELECT
            COUNT(*)::BIGINT AS total_swaps,
            MIN(time) AS earliest_swap,
            MAX(time) AS latest_swap,
            MIN(token_amount) AS min_amount,
            MAX(token_amount) AS max_amount,
            PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY token_amount) AS p10,
            PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY token_amount) AS p25,
            PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY token_amount) AS p50,
            PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY token_amount) AS p75,
            PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY token_amount) AS p90
        FROM swap_data
    ),
    bucket_ranges AS (
        -- Create bucket ranges using width_bucket
        -- Handle edge case where min_amount = max_amount (single value or all identical values)
        SELECT
            ss.*,
            -- Use width_bucket to assign each swap to a bucket
            -- LEAST ensures values at exactly max_amount go to bucket p_buckets, not p_buckets+1
            -- Handle edge case: if min_amount = max_amount, put all values in middle bucket
            CASE
                WHEN ss.min_amount = ss.max_amount THEN
                    -- All values are identical, put everything in the middle bucket
                    CEIL(p_buckets::NUMERIC / 2)::INTEGER
                ELSE
                    LEAST(
                        WIDTH_BUCKET(sd.token_amount, ss.min_amount, ss.max_amount, p_buckets),
                        p_buckets
                    )
            END AS bucket_num
        FROM swap_data sd
        CROSS JOIN sample_stats ss
    ),
    all_buckets AS (
        -- Generate all bucket numbers from 1 to p_buckets
        SELECT generate_series(1, p_buckets) AS bucket_num
    ),
    bucket_counts AS (
        -- Count swaps per bucket (only buckets with data)
        SELECT
            br.bucket_num,
            COUNT(*)::INTEGER AS swap_count
        FROM bucket_ranges br
        WHERE br.bucket_num IS NOT NULL
          AND br.bucket_num BETWEEN 1 AND p_buckets
        GROUP BY br.bucket_num
    ),
    bucket_aggregates AS (
        -- Join all buckets with actual counts, filling 0 for empty buckets
        -- Handle edge case where min_amount = max_amount
        SELECT
            ab.bucket_num,
            -- Calculate bucket boundaries
            -- When min_amount = max_amount, create artificial boundaries around the single value
            CASE
                WHEN ss.min_amount = ss.max_amount THEN
                    -- Create boundaries: single_value - 0.5 * bucket_width to single_value + 0.5 * bucket_width
                    -- Use a small artificial range (1% of the value, or 1 if value is 0)
                    ss.min_amount - COALESCE(NULLIF(ABS(ss.min_amount) * 0.01, 0), 1) * 0.5 + (ab.bucket_num - 1) * COALESCE(NULLIF(ABS(ss.min_amount) * 0.01, 0), 1) / p_buckets
                ELSE
                    ss.min_amount + (ab.bucket_num - 1) * (ss.max_amount - ss.min_amount) / p_buckets
            END AS bucket_min,
            CASE
                WHEN ss.min_amount = ss.max_amount THEN
                    ss.min_amount - COALESCE(NULLIF(ABS(ss.min_amount) * 0.01, 0), 1) * 0.5 + ab.bucket_num * COALESCE(NULLIF(ABS(ss.min_amount) * 0.01, 0), 1) / p_buckets
                ELSE
                    ss.min_amount + ab.bucket_num * (ss.max_amount - ss.min_amount) / p_buckets
            END AS bucket_max,
            COALESCE(bc.swap_count, 0)::INTEGER AS swap_count,
            -- Calculate cumulative sum of swap counts across ALL buckets
            SUM(COALESCE(bc.swap_count, 0)) OVER (ORDER BY ab.bucket_num) AS cumulative_count
        FROM all_buckets ab
        CROSS JOIN sample_stats ss
        LEFT JOIN bucket_counts bc ON ab.bucket_num = bc.bucket_num
        WHERE ss.total_swaps > 0  -- Only generate buckets if we have data
    ),
    distribution_with_share AS (
        -- Calculate cumulative share at bucket midpoint
        SELECT
            ba.bucket_num,
            ba.bucket_min,
            ba.bucket_max,
            (ba.bucket_min + ba.bucket_max) / 2.0 AS bucket_midpoint,
            ba.swap_count,
            -- Cumulative share: cumulative swaps up to this bucket / total swaps * 100
            CASE
                WHEN ss.total_swaps > 0
                THEN (ba.cumulative_count::DOUBLE PRECISION / ss.total_swaps::DOUBLE PRECISION) * 100.0
                ELSE 0
            END AS cumulative_share,
            ss.total_swaps,
            ss.earliest_swap,
            ss.latest_swap,
            ss.p10,
            ss.p25,
            ss.p50,
            ss.p75,
            ss.p90
        FROM bucket_aggregates ba
        CROSS JOIN sample_stats ss
    ),
    distribution_with_impact AS (
        -- Calculate price impact for each bucket midpoint
        -- For t0: selling t0 → negative BPS (price decreases)
        -- For t1: selling t1 → positive BPS (price increases)
        SELECT
            dws.*,
            CASE
                WHEN v_pool_address IS NOT NULL
                     AND dws.swap_count > 0
                     AND dws.bucket_midpoint > 0
                THEN
                    CASE
                        WHEN p_token = 't0' THEN
                            -- Selling t0 → negative BPS (price decreases)
                            dexes.impact_bps_from_qsell_latest(
                                v_pool_address,
                                't0',
                                dws.bucket_midpoint
                            )
                        ELSE
                            -- Selling t1 → positive BPS (price increases)
                            -- Price conversion not needed - impact function handles t1 directly
                            dexes.impact_bps_from_qsell_latest(
                                v_pool_address,
                                't1',
                                dws.bucket_midpoint
                            )
                    END
                ELSE NULL
            END AS price_impact_bps
        FROM distribution_with_share dws
    )
    SELECT
        dwi.bucket_num::INTEGER AS bucket_number,
        ROUND(dwi.bucket_min::NUMERIC, 2)::DOUBLE PRECISION AS bucket_min,
        ROUND(dwi.bucket_max::NUMERIC, 2)::DOUBLE PRECISION AS bucket_max,
        ROUND((dwi.bucket_max / 1000.0)::NUMERIC, 1)::DOUBLE PRECISION AS bucket_max_in_k,
        ROUND(dwi.bucket_midpoint::NUMERIC, 2)::DOUBLE PRECISION AS bucket_midpoint,
        dwi.swap_count,
        ROUND(dwi.cumulative_share::NUMERIC, 4)::DOUBLE PRECISION AS cumulative_share,
        ROUND((CASE WHEN p_invert THEN -1 * dwi.price_impact_bps ELSE dwi.price_impact_bps END)::NUMERIC, 4)::DOUBLE PRECISION AS price_impact_bps,
        ROUND(ABS(dwi.price_impact_bps)::NUMERIC, 4)::DOUBLE PRECISION AS price_impact_bps_abs,
        ROUND((CASE WHEN p_invert THEN dwi.price_impact_bps ELSE -1 * dwi.price_impact_bps END)::NUMERIC, 4)::DOUBLE PRECISION AS price_impact_bps_inv,
        ROUND(dwi.p10::NUMERIC, 2)::DOUBLE PRECISION AS percentile_10,
        ROUND(dwi.p25::NUMERIC, 2)::DOUBLE PRECISION AS percentile_25,
        ROUND(dwi.p50::NUMERIC, 2)::DOUBLE PRECISION AS percentile_50,
        ROUND(dwi.p75::NUMERIC, 2)::DOUBLE PRECISION AS percentile_75,
        ROUND(dwi.p90::NUMERIC, 2)::DOUBLE PRECISION AS percentile_90,
        dwi.total_swaps,
        dwi.earliest_swap,
        dwi.latest_swap
    FROM distribution_with_impact dwi
    ORDER BY dwi.bucket_num;

    -- If no data found, return empty result (no rows)

END;
$$;

-- =====================================================
-- Function Comments
-- =====================================================

COMMENT ON FUNCTION dexes.get_view_sell_swaps_distribution(TEXT, TEXT, TEXT, TEXT, INTEGER, BOOLEAN) IS
'Returns density distribution of swaps by token amount (t0 or t1) with cumulative share and percentiles.
Uses cagg_events_5s for efficient aggregation, leveraging pre-computed maximum single swap amounts
(amount0_in_max or amount1_in_max) for each 5-second bucket to avoid querying the source table.

Parameters:
  - p_protocol: Protocol identifier (e.g., ''raydium'', ''orca'')
  - p_pair: Token pair (e.g., ''USX-USDC'', ''eUSX-USX'')
  - p_token: Token to analyze - ''t0'' or ''t1'' (default: ''t0'' - first token in pair name)
  - p_lookback: Lookback period (e.g., ''1 day'', ''7 days'', ''30 days'')
  - p_buckets: Number of buckets for distribution (1-1000, default: 50)

Returns:
  - Distribution buckets: bucket_number, bucket_min, bucket_max, bucket_midpoint
  - Density: swap_count per bucket (number of 5-second buckets with swaps in this range)
  - Cumulative share: cumulative % of swap activity at bucket midpoint
  - Price impact: price_impact_bps - impact in BPS from selling token at bucket midpoint (using current liquidity)
  - Percentiles: 10th, 25th, 50th (median), 75th, 90th percentile token amounts (constants)
  - Sample stats: total_swaps, earliest_swap, latest_swap (constants)

The token amount uses amount0_in_max (for t0) or amount1_in_max (for t1) from each 5-second bucket in cagg_events_5s.
This avoids querying the source table by leveraging pre-computed maximum single swap amounts.
Each bucket represents the largest swap selling the selected token in that 5-second interval.
All amounts are in decimal-adjusted units (human-readable format) from cagg_events_5s.
Cumulative share represents the percentage of total buckets that have token amounts <= bucket midpoint.
Price impact: For t0, calculated directly (negative BPS = price decreases).
For t1, calculated directly (positive BPS = price increases).
Uses impact_bps_from_qsell_latest with the most recent liquidity snapshot.';

-- =====================================================
-- Usage Examples
-- =====================================================

-- Get 50-bucket distribution for Raydium USX-USDC, t0 (default - USX sells) over last 7 days:
-- SELECT * FROM dexes.get_view_sell_swaps_distribution('raydium', 'USX-USDC', 't0', '7 days', 50);

-- Get 50-bucket distribution for Raydium USX-USDC, t1 (USDC sells) over last 7 days:
-- SELECT * FROM dexes.get_view_sell_swaps_distribution('raydium', 'USX-USDC', 't1', '7 days', 50);

-- Get 100-bucket distribution for Orca eUSX-USX, t1 over last 30 days:
-- SELECT * FROM dexes.get_view_sell_swaps_distribution('orca', 'eUSX-USX', 't1', '30 days', 100);

-- Get distribution with percentiles (t0 - default):
-- SELECT
--     bucket_number,
--     bucket_midpoint,
--     swap_count,
--     cumulative_share,
--     percentile_50 AS median,
--     percentile_90
-- FROM dexes.get_view_sell_swaps_distribution('raydium', 'USX-USDC', DEFAULT, '7 days', 50)
-- WHERE swap_count > 0;

-- Example: 10 buckets, default lookback (7 days), t0 amounts
-- Note: This function uses pre-aggregated 5-second buckets, so interval is not configurable
-- It shows distribution of largest t0-in swaps per 5-second bucket
-- SELECT * FROM dexes.get_view_sell_swaps_distribution('raydium', 'USX-USDC', 't0', DEFAULT, 10);
-- Or explicitly:
-- SELECT * FROM dexes.get_view_sell_swaps_distribution('raydium', 'USX-USDC', 't0', '7 days', 10);

-- Example: 10 buckets, default lookback (7 days), t0 amounts (default - USX sells)
-- SELECT * FROM dexes.get_view_sell_swaps_distribution('raydium', 'USX-USDC', DEFAULT, DEFAULT, 10);

-- =====================================================
-- Grant Permissions
-- =====================================================

-- GRANT EXECUTE ON FUNCTION dexes.get_view_sell_swaps_distribution TO your_read_user;

