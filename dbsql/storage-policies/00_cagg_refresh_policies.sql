-- =============================================================================
-- 00_cagg_refresh_policies.sql
-- Add lightweight CAGG refresh policies as a prerequisite for columnstore.
--
-- TimescaleDB requires a refresh policy to exist before a columnstore policy
-- can be added to a CAGG. Our primary CAGG refresh is handled externally by
-- onyc_refresh.sh, so these internal policies use a long schedule_interval
-- (12 hours) to avoid contention. They serve as a safety net / prerequisite.
--
-- Refresh window: last 30 minutes (matches the cron refresh window).
-- Schedule: every 12 hours (infrequent; external cron is the primary driver).
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- DEXES
-- ─────────────────────────────────────────────────────────────────────────────

SELECT add_continuous_aggregate_policy('dexes.cagg_events_5s',
    start_offset => INTERVAL '30 minutes',
    end_offset   => INTERVAL '1 minute',
    schedule_interval => INTERVAL '12 hours',
    if_not_exists => true);

SELECT add_continuous_aggregate_policy('dexes.cagg_vaults_5s',
    start_offset => INTERVAL '30 minutes',
    end_offset   => INTERVAL '1 minute',
    schedule_interval => INTERVAL '12 hours',
    if_not_exists => true);

SELECT add_continuous_aggregate_policy('dexes.cagg_poolstate_5s',
    start_offset => INTERVAL '30 minutes',
    end_offset   => INTERVAL '1 minute',
    schedule_interval => INTERVAL '12 hours',
    if_not_exists => true);

SELECT add_continuous_aggregate_policy('dexes.cagg_tickarrays_5s',
    start_offset => INTERVAL '30 minutes',
    end_offset   => INTERVAL '1 minute',
    schedule_interval => INTERVAL '12 hours',
    if_not_exists => true);

SELECT add_continuous_aggregate_policy('dexes.queue_health_hourly',
    start_offset => INTERVAL '2 days',
    end_offset   => INTERVAL '1 hour',
    schedule_interval => INTERVAL '12 hours',
    if_not_exists => true);

-- ─────────────────────────────────────────────────────────────────────────────
-- EXPONENT
-- ─────────────────────────────────────────────────────────────────────────────

SELECT add_continuous_aggregate_policy('exponent.cagg_vaults_5s',
    start_offset => INTERVAL '30 minutes',
    end_offset   => INTERVAL '1 minute',
    schedule_interval => INTERVAL '12 hours',
    if_not_exists => true);

SELECT add_continuous_aggregate_policy('exponent.cagg_market_twos_5s',
    start_offset => INTERVAL '30 minutes',
    end_offset   => INTERVAL '1 minute',
    schedule_interval => INTERVAL '12 hours',
    if_not_exists => true);

SELECT add_continuous_aggregate_policy('exponent.cagg_tx_events_5s',
    start_offset => INTERVAL '30 minutes',
    end_offset   => INTERVAL '1 minute',
    schedule_interval => INTERVAL '12 hours',
    if_not_exists => true);

SELECT add_continuous_aggregate_policy('exponent.cagg_sy_meta_account_5s',
    start_offset => INTERVAL '30 minutes',
    end_offset   => INTERVAL '1 minute',
    schedule_interval => INTERVAL '12 hours',
    if_not_exists => true);

SELECT add_continuous_aggregate_policy('exponent.cagg_sy_token_account_5s',
    start_offset => INTERVAL '30 minutes',
    end_offset   => INTERVAL '1 minute',
    schedule_interval => INTERVAL '12 hours',
    if_not_exists => true);

SELECT add_continuous_aggregate_policy('exponent.cagg_vault_yt_escrow_5s',
    start_offset => INTERVAL '30 minutes',
    end_offset   => INTERVAL '1 minute',
    schedule_interval => INTERVAL '12 hours',
    if_not_exists => true);

SELECT add_continuous_aggregate_policy('exponent.cagg_vault_yield_position_5s',
    start_offset => INTERVAL '30 minutes',
    end_offset   => INTERVAL '1 minute',
    schedule_interval => INTERVAL '12 hours',
    if_not_exists => true);

SELECT add_continuous_aggregate_policy('exponent.cagg_base_token_escrow_5s',
    start_offset => INTERVAL '30 minutes',
    end_offset   => INTERVAL '1 minute',
    schedule_interval => INTERVAL '12 hours',
    if_not_exists => true);

SELECT add_continuous_aggregate_policy('exponent.queue_health_hourly',
    start_offset => INTERVAL '2 days',
    end_offset   => INTERVAL '1 hour',
    schedule_interval => INTERVAL '12 hours',
    if_not_exists => true);

-- ─────────────────────────────────────────────────────────────────────────────
-- KAMINO_LEND
-- ─────────────────────────────────────────────────────────────────────────────

SELECT add_continuous_aggregate_policy('kamino_lend.cagg_reserves_5s',
    start_offset => INTERVAL '30 minutes',
    end_offset   => INTERVAL '1 minute',
    schedule_interval => INTERVAL '12 hours',
    if_not_exists => true);

SELECT add_continuous_aggregate_policy('kamino_lend.cagg_obligations_agg_5s',
    start_offset => INTERVAL '30 minutes',
    end_offset   => INTERVAL '1 minute',
    schedule_interval => INTERVAL '12 hours',
    if_not_exists => true);

SELECT add_continuous_aggregate_policy('kamino_lend.cagg_activities_5s',
    start_offset => INTERVAL '30 minutes',
    end_offset   => INTERVAL '1 minute',
    schedule_interval => INTERVAL '12 hours',
    if_not_exists => true);

SELECT add_continuous_aggregate_policy('kamino_lend.queue_health_hourly',
    start_offset => INTERVAL '2 days',
    end_offset   => INTERVAL '1 hour',
    schedule_interval => INTERVAL '12 hours',
    if_not_exists => true);
