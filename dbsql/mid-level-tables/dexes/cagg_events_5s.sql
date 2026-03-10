-- Continuous Aggregate: 5-second time buckets for all DEX events (swaps + liquidity)
-- Unifies swap and liquidity events into common token flow columns
-- Source: src_tx_events (gRPC + backfilled Solscan data)

-- Drop existing CAGG if recreating
-- DROP MATERIALIZED VIEW IF EXISTS dexes.cagg_events_5s CASCADE;

CREATE MATERIALIZED VIEW IF NOT EXISTS dexes.cagg_events_5s
WITH (timescaledb.continuous) AS
SELECT
    -- Time bucket (5 second intervals)
    time_bucket('5 seconds'::interval, s.meta_block_time) AS bucket_time,
    
    -- Partition dimensions (only pool_address and activity_category)
    s.pool_address,
    MAX(s.pool_address) AS pool_name,  -- Note: pool_name doesn't exist in src_tx_events, using pool_address
    MAX(s.token_pair) AS token_pair,
    MAX(s.protocol) AS protocol,
    
    -- Activity category (swap vs liquidity provision) - PRIMARY PARTITION
    CASE 
        WHEN s.event_type = 'swap' THEN 'swap'
        WHEN s.event_type IN ('liquidity_increase', 'liquidity_decrease') THEN 'lp'
        ELSE 'other'
    END AS activity_category,
    
    -- Event counts (aggregated by activity_category)
    COUNT(*) AS event_count,
    
    -- Unified token flow columns (aggregated by activity_category)
    -- All amounts are DECIMAL-ADJUSTED for human readability
    -- Amounts are summed within each 5-second bucket for the pool+category combination
    -- 
    -- For SWAPS (activity_category='swap'):
    --   - amount0_in = total token0 sold (decimal-adjusted by env_token0_decimals)
    --   - amount0_out = total token0 bought (decimal-adjusted by env_token0_decimals)
    --   - amount1_in = total token1 sold (decimal-adjusted by env_token1_decimals)
    --   - amount1_out = total token1 bought (decimal-adjusted by env_token1_decimals)
    --   All four can be non-zero when aggregating multiple swaps in different directions
    --
    -- For ADD LIQUIDITY (activity_category='lp', ADD_LIQ):
    --   - amount0_in = total token0 added (decimal-adjusted by env_token0_decimals)
    --   - amount1_in = total token1 added (decimal-adjusted by env_token1_decimals)
    --   - amount0_out, amount1_out = 0
    --
    -- For REMOVE LIQUIDITY (activity_category='lp', REMOVE_LIQ):
    --   - amount0_out = total token0 removed (decimal-adjusted by env_token0_decimals)
    --   - amount1_out = total token1 removed (decimal-adjusted by env_token1_decimals)
    --   - amount0_in, amount1_in = 0
    
    -- Token0 IN amounts (decimal-adjusted to human-readable format)
    -- For swaps: map based on comparing swap_token_in with pool's token addresses (from reference table)
    SUM(
        CASE 
            -- Swap: Check if swap_token_in matches token0
            WHEN s.swap_amount_in IS NOT NULL AND s.swap_token_in = pt.token0_address
                THEN CAST(s.swap_amount_in AS NUMERIC) / POWER(10, s.env_token0_decimals)
            -- Liquidity ADD: token0 going in
            WHEN s.liq_amount0_in IS NOT NULL 
                THEN CAST(s.liq_amount0_in AS NUMERIC) / POWER(10, s.env_token0_decimals)
            ELSE 0
        END
    ) AS amount0_in,
    
    -- Token1 IN amounts (decimal-adjusted to human-readable format)
    SUM(
        CASE 
            -- Swap: Check if swap_token_in matches token1
            WHEN s.swap_amount_in IS NOT NULL AND s.swap_token_in = pt.token1_address
                THEN CAST(s.swap_amount_in AS NUMERIC) / POWER(10, s.env_token1_decimals)
            -- Liquidity ADD: token1 going in
            WHEN s.liq_amount1_in IS NOT NULL 
                THEN CAST(s.liq_amount1_in AS NUMERIC) / POWER(10, s.env_token1_decimals)
            ELSE 0
        END
    ) AS amount1_in,
    
    -- Token0 OUT amounts (decimal-adjusted to human-readable format)
    SUM(
        CASE 
            -- Swap: Check if swap_token_out matches token0
            WHEN s.swap_amount_out IS NOT NULL AND s.swap_token_out = pt.token0_address
                THEN CAST(s.swap_amount_out AS NUMERIC) / POWER(10, s.env_token0_decimals)
            -- Liquidity REMOVE: token0 going out
            WHEN s.liq_amount0_out IS NOT NULL 
                THEN CAST(s.liq_amount0_out AS NUMERIC) / POWER(10, s.env_token0_decimals)
            ELSE 0
        END
    ) AS amount0_out,
    
    -- Token1 OUT amounts (decimal-adjusted to human-readable format)
    SUM(
        CASE 
            -- Swap: Check if swap_token_out matches token1
            WHEN s.swap_amount_out IS NOT NULL AND s.swap_token_out = pt.token1_address
                THEN CAST(s.swap_amount_out AS NUMERIC) / POWER(10, s.env_token1_decimals)
            -- Liquidity REMOVE: token1 going out
            WHEN s.liq_amount1_out IS NOT NULL 
                THEN CAST(s.liq_amount1_out AS NUMERIC) / POWER(10, s.env_token1_decimals)
            ELSE 0
        END
    ) AS amount1_out,
    
    -- Net token flows (for impact analysis)
    -- Positive values indicate net selling pressure for that token
    -- amount0_net > 0: net sell of token0 (more t0 going in than out)
    -- amount1_net > 0: net sell of token1 (more t1 going in than out)
    SUM(
        CASE 
            WHEN s.swap_amount_in IS NOT NULL AND s.swap_token_in = pt.token0_address
                THEN CAST(s.swap_amount_in AS NUMERIC) / POWER(10, s.env_token0_decimals)
            WHEN s.liq_amount0_in IS NOT NULL 
                THEN CAST(s.liq_amount0_in AS NUMERIC) / POWER(10, s.env_token0_decimals)
            ELSE 0
        END
    ) - SUM(
        CASE 
            WHEN s.swap_amount_out IS NOT NULL AND s.swap_token_out = pt.token0_address
                THEN CAST(s.swap_amount_out AS NUMERIC) / POWER(10, s.env_token0_decimals)
            WHEN s.liq_amount0_out IS NOT NULL 
                THEN CAST(s.liq_amount0_out AS NUMERIC) / POWER(10, s.env_token0_decimals)
            ELSE 0
        END
    ) AS amount0_net,
    
    SUM(
        CASE 
            WHEN s.swap_amount_in IS NOT NULL AND s.swap_token_in = pt.token1_address
                THEN CAST(s.swap_amount_in AS NUMERIC) / POWER(10, s.env_token1_decimals)
            WHEN s.liq_amount1_in IS NOT NULL 
                THEN CAST(s.liq_amount1_in AS NUMERIC) / POWER(10, s.env_token1_decimals)
            ELSE 0
        END
    ) - SUM(
        CASE 
            WHEN s.swap_amount_out IS NOT NULL AND s.swap_token_out = pt.token1_address
                THEN CAST(s.swap_amount_out AS NUMERIC) / POWER(10, s.env_token1_decimals)
            WHEN s.liq_amount1_out IS NOT NULL 
                THEN CAST(s.liq_amount1_out AS NUMERIC) / POWER(10, s.env_token1_decimals)
            ELSE 0
        END
    ) AS amount1_net,
    
    -- Volume-Weighted Average Prices (VWAP) for t0 in t1_per_t0 basis
    -- vwap_buy_t0: Average price paid when buying t0 (weighted by decimal-adjusted amount of t0 bought)
    -- Formula: SUM(price * decimal_adjusted_volume) / SUM(decimal_adjusted_volume)
    -- When buying t0, swap_token_out is t0 (verified by checking against liq events)
    CAST(CASE 
        WHEN SUM(CAST(COALESCE(s.swap_amount_out, '0') AS NUMERIC) / POWER(10, s.env_token0_decimals)) 
             FILTER (WHERE s.effective_price_buyt0_t1_per_t0 IS NOT NULL) > 0 
        THEN SUM(s.effective_price_buyt0_t1_per_t0 * (CAST(COALESCE(s.swap_amount_out, '0') AS NUMERIC) / POWER(10, s.env_token0_decimals))) 
             FILTER (WHERE s.effective_price_buyt0_t1_per_t0 IS NOT NULL) 
             / SUM(CAST(COALESCE(s.swap_amount_out, '0') AS NUMERIC) / POWER(10, s.env_token0_decimals)) 
             FILTER (WHERE s.effective_price_buyt0_t1_per_t0 IS NOT NULL)
        ELSE NULL
    END AS NUMERIC) AS vwap_buy_t0,
    
    -- vwap_sell_t0: Average price received when selling t0 (weighted by decimal-adjusted amount of t0 sold)
    -- When selling t0, swap_token_in is t0 (verified by checking against liq events)
    CAST(CASE 
        WHEN SUM(CAST(COALESCE(s.swap_amount_in, '0') AS NUMERIC) / POWER(10, s.env_token0_decimals)) 
             FILTER (WHERE s.effective_price_sellt0_t1_per_t0 IS NOT NULL) > 0 
        THEN SUM(s.effective_price_sellt0_t1_per_t0 * (CAST(COALESCE(s.swap_amount_in, '0') AS NUMERIC) / POWER(10, s.env_token0_decimals))) 
             FILTER (WHERE s.effective_price_sellt0_t1_per_t0 IS NOT NULL) 
             / SUM(CAST(COALESCE(s.swap_amount_in, '0') AS NUMERIC) / POWER(10, s.env_token0_decimals)) 
             FILTER (WHERE s.effective_price_sellt0_t1_per_t0 IS NOT NULL)
        ELSE NULL
    END AS NUMERIC) AS vwap_sell_t0,
    
    -- Maximum single swap amounts (swap events only)
    -- These track the largest individual swap in each direction within the bucket
    -- Useful for identifying outlier swaps without querying the source table
    -- amount0_in_max: Largest single swap selling token0 (decimal-adjusted)
    MAX(
        CASE 
            WHEN s.swap_amount_in IS NOT NULL AND s.swap_token_in = pt.token0_address
                THEN CAST(s.swap_amount_in AS NUMERIC) / POWER(10, s.env_token0_decimals)
            ELSE NULL
        END
    ) AS amount0_in_max,
    
    -- amount0_in_max_t1_out: Corresponding token1 output for the swap with amount0_in_max
    -- Uses array aggregation to get the token1_out value from the same row as the max amount0_in
    CAST(
        (array_agg(
            CAST(s.swap_amount_out AS NUMERIC) / POWER(10, s.env_token1_decimals)
            ORDER BY 
                CASE 
                    WHEN s.swap_amount_in IS NOT NULL AND s.swap_token_in = pt.token0_address
                        THEN CAST(s.swap_amount_in AS NUMERIC) / POWER(10, s.env_token0_decimals)
                    ELSE -1
                END DESC
        ) FILTER (WHERE s.swap_amount_in IS NOT NULL AND s.swap_token_in = pt.token0_address AND s.swap_token_out = pt.token1_address))[1] AS NUMERIC
    ) AS amount0_in_max_t1_out,
    
    -- amount1_in_max: Largest single swap selling token1 (decimal-adjusted)
    MAX(
        CASE 
            WHEN s.swap_amount_in IS NOT NULL AND s.swap_token_in = pt.token1_address
                THEN CAST(s.swap_amount_in AS NUMERIC) / POWER(10, s.env_token1_decimals)
            ELSE NULL
        END
    ) AS amount1_in_max,
    
    -- amount1_in_max_t0_out: Corresponding token0 output for the swap with amount1_in_max
    -- Uses array aggregation to get the token0_out value from the same row as the max amount1_in
    CAST(
        (array_agg(
            CAST(s.swap_amount_out AS NUMERIC) / POWER(10, s.env_token0_decimals)
            ORDER BY 
                CASE 
                    WHEN s.swap_amount_in IS NOT NULL AND s.swap_token_in = pt.token1_address
                        THEN CAST(s.swap_amount_in AS NUMERIC) / POWER(10, s.env_token1_decimals)
                    ELSE -1
                END DESC
        ) FILTER (WHERE s.swap_amount_in IS NOT NULL AND s.swap_token_in = pt.token1_address AND s.swap_token_out = pt.token0_address))[1] AS NUMERIC
    ) AS amount1_in_max_t0_out,
    
    -- Estimated price impact statistics (swap events only) - broken out by direction
    -- c_swap_est_impact_bps: Estimated price impact in basis points from latest liquidity depth
    -- Negative values = price decreased (t0 sell), Positive values = price increased (t1 sell)
    
    -- Overall statistics (all swaps)
    MIN(s.c_swap_est_impact_bps) FILTER (WHERE s.c_swap_est_impact_bps IS NOT NULL) AS c_swap_est_impact_bps_min,
    MAX(s.c_swap_est_impact_bps) FILTER (WHERE s.c_swap_est_impact_bps IS NOT NULL) AS c_swap_est_impact_bps_max,
    AVG(s.c_swap_est_impact_bps) FILTER (WHERE s.c_swap_est_impact_bps IS NOT NULL) AS c_swap_est_impact_bps_avg,
    
    -- T0 sell direction (swap_token_in = token0, negative impact expected)
    MIN(s.c_swap_est_impact_bps) FILTER (WHERE s.c_swap_est_impact_bps IS NOT NULL AND s.swap_token_in = pt.token0_address) AS c_swap_est_impact_bps_min_t0_sell,
    MAX(s.c_swap_est_impact_bps) FILTER (WHERE s.c_swap_est_impact_bps IS NOT NULL AND s.swap_token_in = pt.token0_address) AS c_swap_est_impact_bps_max_t0_sell,
    AVG(s.c_swap_est_impact_bps) FILTER (WHERE s.c_swap_est_impact_bps IS NOT NULL AND s.swap_token_in = pt.token0_address) AS c_swap_est_impact_bps_avg_t0_sell,
    
    -- T1 sell direction (swap_token_in = token1, positive impact expected)
    MIN(s.c_swap_est_impact_bps) FILTER (WHERE s.c_swap_est_impact_bps IS NOT NULL AND s.swap_token_in = pt.token1_address) AS c_swap_est_impact_bps_min_t1_sell,
    MAX(s.c_swap_est_impact_bps) FILTER (WHERE s.c_swap_est_impact_bps IS NOT NULL AND s.swap_token_in = pt.token1_address) AS c_swap_est_impact_bps_max_t1_sell,
    AVG(s.c_swap_est_impact_bps) FILTER (WHERE s.c_swap_est_impact_bps IS NOT NULL AND s.swap_token_in = pt.token1_address) AS c_swap_est_impact_bps_avg_t1_sell
    
