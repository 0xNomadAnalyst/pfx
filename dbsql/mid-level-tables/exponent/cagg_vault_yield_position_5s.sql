-- Exponent Vault Yield Position Continuous Aggregate (5-second buckets)
-- 
-- Aggregates YieldTokenPosition account snapshots into 5-second intervals.
-- Tracks the vault's robot YT position that collects yield from unstaked YT.
-- Uses LAST() since position data is point-in-time state (not cumulative).
--
-- REFRESH: Manual via external cron job (no automatic policy)

-- Drop existing continuous aggregate if re-deploying
DROP MATERIALIZED VIEW IF EXISTS exponent.cagg_vault_yield_position_5s CASCADE;

CREATE MATERIALIZED VIEW exponent.cagg_vault_yield_position_5s
WITH (timescaledb.continuous) AS
SELECT
    -- Time bucket (5-second intervals on time - the hypertable dimension)
    time_bucket('5 seconds'::interval, time) AS bucket,
    
    -- YieldPosition identification
    yield_position_address,
    
    -- Use LAST() to get most recent state within each 5s window
    -- Metadata
    LAST(slot, time) AS slot,
    LAST(block_time, time) AS block_time,
    LAST(owner, time) AS owner,
    LAST(vault, time) AS vault,
    
    -- YT Position State
    LAST(yt_balance, time) AS yt_balance,
    
    -- Interest Tracking
    LAST(interest_last_seen_index, time) AS interest_last_seen_index,
    LAST(interest_staged, time) AS interest_staged,
    
    -- Emissions Tracking
    LAST(emissions_count, time) AS emissions_count,
    
    -- Calculated Metrics
    LAST(c_total_staged_interest, time) AS c_total_staged_interest,
    LAST(c_total_staged_emissions, time) AS c_total_staged_emissions,
    LAST(c_has_pending_yield, time) AS c_has_pending_yield,
    
    -- Token metadata (from on-chain discovery)
    LAST(meta_yt_symbol, time) AS meta_yt_symbol,
    LAST(meta_yt_name, time) AS meta_yt_name,
    LAST(meta_yt_decimals, time) AS meta_yt_decimals,
    LAST(meta_base_mint, time) AS meta_base_mint,
    
    -- Data source tracking
    LAST(data_source, time) AS data_source

FROM exponent.src_vault_yield_position
GROUP BY bucket, yield_position_address
ORDER BY bucket DESC, yield_position_address;

-- Create indexes on the continuous aggregate for efficient querying
CREATE INDEX IF NOT EXISTS idx_cagg_vault_yield_position_5s_address 
ON exponent.cagg_vault_yield_position_5s(yield_position_address, bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_vault_yield_position_5s_vault 
ON exponent.cagg_vault_yield_position_5s(vault, bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_vault_yield_position_5s_pending_yield 
ON exponent.cagg_vault_yield_position_5s(bucket DESC) 
WHERE c_has_pending_yield = TRUE;

-- Comment on the materialized view
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'cagg_vault_yield_position_5s' AND relkind = 'm') THEN
        EXECUTE 'COMMENT ON MATERIALIZED VIEW exponent.cagg_vault_yield_position_5s IS ''5-second continuous aggregate of YieldTokenPosition accounts - tracks vault robot YT positions and accrued yield. Refresh manually via cron.''';
    END IF;
END $$;

-- NOTE: No automatic refresh policy - refresh externally via cron job:
-- CALL refresh_continuous_aggregate('exponent.cagg_vault_yield_position_5s', NULL, NULL);

