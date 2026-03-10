-- Exponent SY Account (SyMeta) Continuous Aggregate (5-second buckets)
-- 
-- Aggregates SyMeta state snapshots into 5-second intervals for efficient querying.
-- Uses LAST() since SyMeta data is point-in-time state (not cumulative).
--
-- REFRESH: Manual via external cron job (no automatic policy)

-- Drop existing continuous aggregate if re-deploying
DROP MATERIALIZED VIEW IF EXISTS exponent.cagg_sy_meta_account_5s CASCADE;

CREATE MATERIALIZED VIEW exponent.cagg_sy_meta_account_5s
WITH (timescaledb.continuous) AS
SELECT
    -- Time bucket (5-second intervals on time - the hypertable dimension)
    time_bucket('5 seconds'::interval, time) AS bucket,
    
    -- SyMeta identification
    sy_meta_address,
    
    -- Use LAST() to get most recent state within each 5s window
    -- Metadata
    LAST(slot, time) AS slot,
    LAST(block_time, time) AS block_time,
    LAST(mint_sy, time) AS mint_sy,
    LAST(token_sy_escrow, time) AS token_sy_escrow,
    
    -- SY Configuration
    LAST(max_sy_supply, time) AS max_sy_supply,
    LAST(min_mint_size, time) AS min_mint_size,
    LAST(min_redeem_size, time) AS min_redeem_size,
    LAST(self_address_bump, time) AS self_address_bump,
    
    -- Exchange Rate (KEY FIELD - for time-series analysis)
    LAST(sy_exchange_rate, time) AS sy_exchange_rate,
    
    -- Underlying Protocol
    LAST(yield_bearing_mint, time) AS yield_bearing_mint,
    LAST(interface_type, time) AS interface_type,
    
    -- Hook Configuration
    LAST(hook_enabled, time) AS hook_enabled,
    LAST(hook_program_id, time) AS hook_program_id,
    
    -- Interface Accounts
    LAST(interface_accounts_count, time) AS interface_accounts_count,
    
    -- Emissions Tracking
    LAST(emissions_count, time) AS emissions_count,
    
    -- Calculated Metrics (Emissions)
    LAST(c_total_accrued_emissions, time) AS c_total_accrued_emissions,
    LAST(c_total_claimed_emissions, time) AS c_total_claimed_emissions,
    LAST(c_total_treasury_emissions, time) AS c_total_treasury_emissions,
    LAST(c_unclaimed_emissions, time) AS c_unclaimed_emissions,
    LAST(c_utilization_pct, time) AS c_utilization_pct,
    
    -- Trailing APY calculations using time buckets
    -- Note: These are approximations based on bucketed data
    -- For precise calculations, use views that query raw src_sy_meta_account
    
    -- Store exchange rates at different time offsets for APY calculation
    -- These will be used by views to calculate trailing APYs
    FIRST(sy_exchange_rate, time) AS sy_exchange_rate_first_in_bucket,
    LAST(sy_exchange_rate, time) AS sy_exchange_rate_last_in_bucket,
    
    -- Lifetime APY: From config baseline to current
    -- Uses env_sy_lifetime_apy_start_date and env_sy_lifetime_apy_start_index
    LAST(
        CASE
            WHEN sy_exchange_rate > 0
                 AND env_sy_lifetime_apy_start_date IS NOT NULL
                 AND env_sy_lifetime_apy_start_index IS NOT NULL
                 AND env_sy_lifetime_apy_start_index > 0
                 AND time >= env_sy_lifetime_apy_start_date::TIMESTAMPTZ
            THEN (
                (sy_exchange_rate / env_sy_lifetime_apy_start_index - 1.0) * (
                    31536000.0 / GREATEST(
                        EXTRACT(EPOCH FROM (time - env_sy_lifetime_apy_start_date::TIMESTAMPTZ)),
                        3600.0
                    )
                )
            )
            ELSE NULL
        END,
        time
    ) AS c_apy_lifetime,
    
    -- Pass through config values for reference
    LAST(env_sy_lifetime_apy_start_date, time) AS env_sy_lifetime_apy_start_date,
    LAST(env_sy_lifetime_apy_start_index, time) AS env_sy_lifetime_apy_start_index,
    
    -- Token metadata (from on-chain discovery)
    LAST(meta_sy_symbol, time) AS meta_sy_symbol,
    LAST(meta_sy_name, time) AS meta_sy_name,
    LAST(meta_sy_decimals, time) AS meta_sy_decimals,
    LAST(meta_base_symbol, time) AS meta_base_symbol,
    LAST(meta_base_name, time) AS meta_base_name,
    LAST(meta_base_decimals, time) AS meta_base_decimals,
    LAST(meta_base_mint, time) AS meta_base_mint,
    
    -- Data source tracking
    LAST(data_source, time) AS data_source

FROM exponent.src_sy_meta_account
GROUP BY bucket, sy_meta_address
ORDER BY bucket DESC, sy_meta_address;

-- Create indexes on the continuous aggregate for efficient querying
CREATE INDEX IF NOT EXISTS idx_cagg_sy_meta_account_5s_address 
ON exponent.cagg_sy_meta_account_5s(sy_meta_address, bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_sy_meta_account_5s_mint 
ON exponent.cagg_sy_meta_account_5s(mint_sy, bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_sy_meta_account_5s_interface 
ON exponent.cagg_sy_meta_account_5s(interface_type, bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_sy_meta_account_5s_exchange_rate 
ON exponent.cagg_sy_meta_account_5s(bucket DESC, sy_exchange_rate);

-- Comment on the materialized view (will be added if view exists)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'cagg_sy_meta_account_5s' AND relkind = 'm') THEN
        EXECUTE 'COMMENT ON MATERIALIZED VIEW exponent.cagg_sy_meta_account_5s IS ''5-second continuous aggregate of SyMeta state - SY exchange rates and protocol metadata. Refresh manually via cron.''';
    END IF;
END $$;

-- NOTE: No automatic refresh policy - refresh externally via cron job:
-- CALL refresh_continuous_aggregate('exponent.cagg_sy_meta_account_5s', NULL, NULL);

