-- Exponent Vault YT Escrow Continuous Aggregate (5-second buckets)
-- 
-- Aggregates vault YT escrow SPL Token Account snapshots into 5-second intervals.
-- Tracks the vault-owned SPL Token Account that holds YT tokens for user deposits.
-- Uses LAST() since escrow data is point-in-time state (not cumulative).
--
-- REFRESH: Manual via external cron job (no automatic policy)

-- Drop existing continuous aggregate if re-deploying
DROP MATERIALIZED VIEW IF EXISTS exponent.cagg_vault_yt_escrow_5s CASCADE;

CREATE MATERIALIZED VIEW exponent.cagg_vault_yt_escrow_5s
WITH (timescaledb.continuous) AS
SELECT
    -- Time bucket (5-second intervals on time - the hypertable dimension)
    time_bucket('5 seconds'::interval, time) AS bucket,
    
    -- Escrow identification
    escrow_yt_address,
    
    -- Use LAST() to get most recent state within each 5s window
    -- Metadata
    LAST(slot, time) AS slot,
    LAST(block_time, time) AS block_time,
    LAST(mint, time) AS mint,
    LAST(owner, time) AS owner,
    LAST(vault, time) AS vault,
    
    -- Token Account State
    LAST(amount, time) AS amount,
    LAST(is_initialized, time) AS is_initialized,
    
    -- Token metadata (from on-chain discovery)
    LAST(meta_yt_symbol, time) AS meta_yt_symbol,
    LAST(meta_yt_name, time) AS meta_yt_name,
    LAST(meta_yt_decimals, time) AS meta_yt_decimals,
    LAST(meta_base_mint, time) AS meta_base_mint,
    
    -- Data source tracking
    LAST(data_source, time) AS data_source

FROM exponent.src_vault_yt_escrow
GROUP BY bucket, escrow_yt_address
ORDER BY bucket DESC, escrow_yt_address;

-- Create indexes on the continuous aggregate for efficient querying
CREATE INDEX IF NOT EXISTS idx_cagg_vault_yt_escrow_5s_address 
ON exponent.cagg_vault_yt_escrow_5s(escrow_yt_address, bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_vault_yt_escrow_5s_vault 
ON exponent.cagg_vault_yt_escrow_5s(vault, bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_vault_yt_escrow_5s_mint 
ON exponent.cagg_vault_yt_escrow_5s(mint, bucket DESC);

-- Comment on the materialized view
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'cagg_vault_yt_escrow_5s' AND relkind = 'm') THEN
        EXECUTE 'COMMENT ON MATERIALIZED VIEW exponent.cagg_vault_yt_escrow_5s IS ''5-second continuous aggregate of vault YT escrow SPL Token Account - holds YT tokens deposited by users. Refresh manually via cron.''';
    END IF;
END $$;

-- NOTE: No automatic refresh policy - refresh externally via cron job:
-- CALL refresh_continuous_aggregate('exponent.cagg_vault_yt_escrow_5s', NULL, NULL);

