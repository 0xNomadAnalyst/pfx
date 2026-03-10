-- Exponent Vaults Continuous Aggregate (5-second buckets)
--
-- Aggregates vault state snapshots into 5-second intervals for efficient querying.
-- Uses LAST() since vault data is point-in-time state (not cumulative).
--
-- REFRESH: Manual via external cron job (no automatic policy)

-- Drop existing continuous aggregate if re-deploying
DROP MATERIALIZED VIEW IF EXISTS exponent.cagg_vaults_5s CASCADE;

CREATE MATERIALIZED VIEW exponent.cagg_vaults_5s
WITH (timescaledb.continuous) AS
SELECT
    -- Time bucket (5-second intervals on block_time)
    time_bucket('5 seconds'::interval, block_time) AS bucket,

    -- Vault identification
    vault_address,

    -- Use LAST() to get most recent state within each 5s window
    -- Metadata
    LAST(slot, block_time) AS slot,
    LAST(time, block_time) AS time,
    LAST(sy_program, block_time) AS sy_program,

    -- Token mints
    LAST(mint_sy, block_time) AS mint_sy,
    LAST(mint_pt, block_time) AS mint_pt,
    LAST(mint_yt, block_time) AS mint_yt,

    -- PDA addresses associated with the vault
    LAST(yield_position, block_time) AS yield_position,
    LAST(escrow_yt, block_time) AS escrow_yt,
    LAST(escrow_sy, block_time) AS escrow_sy,

    -- Token metadata (from environment/config)
    LAST(env_sy_symbol, block_time) AS env_sy_symbol,
    LAST(env_sy_decimals, block_time) AS env_sy_decimals,
    LAST(env_sy_type, block_time) AS env_sy_type,
    LAST(env_sy_lifetime_apy_start_date, block_time) AS env_sy_lifetime_apy_start_date,
    LAST(env_sy_lifetime_apy_start_index, block_time) AS env_sy_lifetime_apy_start_index,

    -- Token metadata (from on-chain discovery)
    LAST(meta_sy_symbol, block_time) AS meta_sy_symbol,
    LAST(meta_sy_name, block_time) AS meta_sy_name,
    LAST(meta_sy_decimals, block_time) AS meta_sy_decimals,
    LAST(meta_pt_symbol, block_time) AS meta_pt_symbol,
    LAST(meta_pt_name, block_time) AS meta_pt_name,
    LAST(meta_pt_decimals, block_time) AS meta_pt_decimals,
    LAST(meta_yt_symbol, block_time) AS meta_yt_symbol,
    LAST(meta_yt_name, block_time) AS meta_yt_name,
    LAST(meta_yt_decimals, block_time) AS meta_yt_decimals,
    LAST(meta_base_mint, block_time) AS meta_base_mint,

    -- Maturity schedule
    LAST(start_ts, block_time) AS start_ts,
    LAST(duration, block_time) AS duration,
    LAST(maturity_ts, block_time) AS maturity_ts,

    -- Exchange rates (yield accrual tracking)
    LAST(last_seen_sy_exchange_rate, block_time) AS last_seen_sy_exchange_rate,
    LAST(all_time_high_sy_exchange_rate, block_time) AS all_time_high_sy_exchange_rate,
    LAST(final_sy_exchange_rate, block_time) AS final_sy_exchange_rate,

    -- Collateral and supply (base units)
    LAST(total_sy_in_escrow, block_time) AS total_sy_in_escrow,
    LAST(sy_for_pt, block_time) AS sy_for_pt,
    LAST(pt_supply, block_time) AS pt_supply,

    -- Collateral and supply (decimal-adjusted for UI)
    LAST(total_sy_in_escrow, block_time)::DOUBLE PRECISION / (10^LAST(env_sy_decimals, block_time)) AS total_sy_in_escrow_ui,
    LAST(sy_for_pt, block_time)::DOUBLE PRECISION / (10^LAST(env_sy_decimals, block_time)) AS sy_for_pt_ui,
    LAST(pt_supply, block_time)::DOUBLE PRECISION / (10^LAST(env_sy_decimals, block_time)) AS pt_supply_ui,

    -- Note: pt_supply_ui_delta_pos/neg calculated in view function (requires LAG across buckets)

    -- Treasury and fees (base units)
    LAST(treasury_sy, block_time) AS treasury_sy,
    LAST(uncollected_sy, block_time) AS uncollected_sy,

    -- Treasury and fees (decimal-adjusted for UI)
    LAST(treasury_sy, block_time)::DOUBLE PRECISION / (10^LAST(env_sy_decimals, block_time)) AS treasury_sy_ui,
    LAST(uncollected_sy, block_time)::DOUBLE PRECISION / (10^LAST(env_sy_decimals, block_time)) AS uncollected_sy_ui,

    LAST(interest_bps_fee, block_time) AS interest_bps_fee,

    -- Vault state
    LAST(status, block_time) AS status,
    LAST(max_py_supply, block_time) AS max_py_supply,

    -- Operational constraints
    LAST(min_op_size_strip, block_time) AS min_op_size_strip,
    LAST(min_op_size_merge, block_time) AS min_op_size_merge,

    -- Calculated metrics: Collateral & Liquidity Risk
    LAST(c_collateralization_ratio, block_time) AS c_collateralization_ratio,
    LAST(c_uncollected_yield_ratio, block_time) AS c_uncollected_yield_ratio,
    LAST(c_treasury_ratio, block_time) AS c_treasury_ratio,
    LAST(c_available_liquidity, block_time) AS c_available_liquidity,

    -- Calculated metrics: Maturity & Duration Risk
    LAST(c_time_to_maturity_days, block_time) AS c_time_to_maturity_days,
    LAST(c_days_active, block_time) AS c_days_active,
    LAST(c_is_expired, block_time) AS c_is_expired,
    LAST(c_utilization_ratio, block_time) AS c_utilization_ratio,
    LAST(c_maturity_completion_ratio, block_time) AS c_maturity_completion_ratio,

    -- Calculated metrics: Yield Accrual & Exchange Rate Risk
    LAST(c_yield_index_health, block_time) AS c_yield_index_health,
    LAST(c_yield_growth_rate, block_time) AS c_yield_growth_rate,

    -- Calculated metrics: Yield Dynamics (more dynamic than sy_claims_*_pct)
    -- These metrics show meaningful change over time even with low underlying yields

    -- c_yield_pool_pct: Total yield pool as % of total_sy_in_escrow
    -- Shows ALL yield (collected + uncollected + unaccounted) relative to total locked SY
    -- Grows from ~0% at vault start toward (rate-1)/rate as yield accrues
    CASE
        WHEN LAST(total_sy_in_escrow, block_time) > 0
        THEN ((LAST(total_sy_in_escrow, block_time) - LAST(sy_for_pt, block_time))::DOUBLE PRECISION /
              LAST(total_sy_in_escrow, block_time) * 100)
        ELSE 0
    END AS c_yield_pool_pct,

    -- c_yield_utilization_pct: % of yield pool that's been "recognized" in uncollected_sy
    -- Shows how much of accrued yield has been formally assigned to YT holders
    -- Fluctuates as YT holders claim yield vs new yield accrues
    CASE
        WHEN (LAST(total_sy_in_escrow, block_time) - LAST(sy_for_pt, block_time)) > 0
        THEN (LAST(uncollected_sy, block_time)::DOUBLE PRECISION /
              (LAST(total_sy_in_escrow, block_time) - LAST(sy_for_pt, block_time)) * 100)
        ELSE 0
    END AS c_yield_utilization_pct,

    -- c_cumulative_yield_pct: Exchange rate growth since 1.0 (primary yield driver)
    -- Shows total yield accumulated by the underlying SY token
    -- Grows steadily based on underlying protocol yield
    ((LAST(last_seen_sy_exchange_rate, block_time) - 1) * 100)::DOUBLE PRECISION AS c_cumulative_yield_pct,

    -- c_collateral_buffer_pct: Excess SY per PT (yield cushion for PT holders)
    -- Shows how much extra SY exists beyond sy_for_pt per unit of PT
    -- Grows with yield accrual, represents PT holder safety margin
    CASE
        WHEN LAST(pt_supply, block_time) > 0
        THEN ((LAST(total_sy_in_escrow, block_time) - LAST(sy_for_pt, block_time))::DOUBLE PRECISION /
              LAST(pt_supply, block_time) * 100)
        ELSE 0
    END AS c_collateral_buffer_pct,

    -- Extrapolated starting index at vault start (Oct 24)
    -- Uses MIN(last_seen_sy_exchange_rate) as the earliest observation
    -- Then extrapolates backwards to vault start using config baseline growth rate
    CASE
        WHEN COUNT(*) > 0
             AND MIN(last_seen_sy_exchange_rate) > 0
             AND LAST(env_sy_lifetime_apy_start_index, block_time) IS NOT NULL
             AND LAST(env_sy_lifetime_apy_start_index, block_time) > 0
             AND LAST(env_sy_lifetime_apy_start_date, block_time) IS NOT NULL
             AND LAST(start_ts, block_time) IS NOT NULL
             AND MIN(block_time) > to_timestamp(LAST(start_ts, block_time))
        THEN
            -- Extrapolate: first_obs_rate / (growth_factor ^ gap_fraction)
            MIN(last_seen_sy_exchange_rate) / POWER(
                MIN(last_seen_sy_exchange_rate) / LAST(env_sy_lifetime_apy_start_index, block_time),
                EXTRACT(EPOCH FROM (MIN(block_time) - to_timestamp(LAST(start_ts, block_time)))) /
                NULLIF(EXTRACT(EPOCH FROM (MIN(block_time) - LAST(env_sy_lifetime_apy_start_date, block_time)::TIMESTAMPTZ)), 0)
            )
        ELSE NULL
    END AS c_extrapolated_start_index,

    -- Data source tracking
    LAST(data_source, block_time) AS data_source

