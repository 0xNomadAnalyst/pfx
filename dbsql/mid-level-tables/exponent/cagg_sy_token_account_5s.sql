-- Exponent SY Token Mint Continuous Aggregate (5-second buckets)
-- 
-- Aggregates SY token mint supply snapshots into 5-second intervals.
-- Uses LAST() since mint data is point-in-time state (not cumulative).
--
-- REFRESH: Manual via external cron job (no automatic policy)

-- Drop existing continuous aggregate if re-deploying
DROP MATERIALIZED VIEW IF EXISTS exponent.cagg_sy_token_account_5s CASCADE;

CREATE MATERIALIZED VIEW exponent.cagg_sy_token_account_5s
WITH (timescaledb.continuous) AS
SELECT
    -- Time bucket (5-second intervals on time - the hypertable dimension)
    time_bucket('5 seconds'::interval, time) AS bucket,
    
    -- SY Token identification
    mint_sy,
    
    -- Use LAST() to get most recent state within each 5s window
    -- Metadata
    LAST(slot, time) AS slot,
    LAST(block_time, time) AS block_time,
    
    -- SPL Token Mint Fields (KEY: supply)
    LAST(supply, time) AS supply,
    LAST(decimals, time) AS decimals,
    LAST(is_initialized, time) AS is_initialized,
    LAST(freeze_authority, time) AS freeze_authority,
    
    -- Calculated: Supply in UI units
    LAST(supply, time)::DOUBLE PRECISION / (10^LAST(decimals, time)) AS supply_ui,
    
    -- Token metadata (from on-chain discovery)
    LAST(meta_sy_symbol, time) AS meta_sy_symbol,
    LAST(meta_sy_name, time) AS meta_sy_name,
    LAST(meta_base_mint, time) AS meta_base_mint,
    
    -- Data source tracking
    LAST(data_source, time) AS data_source

FROM exponent.src_sy_token_account
GROUP BY bucket, mint_sy
ORDER BY bucket DESC, mint_sy;

-- Create indexes on the continuous aggregate for efficient querying
CREATE INDEX IF NOT EXISTS idx_cagg_sy_token_5s_mint 
ON exponent.cagg_sy_token_account_5s(mint_sy, bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_sy_token_5s_supply 
ON exponent.cagg_sy_token_account_5s(bucket DESC, supply);

-- Comment on the materialized view
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'cagg_sy_token_account_5s' AND relkind = 'm') THEN
        EXECUTE 'COMMENT ON MATERIALIZED VIEW exponent.cagg_sy_token_account_5s IS ''5-second continuous aggregate of SY token mint state - total supply tracking. Refresh manually via cron.''';
    END IF;
END $$;

-- NOTE: No automatic refresh policy - refresh externally via cron job:
-- CALL refresh_continuous_aggregate('exponent.cagg_sy_token_account_5s', NULL, NULL);


