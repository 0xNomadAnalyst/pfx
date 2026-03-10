-- NAME: cagg_base_token_escrow_5s
-- Continuous Aggregate: Underlying Token Escrow Snapshots (5-second intervals)
--
-- Aggregates underlying token escrow data to 5-second buckets for efficient querying.
-- Tracks the actual backing asset reserves (wfragSOL, eUSX, etc.) that back SY tokens.
--
-- CRITICAL FOR RISK MONITORING:
-- - escrow balance vs (sy_supply × exchange_rate)
-- - Collateralization ratio trends
-- - Under-collateralization detection
--
-- Refresh: Via cronjob (see cronjobs/cagg_refresh/)

-- Drop existing view if it exists (for schema updates)
DROP MATERIALIZED VIEW IF EXISTS exponent.cagg_base_token_escrow_5s CASCADE;

-- Create continuous aggregate
CREATE MATERIALIZED VIEW exponent.cagg_base_token_escrow_5s
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('5 seconds', ute.time) AS bucket,
    ute.escrow_address,
    ute.mint,
    ute.owner,
    
    -- Latest values from account data (LAST aggregation)
    LAST(ute.amount, ute.time) AS amount_last,
    LAST(ute.is_initialized, ute.time) AS is_initialized_last,
    COALESCE(
        LAST(ute.amount, ute.time),
        0
    )::DOUBLE PRECISION / NULLIF(POWER(10::DOUBLE PRECISION, COALESCE(MAX(akr.env_sy_decimals), 9)), 0.0) AS c_balance_readable_last,
    
    -- Statistical aggregations (own data)
    AVG(ute.amount) AS amount_avg,
    MIN(ute.amount) AS amount_min,
    MAX(ute.amount) AS amount_max,
    AVG(ute.amount)::DOUBLE PRECISION / NULLIF(POWER(10::DOUBLE PRECISION, COALESCE(MAX(akr.env_sy_decimals), 9)), 0.0) AS c_balance_readable_avg,
    
    -- Token metadata (from on-chain discovery)
    LAST(ute.meta_base_symbol, ute.time) AS meta_base_symbol,
    LAST(ute.meta_base_name, ute.time) AS meta_base_name,
    LAST(ute.meta_base_decimals, ute.time) AS meta_base_decimals,
    
    -- Data source tracking
    LAST(ute.data_source, ute.time) AS data_source,
    
    -- Metadata
    COUNT(*) AS sample_count,
    MIN(ute.time) AS bucket_start,
    MAX(ute.time) AS bucket_end,
    LAST(ute.slot, ute.time) AS slot_last,
    LAST(ute.block_time, ute.time) AS block_time_last

FROM exponent.src_base_token_escrow AS ute
LEFT JOIN exponent.aux_key_relations AS akr
    ON akr.underlying_escrow_address = ute.escrow_address
GROUP BY bucket, ute.escrow_address, ute.mint, ute.owner
WITH NO DATA;

-- Add refresh policy (refresh every 5 seconds, retain 7 days of aggregated data)
SELECT add_continuous_aggregate_policy(
    'exponent.cagg_base_token_escrow_5s',
    start_offset => INTERVAL '1 hour',
    end_offset => INTERVAL '5 seconds',
    schedule_interval => INTERVAL '5 seconds',
    if_not_exists => TRUE
);

-- Add retention policy (drop data older than 90 days)
SELECT add_retention_policy(
    'exponent.cagg_base_token_escrow_5s',
    drop_after => INTERVAL '90 days',
    if_not_exists => TRUE
);

-- Create indexes on the continuous aggregate
CREATE INDEX IF NOT EXISTS idx_cagg_underlying_escrow_5s_escrow_bucket
    ON exponent.cagg_base_token_escrow_5s (escrow_address, bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_underlying_escrow_5s_mint_bucket
    ON exponent.cagg_base_token_escrow_5s (mint, bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_underlying_escrow_5s_owner_bucket
    ON exponent.cagg_base_token_escrow_5s (owner, bucket DESC);

-- Note: For risk metrics (collateralization, deviation), query the view:
-- exponent.view_underlying_escrow_with_metrics
-- which joins CAGG data with SyMeta and SY token data

-- View comment
COMMENT ON MATERIALIZED VIEW exponent.cagg_base_token_escrow_5s IS 
    '5-second continuous aggregate of underlying token escrow data. Tracks backing asset reserves for SY tokens. For collateralization metrics, join with SyMeta and SY token data using view_underlying_escrow_with_metrics.';

-- Example queries:

-- Get latest escrow balance (5s resolution):
-- SELECT bucket, escrow_address, amount_last, c_balance_readable_last
-- FROM exponent.cagg_base_token_escrow_5s
-- WHERE escrow_address = 'Aast2jB47UTXmeKLRTMQyxQo3agFF9uH5rzkDtBHdW7w'
-- ORDER BY bucket DESC
-- LIMIT 1;

-- For collateralization metrics, use the view that joins with SyMeta/SY token:
-- SELECT * FROM exponent.view_underlying_escrow_with_metrics
-- ORDER BY collateralization_ratio ASC;

-- Balance change over time:
-- SELECT bucket, escrow_address,
--        amount_last,
--        LAG(amount_last) OVER (PARTITION BY escrow_address ORDER BY bucket) AS prev_amount,
--        amount_last - LAG(amount_last) OVER (PARTITION BY escrow_address ORDER BY bucket) AS amount_change
-- FROM exponent.cagg_base_token_escrow_5s
-- WHERE escrow_address = 'Aast2jB47UTXmeKLRTMQyxQo3agFF9uH5rzkDtBHdW7w'
--   AND bucket > NOW() - INTERVAL '24 hours'
-- ORDER BY bucket DESC;