FROM src_tx_events s
LEFT JOIN pool_tokens_reference pt ON s.pool_address = pt.pool_address
WHERE 
    -- Data quality filters to ensure token addresses match the pool's token pair
    
    -- For SWAP events: tokens must be in the pool's pair AND complementary (exclusive in/out)
    (
        s.event_type = 'swap'
        AND s.swap_token_in_symbol IS NOT NULL
        AND s.swap_token_out_symbol IS NOT NULL
        AND s.swap_token_in_symbol != s.swap_token_out_symbol  -- Exclusive: different tokens
        -- Both tokens must be in the token_pair (e.g., for "USX-USDC", both USX and USDC must appear)
        AND s.token_pair LIKE '%' || s.swap_token_in_symbol || '%'
        AND s.token_pair LIKE '%' || s.swap_token_out_symbol || '%'
    )
    
    OR
    
    -- For ADD LIQUIDITY: both tokens going in must match the pool's pair
    (
        s.event_type = 'liquidity_increase'
        AND s.liq_token0_in_symbol IS NOT NULL
        AND s.liq_token1_in_symbol IS NOT NULL
        -- Both tokens must be in the token_pair
        AND s.token_pair LIKE '%' || s.liq_token0_in_symbol || '%'
        AND s.token_pair LIKE '%' || s.liq_token1_in_symbol || '%'
    )
    
    OR
    
    -- For REMOVE LIQUIDITY: both tokens coming out must match the pool's pair
    (
        s.event_type = 'liquidity_decrease'
        AND s.liq_token0_out_symbol IS NOT NULL
        AND s.liq_token1_out_symbol IS NOT NULL
        -- Both tokens must be in the token_pair
        AND s.token_pair LIKE '%' || s.liq_token0_out_symbol || '%'
        AND s.token_pair LIKE '%' || s.liq_token1_out_symbol || '%'
    )

