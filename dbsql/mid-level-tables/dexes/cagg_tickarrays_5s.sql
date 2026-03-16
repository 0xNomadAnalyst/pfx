-- Continuous Aggregate: Liquidity Depth Impact Metrics (5-second intervals)
-- 
-- Aggregates pre-calculated impact metrics from source table
-- Uses MIN, MAX, AVG aggregations over 5-second intervals for price impact analysis
--
-- Time Column: block_time (blockchain timestamp) for proper alignment with swap events
-- Bucket Size: 5 seconds
--
-- CRITICAL: Buckets by block_time (blockchain time) instead of time (ingestion time)
-- to ensure liquidity depth metrics align correctly with swap events
--
-- NOTE: Impact metrics are pre-calculated in Python before DB insertion
-- This aggregate provides statistical aggregations (min/max/avg) over each interval

CREATE MATERIALIZED VIEW IF NOT EXISTS dexes.cagg_tickarrays_5s
WITH (timescaledb.continuous) AS
SELECT
    -- Time bucket (5-second intervals on block_time - blockchain time for proper alignment)
    time_bucket('5 seconds'::interval, block_time) AS bucket,
    
    -- Identifying keys / partitioning columns
    pool_address,
    protocol,
    token_pair,
    
    -- Get the most recent query_id in this time bucket
    -- This is used to retrieve the latest liquidity depth snapshot
    LAST(query_id, block_time) AS query_id,
    
    -- Also capture ingestion time for reference
    LAST(time, block_time) AS last_ingestion_time,
    
    -- Additional pool state from the last query
    LAST(current_tick, block_time) AS current_tick,
    
    -- Precise floating-point tick (without rounding, preserves sub-tick precision)
    CAST(dexes.get_tick_float_from_sqrtPriceXQQ(
        LAST(sqrt_price_x64, block_time)::DOUBLE PRECISION,
        POWER(2, LAST(price_fixed_point_base, block_time))::DOUBLE PRECISION,
        1.0001::DOUBLE PRECISION
    ) AS NUMERIC) AS current_tick_float,
    
    LAST(pool_liquidity, block_time) AS pool_liquidity,
    LAST(sqrt_price_x64, block_time) AS sqrt_price_x64,
    
    -- Decimal-adjusted price (token1 per token0, human-readable)
    CAST(dexes.get_decimal_price_from_sqrtPriceXQQ(
        LAST(sqrt_price_x64, block_time)::DOUBLE PRECISION,
        POWER(2, LAST(price_fixed_point_base, block_time))::DOUBLE PRECISION,
        LAST(mint_decimals_0, block_time)::INTEGER,
        LAST(mint_decimals_1, block_time)::INTEGER
    ) AS NUMERIC) AS price_t1_per_t0,
    
    -- =====================================================================
    -- IMPACT FROM SELLING TOKEN0 (Price Impact in BPS, SIGNED)
    -- =====================================================================
    -- Uses pre-calculated impact metrics from source table
    -- Returns NEGATIVE BPS (price t1/t0 decreases when selling t0)
    -- Aggregated as MIN, MAX, AVG over the 5-second interval
    
    -- Quantity 1: Impact from selling configured quantity 1
    CAST(MIN(c_impact_from_sell_t0_1) AS NUMERIC) AS impact_from_t0_sell1_min,
    CAST(MAX(c_impact_from_sell_t0_1) AS NUMERIC) AS impact_from_t0_sell1_max,
    CAST(AVG(c_impact_from_sell_t0_1) AS NUMERIC) AS impact_from_t0_sell1_avg,
    
    -- Quantity 2: Impact from selling configured quantity 2
    CAST(MIN(c_impact_from_sell_t0_2) AS NUMERIC) AS impact_from_t0_sell2_min,
    CAST(MAX(c_impact_from_sell_t0_2) AS NUMERIC) AS impact_from_t0_sell2_max,
    CAST(AVG(c_impact_from_sell_t0_2) AS NUMERIC) AS impact_from_t0_sell2_avg,
    
    -- Quantity 3: Impact from selling configured quantity 3
    CAST(MIN(c_impact_from_sell_t0_3) AS NUMERIC) AS impact_from_t0_sell3_min,
    CAST(MAX(c_impact_from_sell_t0_3) AS NUMERIC) AS impact_from_t0_sell3_max,
    CAST(AVG(c_impact_from_sell_t0_3) AS NUMERIC) AS impact_from_t0_sell3_avg,
    
    -- =====================================================================
    -- QUANTITY NEEDED FOR TARGET BPS IMPACT (Selling Token0)
    -- =====================================================================
    -- Uses pre-calculated quantities from source table
    -- Aggregated as MIN, MAX, AVG over the 5-second interval
    
    -- BPS 1: Quantity needed for configured BPS impact 1
    CAST(MIN(c_sell_t0_for_impact_bps_1) AS NUMERIC) AS sell_t0_for_impact1_min,
    CAST(MAX(c_sell_t0_for_impact_bps_1) AS NUMERIC) AS sell_t0_for_impact1_max,
    CAST(AVG(c_sell_t0_for_impact_bps_1) AS NUMERIC) AS sell_t0_for_impact1_avg,
    
    -- BPS 2: Quantity needed for configured BPS impact 2
    CAST(MIN(c_sell_t0_for_impact_bps_2) AS NUMERIC) AS sell_t0_for_impact2_min,
    CAST(MAX(c_sell_t0_for_impact_bps_2) AS NUMERIC) AS sell_t0_for_impact2_max,
    CAST(AVG(c_sell_t0_for_impact_bps_2) AS NUMERIC) AS sell_t0_for_impact2_avg,
    
    -- BPS 3: Quantity needed for configured BPS impact 3
    CAST(MIN(c_sell_t0_for_impact_bps_3) AS NUMERIC) AS sell_t0_for_impact3_min,
    CAST(MAX(c_sell_t0_for_impact_bps_3) AS NUMERIC) AS sell_t0_for_impact3_max,
    CAST(AVG(c_sell_t0_for_impact_bps_3) AS NUMERIC) AS sell_t0_for_impact3_avg,
    
    -- =====================================================================
    -- IMPACT FROM SELLING TOKEN1 (Price Impact in BPS, SIGNED)
    -- =====================================================================
    -- Returns POSITIVE BPS (price t1/t0 increases when selling t1)
    -- Aggregated as MIN, MAX, AVG over the 5-second interval
    
    CAST(MIN(c_impact_from_sell_t1_1) AS NUMERIC) AS impact_from_t1_sell1_min,
    CAST(MAX(c_impact_from_sell_t1_1) AS NUMERIC) AS impact_from_t1_sell1_max,
    CAST(AVG(c_impact_from_sell_t1_1) AS NUMERIC) AS impact_from_t1_sell1_avg,
    
    CAST(MIN(c_impact_from_sell_t1_2) AS NUMERIC) AS impact_from_t1_sell2_min,
    CAST(MAX(c_impact_from_sell_t1_2) AS NUMERIC) AS impact_from_t1_sell2_max,
    CAST(AVG(c_impact_from_sell_t1_2) AS NUMERIC) AS impact_from_t1_sell2_avg,
    
    CAST(MIN(c_impact_from_sell_t1_3) AS NUMERIC) AS impact_from_t1_sell3_min,
    CAST(MAX(c_impact_from_sell_t1_3) AS NUMERIC) AS impact_from_t1_sell3_max,
    CAST(AVG(c_impact_from_sell_t1_3) AS NUMERIC) AS impact_from_t1_sell3_avg,
    
    -- =====================================================================
    -- QUANTITY NEEDED FOR TARGET BPS IMPACT (Selling Token1)
    -- =====================================================================
    
    CAST(MIN(c_sell_t1_for_impact_bps_1) AS NUMERIC) AS sell_t1_for_impact1_min,
    CAST(MAX(c_sell_t1_for_impact_bps_1) AS NUMERIC) AS sell_t1_for_impact1_max,
    CAST(AVG(c_sell_t1_for_impact_bps_1) AS NUMERIC) AS sell_t1_for_impact1_avg,
    
    CAST(MIN(c_sell_t1_for_impact_bps_2) AS NUMERIC) AS sell_t1_for_impact2_min,
    CAST(MAX(c_sell_t1_for_impact_bps_2) AS NUMERIC) AS sell_t1_for_impact2_max,
    CAST(AVG(c_sell_t1_for_impact_bps_2) AS NUMERIC) AS sell_t1_for_impact2_avg,
    
    CAST(MIN(c_sell_t1_for_impact_bps_3) AS NUMERIC) AS sell_t1_for_impact3_min,
    CAST(MAX(c_sell_t1_for_impact_bps_3) AS NUMERIC) AS sell_t1_for_impact3_max,
    CAST(AVG(c_sell_t1_for_impact_bps_3) AS NUMERIC) AS sell_t1_for_impact3_avg,
    
    -- =====================================================================
    -- LIQUIDITY CONCENTRATION METRICS (% of total liquidity)
    -- =====================================================================
    -- Uses pre-calculated concentration metrics from source table
    -- Returns LAST (most recent) value in the 5-second interval
    
    -- Concentration around peg (tick 0, price = 1.0) - for stablecoin pools
    CAST(LAST(c_liq_pct_within_xticks_of_peg_1, block_time) AS NUMERIC) AS liq_pct_within_xticks_of_peg_1,
    CAST(LAST(c_liq_pct_within_xticks_of_peg_2, block_time) AS NUMERIC) AS liq_pct_within_xticks_of_peg_2,
    CAST(LAST(c_liq_pct_within_xticks_of_peg_3, block_time) AS NUMERIC) AS liq_pct_within_xticks_of_peg_3,
    
    -- Concentration around active price (current_tick)
    CAST(LAST(c_liq_pct_within_xticks_of_active_1, block_time) AS NUMERIC) AS liq_pct_within_xticks_of_active_1,
    CAST(LAST(c_liq_pct_within_xticks_of_active_2, block_time) AS NUMERIC) AS liq_pct_within_xticks_of_active_2,
    CAST(LAST(c_liq_pct_within_xticks_of_active_3, block_time) AS NUMERIC) AS liq_pct_within_xticks_of_active_3,
    
    -- Total liquidity in decimal-adjusted token units (denominator for percentages)
    CAST(LAST(c_total_liquidity_tokens, block_time) AS NUMERIC) AS total_liquidity_tokens,
    
    -- Configuration arrays (tick halfspread levels used)
    LAST(c_liq_pct_within_xticks_of_peg_levels, block_time) AS liq_pct_within_xticks_of_peg_levels,
    LAST(c_liq_pct_within_xticks_of_active_levels, block_time) AS liq_pct_within_xticks_of_active_levels,
    
    -- Count of queries in this bucket (for data quality monitoring)
    COUNT(*) AS num_queries_in_bucket

