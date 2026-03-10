-- =============================================================================
-- 02_cagg_columnstore.sql
-- Enable columnstore on continuous aggregate materialization hypertables.
--
-- CAGGs are specialized hypertables; compression is set via ALTER MATERIALIZED
-- VIEW, then a columnstore policy auto-converts cooled chunks.
--
-- The biggest target is dexes.cagg_vaults_5s at 328 MB.
-- After columnstore conversion with segmentby on pool_address (only 2 values),
-- expect 90%+ compression → ~30 MB.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- DEXES CAGGs
-- ─────────────────────────────────────────────────────────────────────────────

ALTER MATERIALIZED VIEW dexes.cagg_vaults_5s SET (
    timescaledb.enable_columnstore = true,
    timescaledb.segmentby = 'pool_address',
    timescaledb.orderby = 'bucket_time DESC'
);
SELECT add_compression_policy('dexes.cagg_vaults_5s',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

ALTER MATERIALIZED VIEW dexes.cagg_events_5s SET (
    timescaledb.enable_columnstore = true,
    timescaledb.segmentby = 'pool_address',
    timescaledb.orderby = 'bucket_time DESC'
);
SELECT add_compression_policy('dexes.cagg_events_5s',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

ALTER MATERIALIZED VIEW dexes.cagg_poolstate_5s SET (
    timescaledb.enable_columnstore = true,
    timescaledb.segmentby = 'pool_address',
    timescaledb.orderby = 'bucket_time DESC'
);
SELECT add_compression_policy('dexes.cagg_poolstate_5s',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

ALTER MATERIALIZED VIEW dexes.cagg_tickarrays_5s SET (
    timescaledb.enable_columnstore = true,
    timescaledb.segmentby = 'pool_address',
    timescaledb.orderby = 'bucket DESC'
);
SELECT add_compression_policy('dexes.cagg_tickarrays_5s',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

ALTER MATERIALIZED VIEW dexes.queue_health_hourly SET (
    timescaledb.enable_columnstore = true,
    timescaledb.orderby = 'bucket DESC'
);
SELECT add_compression_policy('dexes.queue_health_hourly',
    compress_after => INTERVAL '7 days',
    if_not_exists => true);

-- ─────────────────────────────────────────────────────────────────────────────
-- EXPONENT CAGGs
-- ─────────────────────────────────────────────────────────────────────────────

ALTER MATERIALIZED VIEW exponent.cagg_vaults_5s SET (
    timescaledb.enable_columnstore = true,
    timescaledb.segmentby = 'vault_address',
    timescaledb.orderby = 'bucket DESC'
);
SELECT add_compression_policy('exponent.cagg_vaults_5s',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

ALTER MATERIALIZED VIEW exponent.cagg_market_twos_5s SET (
    timescaledb.enable_columnstore = true,
    timescaledb.segmentby = 'market_address',
    timescaledb.orderby = 'bucket DESC'
);
SELECT add_compression_policy('exponent.cagg_market_twos_5s',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

ALTER MATERIALIZED VIEW exponent.cagg_tx_events_5s SET (
    timescaledb.enable_columnstore = true,
    timescaledb.segmentby = 'vault_address',
    timescaledb.orderby = 'bucket_time DESC'
);
SELECT add_compression_policy('exponent.cagg_tx_events_5s',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

ALTER MATERIALIZED VIEW exponent.cagg_sy_meta_account_5s SET (
    timescaledb.enable_columnstore = true,
    timescaledb.orderby = 'bucket DESC'
);
SELECT add_compression_policy('exponent.cagg_sy_meta_account_5s',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

ALTER MATERIALIZED VIEW exponent.cagg_sy_token_account_5s SET (
    timescaledb.enable_columnstore = true,
    timescaledb.orderby = 'bucket DESC'
);
SELECT add_compression_policy('exponent.cagg_sy_token_account_5s',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

ALTER MATERIALIZED VIEW exponent.cagg_vault_yt_escrow_5s SET (
    timescaledb.enable_columnstore = true,
    timescaledb.orderby = 'bucket DESC'
);
SELECT add_compression_policy('exponent.cagg_vault_yt_escrow_5s',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

ALTER MATERIALIZED VIEW exponent.cagg_vault_yield_position_5s SET (
    timescaledb.enable_columnstore = true,
    timescaledb.orderby = 'bucket DESC'
);
SELECT add_compression_policy('exponent.cagg_vault_yield_position_5s',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

ALTER MATERIALIZED VIEW exponent.cagg_base_token_escrow_5s SET (
    timescaledb.enable_columnstore = true,
    timescaledb.orderby = 'bucket DESC'
);
SELECT add_compression_policy('exponent.cagg_base_token_escrow_5s',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

ALTER MATERIALIZED VIEW exponent.queue_health_hourly SET (
    timescaledb.enable_columnstore = true,
    timescaledb.orderby = 'bucket DESC'
);
SELECT add_compression_policy('exponent.queue_health_hourly',
    compress_after => INTERVAL '7 days',
    if_not_exists => true);

-- ─────────────────────────────────────────────────────────────────────────────
-- KAMINO_LEND CAGGs
-- ─────────────────────────────────────────────────────────────────────────────

ALTER MATERIALIZED VIEW kamino_lend.cagg_reserves_5s SET (
    timescaledb.enable_columnstore = true,
    timescaledb.segmentby = 'reserve_address',
    timescaledb.orderby = 'bucket DESC'
);
SELECT add_compression_policy('kamino_lend.cagg_reserves_5s',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

ALTER MATERIALIZED VIEW kamino_lend.cagg_obligations_agg_5s SET (
    timescaledb.enable_columnstore = true,
    timescaledb.segmentby = 'market_address',
    timescaledb.orderby = 'bucket DESC'
);
SELECT add_compression_policy('kamino_lend.cagg_obligations_agg_5s',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

ALTER MATERIALIZED VIEW kamino_lend.cagg_activities_5s SET (
    timescaledb.enable_columnstore = true,
    timescaledb.segmentby = 'reserve_address',
    timescaledb.orderby = 'bucket DESC'
);
SELECT add_compression_policy('kamino_lend.cagg_activities_5s',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

ALTER MATERIALIZED VIEW kamino_lend.queue_health_hourly SET (
    timescaledb.enable_columnstore = true,
    timescaledb.orderby = 'bucket DESC'
);
SELECT add_compression_policy('kamino_lend.queue_health_hourly',
    compress_after => INTERVAL '7 days',
    if_not_exists => true);