GROUP BY 
    time_bucket('5 seconds'::interval, s.meta_block_time),
    s.pool_address,
    CASE 
        WHEN s.event_type = 'swap' THEN 'swap'
        WHEN s.event_type IN ('liquidity_increase', 'liquidity_decrease') THEN 'lp'
        ELSE 'other'
    END
ORDER BY time_bucket('5 seconds'::interval, s.meta_block_time) DESC;

-- Note: COMMENT ON MATERIALIZED VIEW doesn't work for TimescaleDB continuous aggregates
-- Description: Continuous aggregate with 5-second time buckets. Aggregates swap and liquidity events by pool_address and activity_category. 
-- All amounts are DECIMAL-ADJUSTED using env_token0_decimals and env_token1_decimals for human-readable values.
-- Swap amounts are correctly mapped to token0/token1 columns using pool_tokens_reference table.
-- When aggregating swaps, both amount0_in/out and amount1_in/out can be non-zero (bidirectional trading).
-- Includes VWAP for buy/sell trades of token0, and net token flows (amount0_net, amount1_net) for impact analysis.
-- Maximum single swap tracking: amount0_in_max/amount0_in_max_t1_out and amount1_in_max/amount1_in_max_t0_out track
--   the largest individual swap in each direction within each bucket, allowing efficient outlier identification without
--   querying the source table.
-- Price impact metrics: c_swap_est_impact_bps_min/max/avg - Estimated price impact statistics (swap events only).
--   Calculated automatically via trigger using impact_bps_from_qsell_latest() with latest liquidity depth.
--   Negative values = price decreased (t0 sell), Positive values = price increased (t1 sell).
--   Also broken out by direction: *_t0_sell (swap_token_in = token0) and *_t1_sell (swap_token_in = token1).
--   NOTE: Outlier filtering is applied at the view layer (get_view_dex_timeseries) using dynamic thresholds
--   computed from the distribution of impact values across the data.
-- Data quality filters ensure: (1) swap tokens are exclusive and match pool pair, (2) liquidity tokens match pool pair.