FROM dexes.src_acct_tickarray_queries
WHERE block_time IS NOT NULL  -- Only include rows with valid blockchain timestamp
  -- NOTE: Impact metrics are optional - concentration metrics can exist without them
  -- AND c_impact_from_sell_t0_1 IS NOT NULL  -- Only include rows with pre-calculated impact metrics
  -- AND c_sell_t0_for_impact_bps_1 IS NOT NULL
GROUP BY 
    time_bucket('5 seconds'::interval, block_time),
    pool_address,
    protocol,
    token_pair;

-- Create index on bucket time for efficient time-series queries (DESC for recent-first)
CREATE INDEX IF NOT EXISTS idx_cagg_tickarrays_5s_bucket 
ON dexes.cagg_tickarrays_5s (bucket DESC);

-- Create index on pool_address for pool-specific queries (DESC for recent-first)
CREATE INDEX IF NOT EXISTS idx_cagg_tickarrays_5s_pool 
ON dexes.cagg_tickarrays_5s (pool_address, bucket DESC);

-- Create index on token_pair for pair-specific queries (DESC for recent-first)
CREATE INDEX IF NOT EXISTS idx_cagg_tickarrays_5s_pair 
ON dexes.cagg_tickarrays_5s (token_pair, bucket DESC);

-- Add comments
COMMENT ON MATERIALIZED VIEW dexes.cagg_tickarrays_5s IS 
'5-second continuous aggregate of liquidity depth impact and concentration metrics. 
CRITICAL: Buckets by block_time (blockchain time) instead of ingestion time to ensure proper alignment with swap events.
Includes current_tick_float (precise floating-point tick with sub-tick precision) and price_t1_per_t0 (decimal-adjusted human-readable price), both calculated from sqrt_price_x64.
Uses pre-calculated impact metrics from source table (c_impact_from_sell_t0_* and c_sell_t0_for_impact_bps_* columns).
Uses pre-calculated concentration metrics from source table (c_liq_pct_within_xticks_* columns).
Provides MIN, MAX, and AVG aggregations for impact metrics over the 5-second interval.
Provides LAST (most recent) values for concentration metrics over the 5-second interval.
Impact and concentration metrics are pre-calculated in Python before DB insertion for performance.
All BPS values measured on consistent token1/token0 price basis.
Concentration metrics measure % of liquidity within specific tick ranges of peg (price=1.0) and active price.
Uses LAST() aggregation for pool state fields and concentration metrics, MIN/MAX/AVG for impact metrics.
Indexes sorted DESC for efficient recent-first time-series queries.';

