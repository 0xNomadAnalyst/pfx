-- Continuous Aggregate: Token Vault Reserves (5-second intervals)
-- 
-- Tracks SPL token account balances for pool reserves
-- Shows the most recent vault state within each 5-second bucket
--
-- Source: src_acct_vaults
-- Time Column: block_time (blockchain time) for proper alignment with swap events
-- Bucket Size: 5 seconds
--
-- CRITICAL: Buckets by block_time (blockchain time) instead of time (ingestion time)
-- to ensure reserves align correctly with swap events which are bucketed by meta_block_time

CREATE MATERIALIZED VIEW IF NOT EXISTS dexes.cagg_vaults_5s
WITH (timescaledb.continuous) AS
SELECT
    -- Time bucket (5-second intervals on block_time - blockchain time for proper alignment)
    time_bucket('5 seconds'::interval, block_time) AS bucket_time,
    
    -- Also capture ingestion time for reference
    LAST(time, block_time) AS last_ingestion_time,
    
    -- Partition dimensions
    pool_address,
    LAST(protocol, block_time) AS protocol,
    LAST(token_pair, block_time) AS token_pair,
    
    -- Token 0 vault information
    LAST(token_0_vault, block_time) AS token_0_vault,
    LAST(token_0_mint, block_time) AS token_0_mint,
    LAST(token0_decimals, block_time) AS token0_decimals,
    CAST(LAST(token_0_value, block_time) AS NUMERIC) AS token_0_value,  -- Decimal-adjusted reserve
    
    -- Token 1 vault information
    LAST(token_1_vault, block_time) AS token_1_vault,
    LAST(token_1_mint, block_time) AS token_1_mint,
    LAST(token1_decimals, block_time) AS token1_decimals,
    CAST(LAST(token_1_value, block_time) AS NUMERIC) AS token_1_value,  -- Decimal-adjusted reserve
    
    -- Metadata
    LAST(slot, block_time) AS last_slot,
    LAST(block_time, block_time) AS last_block_time,  -- Most recent block_time in bucket
    COUNT(*) AS num_updates_in_bucket

FROM dexes.src_acct_vaults
WHERE block_time IS NOT NULL  -- Only include rows with valid blockchain timestamp
GROUP BY 
    bucket_time,
    pool_address
ORDER BY bucket_time DESC;

-- Add comment
COMMENT ON MATERIALIZED VIEW dexes.cagg_vaults_5s IS 
    'Continuous aggregate with 5-second time buckets. Tracks token vault reserves (SPL token account balances) for pool liquidity. 
    CRITICAL: Buckets by block_time (blockchain time) instead of ingestion time to ensure proper alignment with swap events.
    Shows the most recent vault state within each bucket using LAST() aggregation. token_0_value and token_1_value are decimal-adjusted for human readability.';

-- Create indexes for efficient queries
CREATE INDEX IF NOT EXISTS idx_cagg_vaults_5s_bucket_time 
    ON dexes.cagg_vaults_5s (bucket_time DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_vaults_5s_pool 
    ON dexes.cagg_vaults_5s (pool_address, bucket_time DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_vaults_5s_token_pair 
    ON dexes.cagg_vaults_5s (token_pair, bucket_time DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_vaults_5s_token0_mint 
    ON dexes.cagg_vaults_5s (token_0_mint, bucket_time DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_vaults_5s_token1_mint 
    ON dexes.cagg_vaults_5s (token_1_mint, bucket_time DESC);

-- Example queries:

-- Recent vault balances for all pools
-- SELECT 
--     bucket_time,
--     pool_address,
--     token_pair,
--     token_0_value,
--     token_1_value,
--     num_updates_in_bucket
-- FROM test_tables.cagg_vaults_5s
-- ORDER BY bucket_time DESC
-- LIMIT 20;

-- Vault balance history for a specific pool
-- SELECT 
--     bucket_time,
--     token_pair,
--     token_0_value,
--     token_1_value
-- FROM test_tables.cagg_vaults_5s
-- WHERE pool_address = 'YOUR_POOL_ADDRESS'
-- ORDER BY bucket_time DESC
-- LIMIT 100;

-- Token reserve changes over time
-- SELECT 
--     bucket_time,
--     token_pair,
--     token_0_value,
--     LAG(token_0_value) OVER (PARTITION BY pool_address ORDER BY bucket_time) as prev_token_0,
--     token_0_value - LAG(token_0_value) OVER (PARTITION BY pool_address ORDER BY bucket_time) as token_0_change,
--     token_1_value,
--     LAG(token_1_value) OVER (PARTITION BY pool_address ORDER BY bucket_time) as prev_token_1,
--     token_1_value - LAG(token_1_value) OVER (PARTITION BY pool_address ORDER BY bucket_time) as token_1_change
-- FROM test_tables.cagg_vaults_5s
-- WHERE pool_address = 'YOUR_POOL_ADDRESS'
-- ORDER BY bucket_time DESC
-- LIMIT 50;

-- Compare reserves across all pools at latest time
-- SELECT 
--     pool_address,
--     token_pair,
--     token_0_value,
--     token_1_value,
--     bucket_time
-- FROM test_tables.cagg_vaults_5s
-- WHERE bucket_time = (SELECT MAX(bucket_time) FROM test_tables.cagg_vaults_5s)
-- ORDER BY token_pair;