-- Create indexes on the materialized view for better query performance
CREATE INDEX IF NOT EXISTS idx_cagg_events_5s_bucket_time 
    ON cagg_events_5s (bucket_time DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_events_5s_pool 
    ON cagg_events_5s (pool_address, bucket_time DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_events_5s_token_pair 
    ON cagg_events_5s (token_pair, bucket_time DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_events_5s_activity_category 
    ON cagg_events_5s (activity_category, bucket_time DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_events_5s_pool_category 
    ON cagg_events_5s (pool_address, activity_category, bucket_time DESC);

-- Indexes for VWAP analysis
CREATE INDEX IF NOT EXISTS idx_cagg_events_5s_vwap_buy 
    ON cagg_events_5s (vwap_buy_t0) 
    WHERE vwap_buy_t0 IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_cagg_events_5s_vwap_sell 
    ON cagg_events_5s (vwap_sell_t0) 
    WHERE vwap_sell_t0 IS NOT NULL;

-- Indexes for price impact analysis (swap events only)
CREATE INDEX IF NOT EXISTS idx_cagg_events_5s_impact_avg 
    ON cagg_events_5s (c_swap_est_impact_bps_avg) 
    WHERE c_swap_est_impact_bps_avg IS NOT NULL AND activity_category = 'swap';

CREATE INDEX IF NOT EXISTS idx_cagg_events_5s_impact_max 
    ON cagg_events_5s (c_swap_est_impact_bps_max) 
    WHERE c_swap_est_impact_bps_max IS NOT NULL AND activity_category = 'swap';

-- Indexes for maximum single swap amounts (swap events only)
CREATE INDEX IF NOT EXISTS idx_cagg_events_5s_amount0_in_max 
    ON cagg_events_5s (amount0_in_max) 
    WHERE amount0_in_max IS NOT NULL AND activity_category = 'swap';

CREATE INDEX IF NOT EXISTS idx_cagg_events_5s_amount1_in_max 
    ON cagg_events_5s (amount1_in_max) 
    WHERE amount1_in_max IS NOT NULL AND activity_category = 'swap';

-- Example queries:

-- Recent 5-second buckets with swap volume and VWAP
-- SELECT 
--     bucket_time,
--     pool_name,
--     token_pair,
--     activity_category,
--     event_count,
--     amount0_in,
--     amount0_out,
--     amount0_net,
--     amount1_net,
--     vwap_buy_t0,
--     vwap_sell_t0
-- FROM dexes.cagg_events_5s
-- WHERE activity_category = 'swap'
-- ORDER BY bucket_time DESC
-- LIMIT 20;

-- Liquidity events by pool (combines ADD and REMOVE)
-- SELECT 
--     bucket_time,
--     pool_name,
--     event_count,
--     amount0_in,
--     amount1_in,
--     amount0_out,
--     amount1_out
-- FROM test_tables.cagg_events_5s
-- WHERE activity_category = 'lp'
-- ORDER BY bucket_time DESC
-- LIMIT 20;

-- Swap volume aggregated by pool over time
-- SELECT 
--     bucket_time,
--     pool_name,
--     token_pair,
--     SUM(event_count) as total_swaps,
--     SUM(amount0_in) as total_volume_in,
--     SUM(amount0_out) as total_volume_out
-- FROM test_tables.cagg_events_5s
-- WHERE activity_category = 'swap'
-- GROUP BY bucket_time, pool_name, token_pair
-- ORDER BY bucket_time DESC
-- LIMIT 20;

-- Net liquidity changes per pool (aggregating ADD and REMOVE)
-- SELECT 
--     pool_name,
--     time_bucket('1 minute', bucket_time) as minute,
--     SUM(amount0_in) as token0_added,
--     SUM(amount0_out) as token0_removed,
--     SUM(amount0_in) - SUM(amount0_out) as token0_net_change,
--     SUM(amount1_in) as token1_added,
--     SUM(amount1_out) as token1_removed,
--     SUM(amount1_in) - SUM(amount1_out) as token1_net_change
-- FROM test_tables.cagg_events_5s
-- WHERE activity_category = 'lp'
-- GROUP BY pool_name, minute
-- ORDER BY minute DESC
-- LIMIT 20;

-- Compare swap vs LP activity across all pools
-- SELECT 
--     bucket_time,
--     activity_category,
--     SUM(event_count) as total_events
-- FROM test_tables.cagg_events_5s
-- GROUP BY bucket_time, activity_category
-- ORDER BY bucket_time DESC
-- LIMIT 20;

-- VWAP analysis: Buy vs Sell pressure with price
-- SELECT 
--     bucket_time,
--     pool_name,
--     token_pair,
--     vwap_buy_t0,
--     amount0_out as buy_volume,
--     vwap_sell_t0,
--     amount0_in as sell_volume,
--     vwap_buy_t0 - vwap_sell_t0 as bid_ask_spread
-- FROM test_tables.cagg_events_5s
-- WHERE activity_category = 'swap'
--     AND (vwap_buy_t0 IS NOT NULL OR vwap_sell_t0 IS NOT NULL)
-- ORDER BY bucket_time DESC
-- LIMIT 20;

-- Time-series VWAP for a specific pool (e.g., USX-USDC)
-- SELECT 
--     bucket_time,
--     vwap_buy_t0,
--     vwap_sell_t0,
--     COALESCE(vwap_buy_t0, vwap_sell_t0) as last_price,
--     amount0_in + amount0_out as total_volume
-- FROM test_tables.cagg_events_5s
-- WHERE pool_address = 'EWivkwNtcxuPsU6RyD7Pfvs7u9Yv8nQ79tJ7xgGyPrp6'
--     AND activity_category = 'swap'
-- ORDER BY bucket_time DESC
-- LIMIT 50;

-- Net swap impact analysis using wrapper function
-- Shows estimated price impact based on net token flows in each bucket
-- SELECT 
--     bucket_time,
--     pool_name,
--     token_pair,
--     amount0_net,
--     amount1_net,
--     vwap_buy_t0,
--     vwap_sell_t0,
--     dexes.impact_netswap_value(pool_address, bucket_time) as net_swap_impact_bps
-- FROM dexes.cagg_events_5s
-- WHERE activity_category = 'swap'
--   AND pool_address = 'EWivkwNtcxuPsU6RyD7Pfvs7u9Yv8nQ79tJ7xgGyPrp6'
--   AND bucket_time >= NOW() - INTERVAL '1 hour'
-- ORDER BY bucket_time DESC
-- LIMIT 20;
