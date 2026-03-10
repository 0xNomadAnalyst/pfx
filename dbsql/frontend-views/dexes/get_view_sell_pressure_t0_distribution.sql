-- =====================================================
-- DEX Sell Pressure T0 Distribution Function
-- =====================================================
-- Function: get_view_sell_pressure_t0_distribution
-- Purpose: Return density distribution of net sell t0 pressure measured over configurable intervals
--
-- Features:
-- - Protocol and token pair filtering
-- - Configurable interval for measuring net sell pressure (e.g., '5 minutes', '1 hour')
-- - Configurable lookback period
-- - Configurable number of buckets for distribution
-- - Density distribution (count of intervals per bucket)
-- - Cumulative share of sell pressure activity at bucket midpoints
-- - Percentile constants (10th, 25th, 50th, 75th, 90th)
-- - Sample statistics (count, earliest, latest interval dates)
--
-- Net sell t0 pressure = amount0_in - amount0_out (positive = selling pressure, negative = buying pressure)
-- This is aggregated over time intervals (e.g., 5-minute buckets), then distributed into histogram buckets
-- Uses cagg_events_5s for efficient aggregation (following approach from get_ranked_net_sell_pressure)
-- =====================================================

CREATE OR REPLACE FUNCTION dexes.get_view_sell_pressure_t0_distribution(
    p_protocol TEXT,                    -- Protocol filter (e.g., 'raydium_clmm', 'orca_whirlpool')
    p_token_pair TEXT,                  -- Token pair filter (e.g., 'USX-USDC', 'eUSX-USX')
    p_pressure_interval TEXT DEFAULT '5 minutes', -- Interval for measuring net sell pressure (e.g., '5 minutes', '1 hour', '30 minutes')
    p_lookback TEXT DEFAULT '7 days',   -- Lookback period (e.g., '1 day', '7 days', '30 days')
    p_buckets INTEGER DEFAULT 50,       -- Number of buckets for distribution (1-1000)
    p_pressure_filter TEXT DEFAULT NULL -- Filter by pressure direction: 'buy_only' (negative values), 'sell_only' (positive values), or NULL (both)
)
RETURNS TABLE (
    -- Distribution buckets
    bucket_number INTEGER,              -- Bucket number (1 to p_buckets)
    bucket_min DOUBLE PRECISION,       -- Minimum net sell pressure in this bucket
    bucket_max DOUBLE PRECISION,       -- Maximum net sell pressure in this bucket
    bucket_max_in_k DOUBLE PRECISION,  -- bucket_max divided by 1000, rounded to 1 decimal place
    bucket_midpoint DOUBLE PRECISION,   -- Midpoint of bucket (for cumulative share calculation)

    -- Density distribution
    interval_count INTEGER,             -- Number of time intervals in this bucket

    -- Cumulative share
    cumulative_share DOUBLE PRECISION, -- Cumulative share of sell pressure activity at bucket midpoint (%)

    -- Cumulative percentile
    cumulative_percentile DOUBLE PRECISION, -- Cumulative percentile rank of bucket midpoint (0-100)

    -- Price impact (calculated using current liquidity)
    price_impact_bps DOUBLE PRECISION,  -- Price impact in BPS from selling t0 at bucket midpoint (using current liquidity)
    price_impact_bps_abs DOUBLE PRECISION,  -- Absolute value of price_impact_bps
    price_impact_bps_inv DOUBLE PRECISION,  -- Inverted price_impact_bps (price_impact_bps * -1)

    -- Percentile constants (same for all rows)
    percentile_10 DOUBLE PRECISION,     -- 10th percentile net sell pressure
    percentile_25 DOUBLE PRECISION,     -- 25th percentile net sell pressure
    percentile_50 DOUBLE PRECISION,      -- 50th percentile (median) net sell pressure
    percentile_75 DOUBLE PRECISION,     -- 75th percentile net sell pressure
    percentile_90 DOUBLE PRECISION,      -- 90th percentile net sell pressure

    -- Sample statistics (same for all rows)
    total_intervals BIGINT,              -- Total number of time intervals with swap activity (unfiltered)
    total_intervals_filtered BIGINT,     -- Total number of time intervals after pressure filter applied
    total_intervals_filtered_pct INTEGER, -- Percentage of intervals that passed the filter (0-100)
    total_swaps BIGINT,                  -- Total number of swap events in sample
    earliest_interval TIMESTAMPTZ,      -- Date/time of earliest interval
    latest_interval TIMESTAMPTZ,        -- Date/time of latest interval

    -- Additional context
    protocol TEXT,                      -- Protocol identifier
    token_pair TEXT                     -- Token pair identifier
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_pressure_interval INTERVAL;
    v_lookback_interval INTERVAL;
    v_pool_address TEXT;
    v_current_price DOUBLE PRECISION;
BEGIN
    -- =====================================================
    -- Input Validation and Transformation
    -- =====================================================

    -- Convert pressure interval string to PostgreSQL INTERVAL
    BEGIN
        v_pressure_interval := p_pressure_interval::INTERVAL;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION 'Invalid pressure interval: %. Must be a valid interval (e.g., ''5 minutes'', ''1 hour'', ''30 minutes'')', p_pressure_interval;
    END;

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

    -- Validate pressure filter parameter
    IF p_pressure_filter IS NOT NULL
       AND p_pressure_filter NOT IN ('buy_only', 'sell_only') THEN
        RAISE EXCEPTION 'Invalid pressure_filter: %. Must be NULL, ''buy_only'', or ''sell_only''', p_pressure_filter;
    END IF;

    -- =====================================================
    -- Get Current Liquidity Snapshot for Price Impact Calculation
    -- =====================================================

    -- Get pool address from swap data
    SELECT DISTINCT e.pool_address INTO v_pool_address
    FROM dexes.cagg_events_5s e
    WHERE e.protocol = p_protocol
      AND e.token_pair = p_token_pair
      AND e.activity_category = 'swap'
    LIMIT 1;

    -- Get current price for conversion (negative bucket_midpoint to t1 equivalent)
    IF v_pool_address IS NOT NULL THEN
        SELECT
            POWER(q.sqrt_price_x64::DOUBLE PRECISION / POWER(2::DOUBLE PRECISION, 64), 2) * POWER(10, q.mint_decimals_0 - q.mint_decimals_1) AS price
        INTO
            v_current_price
        FROM dexes.src_acct_tickarray_queries q
        WHERE q.pool_address = v_pool_address
        ORDER BY q.time DESC
        LIMIT 1;
    END IF;

    -- =====================================================
    -- Build and Execute Query
    -- =====================================================

    RETURN QUERY
    WITH swap_events_total AS (
        -- Calculate total swap events from original data (before pressure filtering)
        -- IMPORTANT: Only counts swap events (activity_category='swap'), NOT LP actions or other activity types
        -- cagg_events_5s has separate rows for swaps vs LP actions, each with their own event_count
        -- This sums only the event_count values from rows where activity_category = 'swap'
        SELECT
            SUM(e.event_count)::BIGINT AS total_swap_events
        FROM dexes.cagg_events_5s e
        WHERE e.protocol = p_protocol
          AND e.token_pair = p_token_pair
          AND e.activity_category = 'swap'  -- CRITICAL: Only swap events, excludes 'lp' and 'other' activity categories
          AND e.bucket_time >= NOW() - v_lookback_interval
    ),
    all_intervals AS (
        -- Count all intervals with swap activity (before pressure direction filter)
        -- This represents the total number of time intervals that had any swap activity
        SELECT
            COUNT(*)::BIGINT AS total_intervals_unfiltered
        FROM (
            SELECT
                time_bucket(v_pressure_interval, e.bucket_time) AS interval_time
            FROM dexes.cagg_events_5s e
            WHERE e.protocol = p_protocol
              AND e.token_pair = p_token_pair
              AND e.activity_category = 'swap'
              AND e.bucket_time >= NOW() - v_lookback_interval
            GROUP BY time_bucket(v_pressure_interval, e.bucket_time), e.pool_address
            HAVING SUM(e.event_count) > 0
        ) intervals
    ),
    pressure_intervals AS (
        -- Aggregate swap data from cagg_events_5s into time buckets and calculate net sell t0 pressure
        -- Net sell t0 pressure = amount0_in - amount0_out
        -- Positive values = selling pressure (more t0 going in than out)
        -- Negative values = buying pressure (more t0 going out than in)
        -- Following the same approach as get_ranked_net_sell_pressure
        SELECT
            time_bucket(v_pressure_interval, e.bucket_time) AS interval_time,
            e.pool_address,
            MAX(e.protocol) AS protocol,
            MAX(e.token_pair) AS token_pair,

            -- Calculate net sell t0 pressure
            -- amount0_in - amount0_out = net selling pressure (positive = selling, negative = buying)
            SUM(e.amount0_in) - SUM(e.amount0_out) AS net_sell_pressure_t0

        FROM dexes.cagg_events_5s e
        WHERE e.protocol = p_protocol
          AND e.token_pair = p_token_pair
          AND e.activity_category = 'swap'
          AND e.bucket_time >= NOW() - v_lookback_interval
        GROUP BY time_bucket(v_pressure_interval, e.bucket_time), e.pool_address
        HAVING SUM(e.event_count) > 0  -- Only include intervals with swap activity
            -- Apply pressure filter if specified
            AND (
                p_pressure_filter IS NULL
                OR (p_pressure_filter = 'buy_only' AND (SUM(e.amount0_in) - SUM(e.amount0_out)) < 0)
                OR (p_pressure_filter = 'sell_only' AND (SUM(e.amount0_in) - SUM(e.amount0_out)) > 0)
            )
    ),
    sample_stats AS (
        -- Calculate sample statistics and percentiles
        SELECT
            MAX(ai.total_intervals_unfiltered)::BIGINT AS total_intervals,
            COUNT(*)::BIGINT AS total_intervals_filtered,
            CASE
                WHEN MAX(ai.total_intervals_unfiltered) > 0
                THEN ROUND((COUNT(*)::NUMERIC / MAX(ai.total_intervals_unfiltered)::NUMERIC) * 100, 0)::INTEGER
                ELSE 0
            END AS total_intervals_filtered_pct,
            COALESCE(MAX(set.total_swap_events), 0)::BIGINT AS total_swaps,
            MIN(interval_time) AS earliest_interval,
            MAX(interval_time) AS latest_interval,
            MIN(net_sell_pressure_t0) AS min_pressure,
            MAX(net_sell_pressure_t0) AS max_pressure,
            PERCENTILE_CONT(0.10) WITHIN GROUP (ORDER BY net_sell_pressure_t0) AS p10,
            PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY net_sell_pressure_t0) AS p25,
            PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY net_sell_pressure_t0) AS p50,
            PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY net_sell_pressure_t0) AS p75,
            PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY net_sell_pressure_t0) AS p90,
            MAX(pi.protocol) AS protocol,
            MAX(pi.token_pair) AS token_pair
        FROM pressure_intervals pi
        CROSS JOIN swap_events_total set
        CROSS JOIN all_intervals ai
    ),
    bucket_ranges AS (
        -- Create bucket ranges using width_bucket
        -- Handle edge case where min_pressure = max_pressure (single value or all identical values)
        SELECT
            pi.interval_time,
            pi.pool_address,
            pi.net_sell_pressure_t0,
            ss.total_intervals,
            ss.total_intervals_filtered,
            ss.total_intervals_filtered_pct,
            ss.total_swaps,
            ss.earliest_interval,
            ss.latest_interval,
            ss.min_pressure,
            ss.max_pressure,
            ss.p10,
            ss.p25,
            ss.p50,
            ss.p75,
            ss.p90,
            ss.protocol,
            ss.token_pair,
            -- Use width_bucket to assign each interval to a bucket
            -- LEAST ensures values at exactly max_pressure go to bucket p_buckets, not p_buckets+1
            -- Handle edge case: if min_pressure = max_pressure, put all values in middle bucket
            CASE
                WHEN ss.min_pressure = ss.max_pressure THEN
                    -- All values are identical, put everything in the middle bucket
                    CEIL(p_buckets::NUMERIC / 2)::INTEGER
                ELSE
                    LEAST(
                        WIDTH_BUCKET(pi.net_sell_pressure_t0, ss.min_pressure, ss.max_pressure, p_buckets),
                        p_buckets
                    )
            END AS bucket_num
        FROM pressure_intervals pi
        CROSS JOIN sample_stats ss
    ),
    all_buckets AS (
        -- Generate all bucket numbers from 1 to p_buckets
        SELECT generate_series(1, p_buckets) AS bucket_num
    ),
    bucket_counts AS (
        -- Count intervals per bucket (only buckets with data)
        SELECT
            br.bucket_num,
            COUNT(*)::INTEGER AS interval_count
        FROM bucket_ranges br
        WHERE br.bucket_num IS NOT NULL
          AND br.bucket_num BETWEEN 1 AND p_buckets
        GROUP BY br.bucket_num
    ),
    bucket_aggregates AS (
        -- Join all buckets with actual counts, filling 0 for empty buckets
        -- Handle edge case where min_pressure = max_pressure
        SELECT
            ab.bucket_num,
            ss.protocol,
            ss.token_pair,
            -- Calculate bucket boundaries
            -- When min_pressure = max_pressure, create artificial boundaries around the single value
            CASE
                WHEN ss.min_pressure = ss.max_pressure THEN
                    -- Create boundaries: single_value - 0.5 * bucket_width to single_value + 0.5 * bucket_width
                    -- Use a small artificial range (1% of the value, or 1 if value is 0)
                    ss.min_pressure - COALESCE(NULLIF(ABS(ss.min_pressure) * 0.01, 0), 1) * 0.5 + (ab.bucket_num - 1) * COALESCE(NULLIF(ABS(ss.min_pressure) * 0.01, 0), 1) / p_buckets
                ELSE
                    ss.min_pressure + (ab.bucket_num - 1) * (ss.max_pressure - ss.min_pressure) / p_buckets
            END AS bucket_min,
            CASE
                WHEN ss.min_pressure = ss.max_pressure THEN
                    ss.min_pressure - COALESCE(NULLIF(ABS(ss.min_pressure) * 0.01, 0), 1) * 0.5 + ab.bucket_num * COALESCE(NULLIF(ABS(ss.min_pressure) * 0.01, 0), 1) / p_buckets
                ELSE
                    ss.min_pressure + ab.bucket_num * (ss.max_pressure - ss.min_pressure) / p_buckets
            END AS bucket_max,
            COALESCE(bc.interval_count, 0)::INTEGER AS interval_count,
            -- Calculate cumulative sum of interval counts across ALL buckets
            SUM(COALESCE(bc.interval_count, 0)) OVER (ORDER BY ab.bucket_num) AS cumulative_count
        FROM all_buckets ab
        CROSS JOIN sample_stats ss
        LEFT JOIN bucket_counts bc ON ab.bucket_num = bc.bucket_num
        WHERE ss.total_intervals_filtered > 0  -- Only generate buckets if we have filtered data
    ),
    distribution_with_share AS (
        -- Calculate cumulative share and percentile at bucket midpoint
        SELECT
            ba.bucket_num,
            ba.bucket_min,
            ba.bucket_max,
            (ba.bucket_min + ba.bucket_max) / 2.0 AS bucket_midpoint,
            ba.interval_count,
            -- Cumulative share: cumulative intervals up to this bucket / total filtered intervals * 100
            CASE
                WHEN ss.total_intervals_filtered > 0
                THEN (ba.cumulative_count::DOUBLE PRECISION / ss.total_intervals_filtered::DOUBLE PRECISION) * 100.0
                ELSE 0
            END AS cumulative_share,
            -- Cumulative percentile: percentile rank of bucket midpoint within the distribution
            -- This represents what percentile the bucket midpoint falls at
            -- Calculated as: (cumulative intervals up to this bucket / total filtered intervals) * 100
            -- This is the same as cumulative_share, but we'll keep both for clarity
            CASE
                WHEN ss.total_intervals_filtered > 0
                THEN (ba.cumulative_count::DOUBLE PRECISION / ss.total_intervals_filtered::DOUBLE PRECISION) * 100.0
                ELSE 0
            END AS cumulative_percentile,
            ss.total_intervals,
            ss.total_intervals_filtered,
            ss.total_intervals_filtered_pct,
            ss.total_swaps,
            ss.earliest_interval,
            ss.latest_interval,
            ss.p10,
            ss.p25,
            ss.p50,
            ss.p75,
            ss.p90,
            ss.protocol,
            ss.token_pair
        FROM bucket_aggregates ba
        CROSS JOIN sample_stats ss
    ),
    distribution_with_impact AS (
        -- Calculate price impact for each bucket midpoint
        -- Handles both buying and selling pressure:
        --   - Positive bucket_midpoint = selling t0 → negative BPS (price down)
        --   - Negative bucket_midpoint = buying t0 (selling t1) → positive BPS (price up)
        SELECT
            dws.*,
            -- Calculate impact using impact_bps_from_qsell_latest
            -- For positive values: sell t0 → negative BPS
            -- For negative values: convert to t1 equivalent and sell t1 → positive BPS
            CASE
                WHEN v_pool_address IS NOT NULL
                     AND v_current_price > 0
                     AND dws.bucket_midpoint != 0
                THEN
                    CASE
                        WHEN dws.bucket_midpoint > 0 THEN
                            -- Selling t0 → negative BPS (price decreases)
                            dexes.impact_bps_from_qsell_latest(
                                v_pool_address,
                                't0',
                                dws.bucket_midpoint
                            )
                        ELSE
                            -- Buying t0 = selling t1 → positive BPS (price increases)
                            -- Convert t0 amount to t1 equivalent: t1_amount = |t0_amount| * price
                            dexes.impact_bps_from_qsell_latest(
                                v_pool_address,
                                't1',
                                ABS(dws.bucket_midpoint) * v_current_price
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
        dwi.interval_count,
        ROUND(dwi.cumulative_share::NUMERIC, 4)::DOUBLE PRECISION AS cumulative_share,
        ROUND(dwi.cumulative_percentile::NUMERIC, 2)::DOUBLE PRECISION AS cumulative_percentile,
        ROUND(dwi.price_impact_bps::NUMERIC, 4)::DOUBLE PRECISION AS price_impact_bps,
        ROUND(ABS(dwi.price_impact_bps)::NUMERIC, 4)::DOUBLE PRECISION AS price_impact_bps_abs,
        ROUND((dwi.price_impact_bps * -1)::NUMERIC, 4)::DOUBLE PRECISION AS price_impact_bps_inv,
        ROUND(dwi.p10::NUMERIC, 2)::DOUBLE PRECISION AS percentile_10,
        ROUND(dwi.p25::NUMERIC, 2)::DOUBLE PRECISION AS percentile_25,
        ROUND(dwi.p50::NUMERIC, 2)::DOUBLE PRECISION AS percentile_50,
        ROUND(dwi.p75::NUMERIC, 2)::DOUBLE PRECISION AS percentile_75,
        ROUND(dwi.p90::NUMERIC, 2)::DOUBLE PRECISION AS percentile_90,
        dwi.total_intervals,
        dwi.total_intervals_filtered,
        dwi.total_intervals_filtered_pct,
        dwi.total_swaps,
        dwi.earliest_interval,
        dwi.latest_interval,
        dwi.protocol,
        dwi.token_pair
    FROM distribution_with_impact dwi
    ORDER BY dwi.bucket_num;

    -- If no data found, return empty result (no rows)

END;
$$;

-- =====================================================
-- Function Comments
-- =====================================================

COMMENT ON FUNCTION dexes.get_view_sell_pressure_t0_distribution(TEXT, TEXT, TEXT, TEXT, INTEGER, TEXT) IS
'Returns density distribution of net sell t0 pressure measured over configurable time intervals.
Aggregates swap data into time buckets (e.g., 5-minute intervals), calculates net sell t0 pressure
for each bucket, then creates a histogram distribution of those pressure values.

Net sell t0 pressure = amount0_in - amount0_out
- Positive values = selling pressure (more t0 going in than out)
- Negative values = buying pressure (more t0 going out than in)

Uses cagg_events_5s for swap transaction data aggregated at 5-second intervals.

Parameters:
  - p_protocol: Protocol identifier (e.g., ''raydium_clmm'', ''orca_whirlpool'')
  - p_token_pair: Token pair (e.g., ''USX-USDC'', ''eUSX-USX'')
  - p_pressure_interval: Interval for measuring net sell pressure (e.g., ''5 minutes'', ''1 hour'', ''30 minutes'')
  - p_lookback: Lookback period (e.g., ''1 day'', ''7 days'', ''30 days'')
  - p_buckets: Number of buckets for distribution (1-1000, default: 50)
  - p_pressure_filter: Filter by pressure direction - ''buy_only'' (negative values only), ''sell_only'' (positive values only), or NULL (both, default)

Returns:
  - Distribution buckets: bucket_number, bucket_min, bucket_max, bucket_midpoint
  - Density: interval_count per bucket (number of time intervals with net sell pressure in this range)
  - Cumulative share: cumulative % of filtered intervals at bucket midpoint
  - Cumulative percentile: percentile rank of bucket midpoint (0-100, represents what percentile the bucket midpoint falls at)
  - Price impact: price_impact_bps - impact in BPS from selling/buying at bucket midpoint (using current liquidity)
    Calculated for both positive (selling) and negative (buying) bucket_midpoint values.
  - Percentiles: 10th, 25th, 50th (median), 75th, 90th percentile net sell pressure values (constants)
  - Sample stats:
    - total_intervals: count of all intervals with swap activity (before pressure direction filter)
    - total_intervals_filtered: count of intervals after pressure filter applied
    - total_intervals_filtered_pct: percentage of intervals that passed filter (0-100, rounded)
    - total_swaps: total number of swap events in sample
    - earliest_interval, latest_interval: time range of data
  - Context: protocol, token_pair (constants)

All pressure values are in decimal-adjusted units (human-readable format).
Cumulative share represents the percentage of filtered intervals that have net sell pressure <= bucket midpoint.
total_swaps counts the total number of swap events in the sample (sum of event_count from cagg_events_5s matching the filters).
Price impact is calculated using impact_bps_from_qsell_latest with the most recent liquidity snapshot.';

-- =====================================================
-- Usage Examples
-- =====================================================

-- Get 50-bucket distribution for Raydium USX-USDC using 5-minute intervals over last 7 days:
-- SELECT * FROM dexes.get_view_sell_pressure_t0_distribution('raydium_clmm', 'USX-USDC', '5 minutes', '7 days', 50);

-- Get 100-bucket distribution for Orca eUSX-USX using 1-hour intervals over last 30 days:
-- SELECT * FROM dexes.get_view_sell_pressure_t0_distribution('orca_whirlpool', 'eUSX-USX', '1 hour', '30 days', 100);

-- Get only buying pressure distribution:
-- SELECT * FROM dexes.get_view_sell_pressure_t0_distribution('raydium', 'USX-USDC', '5 minutes', '7 days', 50, 'buy_only');

-- Get only selling pressure distribution:
-- SELECT * FROM dexes.get_view_sell_pressure_t0_distribution('raydium', 'USX-USDC', '5 minutes', '7 days', 50, 'sell_only');

-- Get distribution with percentiles and price impact:
-- SELECT
--     bucket_number,
--     bucket_midpoint,
--     interval_count,
--     cumulative_share,
--     price_impact_bps,
--     percentile_50 AS median,
--     percentile_90
-- FROM dexes.get_view_sell_pressure_t0_distribution('raydium_clmm', 'USX-USDC', '5 minutes', '7 days', 50)
-- WHERE interval_count > 0;

-- Analyze sell pressure distribution patterns:
-- SELECT
--     bucket_number,
--     bucket_midpoint,
--     interval_count,
--     CASE
--         WHEN bucket_midpoint > 0 THEN 'Selling Pressure'
--         WHEN bucket_midpoint < 0 THEN 'Buying Pressure'
--         ELSE 'Neutral'
--     END AS pressure_type
-- FROM dexes.get_view_sell_pressure_t0_distribution('raydium_clmm', 'USX-USDC', '15 minutes', '7 days', 50)
-- WHERE interval_count > 0
-- ORDER BY bucket_number;

-- Example: 10 buckets, 1-hour intervals, default lookback (7 days), sell_only filter, t0 pressure
-- SELECT * FROM dexes.get_view_sell_pressure_t0_distribution('raydium', 'USX-USDC', '1 hour', DEFAULT, 10, 'sell_only');
-- Or explicitly:
-- SELECT * FROM dexes.get_view_sell_pressure_t0_distribution('raydium', 'USX-USDC', '1 hour', '7 days', 10, 'sell_only');

-- Example: 10 buckets, 1-hour intervals, sell_only, with selected columns:
-- SELECT
--     bucket_number,
--     bucket_midpoint,
--     interval_count,
--     cumulative_share,
--     price_impact_bps,
--     percentile_50 AS median,
--     percentile_90
-- FROM dexes.get_view_sell_pressure_t0_distribution('raydium', 'USX-USDC', '1 hour', DEFAULT, 10, 'sell_only')
-- WHERE interval_count > 0
-- ORDER BY bucket_number;

-- =====================================================
-- Grant Permissions
-- =====================================================

-- GRANT EXECUTE ON FUNCTION dexes.get_view_sell_pressure_t0_distribution TO your_read_user;