-- =====================================================================
-- EXAMPLE QUERIES
-- =====================================================================
--
-- 1. Latest impact metrics for all pools (sorted DESC via index):
--    SELECT * FROM dexes.cagg_tickarrays_5s 
--    ORDER BY bucket DESC LIMIT 10;
--
-- 2. Time series for specific pool with price and tick:
--    SELECT bucket, price_t1_per_t0, current_tick, current_tick_float,
--           impact_from_t0_sell1_min, impact_from_t0_sell1_max, impact_from_t0_sell1_avg,
--           impact_from_t0_sell2_min, impact_from_t0_sell2_max, impact_from_t0_sell2_avg
--    FROM dexes.cagg_tickarrays_5s
--    WHERE pool_address = 'YOUR_POOL_ADDRESS'
--    ORDER BY bucket DESC LIMIT 100;
--
-- 3. Compare liquidity across pools at specific time:
--    SELECT pool_address, token_pair,
--           impact_from_t0_sell1_avg, sell_t0_for_impact1_avg
--    FROM dexes.cagg_tickarrays_5s
--    WHERE bucket >= NOW() - INTERVAL '5 minutes'
--    ORDER BY bucket DESC, impact_from_t0_sell1_avg ASC;
--
-- 4. Get aggregated impact metrics:
--    SELECT bucket, pool_address, 
--           impact_from_t0_sell1_min, impact_from_t0_sell1_max, impact_from_t0_sell1_avg,
--           impact_from_t0_sell2_min, impact_from_t0_sell2_max, impact_from_t0_sell2_avg,
--           impact_from_t0_sell3_min, impact_from_t0_sell3_max, impact_from_t0_sell3_avg,
--           sell_t0_for_impact1_min, sell_t0_for_impact1_max, sell_t0_for_impact1_avg,
--           sell_t0_for_impact2_min, sell_t0_for_impact2_max, sell_t0_for_impact2_avg,
--           sell_t0_for_impact3_min, sell_t0_for_impact3_max, sell_t0_for_impact3_avg
--    FROM dexes.cagg_tickarrays_5s
--    ORDER BY bucket DESC LIMIT 10;
--
-- 5. Price time-series with human-readable format:
--    SELECT bucket, pool_address, token_pair,
--           price_t1_per_t0,
--           current_tick
--    FROM dexes.cagg_tickarrays_5s
--    WHERE token_pair = 'USX-USDC'
--    ORDER BY bucket DESC LIMIT 50;
--
-- 6. Liquidity concentration metrics for stablecoin pools:
--    SELECT bucket, pool_address, token_pair,
--           liq_pct_within_xticks_of_peg_1,
--           liq_pct_within_xticks_of_peg_2,
--           liq_pct_within_xticks_of_peg_3,
--           liq_pct_within_xticks_of_active_1,
--           total_liquidity_tokens
--    FROM dexes.cagg_tickarrays_5s
--    WHERE token_pair IN ('USDC-USDT', 'USX-USDC')
--    ORDER BY bucket DESC LIMIT 50;
--
-- 7. Monitor concentration risk - find pools with highly concentrated liquidity:
--    SELECT bucket, pool_address, token_pair,
--           liq_pct_within_xticks_of_active_1,
--           liq_pct_within_xticks_of_active_2,
--           liq_pct_within_xticks_of_active_3,
--           impact_from_t0_sell1_avg,
--           total_liquidity_tokens
--    FROM dexes.cagg_tickarrays_5s
--    WHERE bucket >= NOW() - INTERVAL '1 hour'
--      AND liq_pct_within_xticks_of_active_1 > 50  -- More than 50% in tight range
--    ORDER BY liq_pct_within_xticks_of_active_1 DESC;
--
-- 8. Stablecoin peg deviation analysis:
--    SELECT bucket, pool_address, token_pair,
--           price_t1_per_t0,
--           liq_pct_within_xticks_of_peg_1,
--           liq_pct_within_xticks_of_peg_2,
--           ABS(price_t1_per_t0 - 1.0) * 10000 AS depeg_bps
--    FROM dexes.cagg_tickarrays_5s
--    WHERE token_pair IN ('USDC-USDT', 'USX-USDC')
--      AND bucket >= NOW() - INTERVAL '24 hours'
--    ORDER BY depeg_bps DESC LIMIT 20;

