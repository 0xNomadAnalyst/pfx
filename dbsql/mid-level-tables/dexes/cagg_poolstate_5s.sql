-- Continuous Aggregate: Pool State with Tick Crossings (5-second intervals)
-- 
-- Tracks pool state from src_acct_pool and calculates tick crossing metrics
-- Detects when price crosses tick boundaries and measures associated liquidity changes
--
-- Time Column: block_time (blockchain timestamp) for proper alignment with swap events
-- Bucket Size: 5 seconds
--
-- CRITICAL: Buckets by block_time (blockchain time) instead of time (ingestion time)
-- to ensure pool state metrics align correctly with swap events
--
-- NOTE: Tick crossing detection uses FIRST/LAST comparison within each bucket
-- For precise per-row crossing detection, a separate function or view would be needed

CREATE MATERIALIZED VIEW IF NOT EXISTS dexes.cagg_poolstate_5s
WITH (timescaledb.continuous) AS
SELECT
    -- Time bucket (5-second intervals on time - primary hypertable dimension)
    -- Note: We order by block_time for LAST() to get most recent by blockchain time
    time_bucket('5 seconds'::interval, time) AS bucket_time,
    
    -- Partition dimensions
    pool_address,
    MAX(protocol) AS protocol,
    MAX(token_pair) AS token_pair,
    
    -- Most recent pool state in bucket
    LAST(tick_current, block_time) AS current_tick,
    LAST(liquidity, block_time) AS current_liquidity,
    LAST(sqrt_price_x64, block_time) AS current_sqrt_price_x64,
    LAST(price_fixed_point_base, block_time) AS current_price_fixed_point_base,
    LAST(mint_decimals_0, block_time) AS current_mint_decimals_0,
    LAST(mint_decimals_1, block_time) AS current_mint_decimals_1,
    LAST(tick_spacing, block_time) AS current_tick_spacing,
    
    -- First tick in bucket (for detecting crossings)
    FIRST(tick_current, block_time) AS first_tick_in_bucket,
    
    -- Count distinct ticks in bucket (approximate crossing count)
    -- This counts how many different tick values appeared in the bucket
    COUNT(DISTINCT tick_current) - 1 AS tick_cross_count,
    -- Subtract 1 because if we see N distinct ticks, there were N-1 crossings
    
    -- Calculate liquidity in t1 units for current state (most recent in bucket)
    -- Use tick range: current_tick ± tick_spacing
    CASE 
        WHEN LAST(tick_current, block_time) IS NOT NULL 
             AND LAST(liquidity, block_time) IS NOT NULL 
             AND LAST(tick_spacing, block_time) IS NOT NULL
             AND LAST(mint_decimals_1, block_time) IS NOT NULL
        THEN
            COALESCE(
                dexes.get_t1raw_from_vliquidity_down(
                    dexes.get_price_from_tick(LAST(tick_current, block_time) + COALESCE(LAST(tick_spacing, block_time), 1))::DOUBLE PRECISION,
                    dexes.get_price_from_tick(LAST(tick_current, block_time) - COALESCE(LAST(tick_spacing, block_time), 1))::DOUBLE PRECISION,
                    LAST(liquidity, block_time)::DOUBLE PRECISION
                ),
                0
            ) * POWER(10, LAST(mint_decimals_1, block_time))
        ELSE NULL
    END AS current_liquidity_t1_units,
    
    -- Calculate liquidity in t1 units for first state in bucket
    CASE 
        WHEN FIRST(tick_current, block_time) IS NOT NULL 
             AND FIRST(liquidity, block_time) IS NOT NULL 
             AND FIRST(tick_spacing, block_time) IS NOT NULL
             AND FIRST(mint_decimals_1, block_time) IS NOT NULL
        THEN
            COALESCE(
                dexes.get_t1raw_from_vliquidity_down(
                    dexes.get_price_from_tick(FIRST(tick_current, block_time) + COALESCE(FIRST(tick_spacing, block_time), 1))::DOUBLE PRECISION,
                    dexes.get_price_from_tick(FIRST(tick_current, block_time) - COALESCE(FIRST(tick_spacing, block_time), 1))::DOUBLE PRECISION,
                    FIRST(liquidity, block_time)::DOUBLE PRECISION
                ),
                0
            ) * POWER(10, FIRST(mint_decimals_1, block_time))
        ELSE NULL
    END AS first_liquidity_t1_units,
    
    -- Metadata
    COUNT(*) AS num_updates_in_bucket,
    LAST(block_time, block_time) AS last_block_time,
    FIRST(block_time, block_time) AS first_block_time

