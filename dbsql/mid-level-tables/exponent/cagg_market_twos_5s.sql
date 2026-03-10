-- Exponent MarketTwo Continuous Aggregate (5-second buckets)
-- 
-- Aggregates market state snapshots into 5-second intervals for efficient querying.
-- Uses LAST() since market data is point-in-time state (not cumulative).
--
-- REFRESH: Manual via external cron job (no automatic policy)

-- Drop existing continuous aggregate if re-deploying
DROP MATERIALIZED VIEW IF EXISTS exponent.cagg_market_twos_5s CASCADE;

CREATE MATERIALIZED VIEW exponent.cagg_market_twos_5s
WITH (timescaledb.continuous) AS
SELECT
    -- Time bucket (5-second intervals on block_time)
    time_bucket('5 seconds'::interval, block_time) AS bucket,
    
    -- Market identification
    market_address,
    
    -- Use LAST() to get most recent state within each 5s window
    -- Metadata
    LAST(slot, block_time) AS slot,
    LAST(time, block_time) AS time,
    LAST(vault_address, block_time) AS vault_address,
    
    -- Token mints
    LAST(mint_pt, block_time) AS mint_pt,
    LAST(mint_sy, block_time) AS mint_sy,
    LAST(mint_lp, block_time) AS mint_lp,
    
    -- Token metadata (from environment/config)
    LAST(env_sy_symbol, block_time) AS env_sy_symbol,
    LAST(env_sy_decimals, block_time) AS env_sy_decimals,
    LAST(env_sy_type, block_time) AS env_sy_type,
    
    -- Token metadata (from on-chain discovery)
    LAST(meta_pt_symbol, block_time) AS meta_pt_symbol,
    LAST(meta_pt_name, block_time) AS meta_pt_name,
    LAST(meta_pt_decimals, block_time) AS meta_pt_decimals,
    LAST(meta_sy_symbol, block_time) AS meta_sy_symbol,
    LAST(meta_sy_name, block_time) AS meta_sy_name,
    LAST(meta_sy_decimals, block_time) AS meta_sy_decimals,
    LAST(meta_lp_symbol, block_time) AS meta_lp_symbol,
    LAST(meta_lp_name, block_time) AS meta_lp_name,
    LAST(meta_lp_decimals, block_time) AS meta_lp_decimals,
    LAST(meta_base_mint, block_time) AS meta_base_mint,
    
    -- Data source tracking
    LAST(data_source, block_time) AS data_source,
    
    -- AMM reserves (base units)
    LAST(pt_balance, block_time) AS pt_balance,
    LAST(sy_balance, block_time) AS sy_balance,
    
    -- AMM reserves (decimal-adjusted for UI)
    LAST(pt_balance, block_time)::DOUBLE PRECISION / (10^LAST(env_sy_decimals, block_time)) AS pt_balance_ui,
    LAST(sy_balance, block_time)::DOUBLE PRECISION / (10^LAST(env_sy_decimals, block_time)) AS sy_balance_ui,
    LAST(lp_escrow_amount, block_time)::DOUBLE PRECISION / (10^LAST(env_sy_decimals, block_time)) AS lp_escrow_amount_ui,
    
    -- Pricing and yield
    LAST(ln_implied_rate, block_time) AS ln_implied_rate,
    LAST(expiration_ts, block_time) AS expiration_ts,
    
    -- AMM curve parameters
    LAST(ln_fee_rate_root, block_time) AS ln_fee_rate_root,
    LAST(rate_scalar_root, block_time) AS rate_scalar_root,
    
    -- Fees and treasury
    LAST(fee_treasury_sy_bps, block_time) AS fee_treasury_sy_bps,
    
    -- LP tracking
    LAST(lp_escrow_amount, block_time) AS lp_escrow_amount,
    LAST(max_lp_supply, block_time) AS max_lp_supply,
    
    -- Market state
    LAST(status_flags, block_time) AS status_flags,
    
    -- Calculated metrics: Liquidity Depth & Market Health
    LAST(c_total_market_depth_in_sy, block_time) AS c_total_market_depth_in_sy,
    LAST(c_reserve_ratio, block_time) AS c_reserve_ratio,
    LAST(c_reserve_imbalance, block_time) AS c_reserve_imbalance,
    
    -- Legacy alias for pool depth (same as c_total_market_depth_in_sy)
    LAST(c_total_market_depth_in_sy, block_time) AS pool_depth_in_sy,
    
    -- Calculated metrics: Pricing & Yield
    LAST(c_implied_pt_price, block_time) AS c_implied_pt_price,
    LAST(c_implied_yt_price, block_time) AS c_implied_yt_price,
    LAST(c_implied_apy, block_time) AS c_implied_apy,
    LAST(c_time_to_expiry_years, block_time) AS c_time_to_expiry_years,
    LAST(c_time_to_expiry_days, block_time) AS c_time_to_expiry_days,
    LAST(c_discount_rate, block_time) AS c_discount_rate,
    
    -- Calculated metrics: LP Utilization
    LAST(c_lp_utilization, block_time) AS c_lp_utilization

FROM exponent.src_market_twos
GROUP BY bucket, market_address
ORDER BY bucket DESC, market_address;

-- Create indexes on the continuous aggregate for efficient querying
CREATE INDEX IF NOT EXISTS idx_cagg_markets_5s_market 
ON exponent.cagg_market_twos_5s(market_address, bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_markets_5s_vault 
ON exponent.cagg_market_twos_5s(vault_address, bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_markets_5s_expiration 
ON exponent.cagg_market_twos_5s(expiration_ts, bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_markets_5s_mint_sy 
ON exponent.cagg_market_twos_5s(mint_sy, bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_markets_5s_depth 
ON exponent.cagg_market_twos_5s(c_total_market_depth_in_sy, bucket DESC);

-- Comment on the materialized view (will be added if view exists)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'cagg_market_twos_5s' AND relkind = 'm') THEN
        EXECUTE 'COMMENT ON MATERIALIZED VIEW exponent.cagg_market_twos_5s IS ''5-second continuous aggregate of MarketTwo state - use for efficient time-series queries. Refresh manually via cron.''';
    END IF;
END $$;

-- NOTE: No automatic refresh policy - refresh externally via cron job:
-- CALL refresh_continuous_aggregate('exponent.cagg_market_twos_5s', NULL, NULL);