FROM exponent.src_vaults
GROUP BY bucket, vault_address
ORDER BY bucket DESC, vault_address;

-- Create indexes on the continuous aggregate for efficient querying
CREATE INDEX IF NOT EXISTS idx_cagg_vaults_5s_vault
ON exponent.cagg_vaults_5s(vault_address, bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_vaults_5s_maturity
ON exponent.cagg_vaults_5s(maturity_ts, bucket DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_vaults_5s_expired
ON exponent.cagg_vaults_5s(c_is_expired, bucket DESC)
WHERE c_is_expired = FALSE;

CREATE INDEX IF NOT EXISTS idx_cagg_vaults_5s_mint_sy
ON exponent.cagg_vaults_5s(mint_sy, bucket DESC);

-- Comment on the materialized view (will be added if view exists)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'cagg_vaults_5s' AND relkind = 'm') THEN
        EXECUTE 'COMMENT ON MATERIALIZED VIEW exponent.cagg_vaults_5s IS ''5-second continuous aggregate of vault state - use for efficient time-series queries. Refresh manually via cron.''';
    END IF;
END $$;

-- NOTE: No automatic refresh policy - refresh externally via cron job:
-- CALL refresh_continuous_aggregate('exponent.cagg_vaults_5s', NULL, NULL);