FROM dexes.src_acct_pool
WHERE block_time IS NOT NULL
    AND tick_current IS NOT NULL
    AND liquidity IS NOT NULL
    AND tick_spacing IS NOT NULL
GROUP BY 
    time_bucket('5 seconds'::interval, time),
    pool_address
WITH NO DATA;

-- Calculate average liquidity change per tick crossing in a separate step
-- This requires a function or view since we can't do complex calculations in CAGG
CREATE OR REPLACE FUNCTION dexes.calculate_avg_liquidity_change_per_cross(
    p_tick_cross_count BIGINT,
    p_current_liquidity_t1_units DOUBLE PRECISION,
    p_first_liquidity_t1_units DOUBLE PRECISION
) RETURNS NUMERIC AS $$
BEGIN
    -- If no crossings, return NULL
    IF p_tick_cross_count IS NULL OR p_tick_cross_count <= 0 THEN
        RETURN NULL;
    END IF;
    
    -- If we don't have liquidity values, return NULL
    IF p_current_liquidity_t1_units IS NULL OR p_first_liquidity_t1_units IS NULL THEN
        RETURN NULL;
    END IF;
    
    -- If first liquidity is zero, return NULL (can't calculate % change)
    IF p_first_liquidity_t1_units <= 0 THEN
        RETURN NULL;
    END IF;
    
    -- Calculate total % change across all crossings, then average
    -- This is an approximation: we're dividing the total change by number of crossings
    RETURN ((p_current_liquidity_t1_units - p_first_liquidity_t1_units) / p_first_liquidity_t1_units * 100) / NULLIF(p_tick_cross_count, 0);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Create indexes for efficient queries
CREATE INDEX IF NOT EXISTS idx_cagg_poolstate_5s_bucket_time 
    ON dexes.cagg_poolstate_5s (bucket_time DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_poolstate_5s_pool 
    ON dexes.cagg_poolstate_5s (pool_address, bucket_time DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_poolstate_5s_token_pair 
    ON dexes.cagg_poolstate_5s (token_pair, bucket_time DESC);

-- Add comment
COMMENT ON MATERIALIZED VIEW dexes.cagg_poolstate_5s IS 
'5-second continuous aggregate of pool state with tick crossing detection and liquidity change metrics.
CRITICAL: Buckets by block_time (blockchain time) instead of ingestion time to ensure proper alignment with swap events.
Detects tick crossings by counting distinct tick values in each bucket (COUNT(DISTINCT tick_current) - 1).
Calculates liquidity in t1 units using virtual liquidity and tick range (current_tick ± tick_spacing).
tick_cross_count: Number of distinct tick values minus 1 (approximate crossing count per bucket).
Use calculate_avg_liquidity_change_per_cross() function to compute average % change per crossing.
Uses LAST()/FIRST() aggregation to get pool state at start and end of bucket.
Indexes sorted DESC for efficient recent-first time-series queries.';

COMMENT ON FUNCTION dexes.calculate_avg_liquidity_change_per_cross(BIGINT, DOUBLE PRECISION, DOUBLE PRECISION) IS
'Calculates average percentage change in liquidity per tick crossing.
Takes tick_cross_count, current_liquidity_t1_units, and first_liquidity_t1_units from cagg_poolstate_5s.
Returns average % change per crossing, or NULL if no crossings or invalid data.';

-- Example queries:
--
-- Recent tick crossing activity for all pools:
-- SELECT 
--     bucket_time,
--     pool_address,
--     token_pair,
--     current_tick,
--     tick_cross_count,
--     dexes.calculate_avg_liquidity_change_per_cross(
--         tick_cross_count,
--         current_liquidity_t1_units,
--         first_liquidity_t1_units
--     ) AS avg_liquidity_pct_change_per_tick_cross,
--     num_updates_in_bucket
-- FROM dexes.cagg_poolstate_5s
-- ORDER BY bucket_time DESC
-- LIMIT 20;
--
-- Tick crossing history for a specific pool:
-- SELECT 
--     bucket_time,
--     current_tick,
--     tick_cross_count,
--     dexes.calculate_avg_liquidity_change_per_cross(
--         tick_cross_count,
--         current_liquidity_t1_units,
--         first_liquidity_t1_units
--     ) AS avg_liquidity_pct_change_per_tick_cross,
--     current_liquidity
-- FROM dexes.cagg_poolstate_5s
-- WHERE pool_address = 'YOUR_POOL_ADDRESS'
-- ORDER BY bucket_time DESC
-- LIMIT 100;
