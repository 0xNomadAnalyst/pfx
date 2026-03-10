-- =============================================================================
-- 03_mat_columnstore.sql
-- Enable columnstore on materialized intermediate tables (mat_*).
--
-- These tables are refreshed every 30s by onyc_refresh.sh. Only chunks older
-- than 1 day are converted (the active chunk stays in rowstore for fast
-- upserts during refresh cycles).
--
-- Mat tables with 7-day chunk intervals will see conversion after the first
-- chunk rolls over. Until then, data stays in the rowstore which is fine —
-- the mat tables are small and the rowstore handles the refresh upsert pattern.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- DEXES mat tables
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE dexes.mat_dex_timeseries_1m SET (
    timescaledb.orderby = 'bucket_time DESC',
    timescaledb.segmentby = 'pool_address'
);
SELECT add_compression_policy('dexes.mat_dex_timeseries_1m',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

ALTER TABLE dexes.mat_dex_ohlcv_1m SET (
    timescaledb.orderby = 'bucket_time DESC',
    timescaledb.segmentby = 'pool_address'
);
SELECT add_compression_policy('dexes.mat_dex_ohlcv_1m',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

-- ─────────────────────────────────────────────────────────────────────────────
-- KAMINO_LEND mat tables
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE kamino_lend.mat_klend_reserve_ts_1m SET (
    timescaledb.orderby = 'bucket_time DESC',
    timescaledb.segmentby = 'reserve_address'
);
SELECT add_compression_policy('kamino_lend.mat_klend_reserve_ts_1m',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

ALTER TABLE kamino_lend.mat_klend_obligation_ts_1m SET (
    timescaledb.orderby = 'bucket_time DESC',
    timescaledb.segmentby = 'market_address'
);
SELECT add_compression_policy('kamino_lend.mat_klend_obligation_ts_1m',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

ALTER TABLE kamino_lend.mat_klend_activity_ts_1m SET (
    timescaledb.orderby = 'bucket_time DESC',
    timescaledb.segmentby = 'symbol'
);
SELECT add_compression_policy('kamino_lend.mat_klend_activity_ts_1m',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

-- ─────────────────────────────────────────────────────────────────────────────
-- EXPONENT mat tables
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE exponent.mat_exp_timeseries_1m SET (
    timescaledb.orderby = 'bucket_time DESC',
    timescaledb.segmentby = 'vault_address'
);
SELECT add_compression_policy('exponent.mat_exp_timeseries_1m',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

-- ─────────────────────────────────────────────────────────────────────────────
-- HEALTH mat tables
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE health.mat_health_base_hourly SET (
    timescaledb.orderby = 'hour DESC',
    timescaledb.segmentby = 'schema_name'
);
SELECT add_compression_policy('health.mat_health_base_hourly',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

-- ─────────────────────────────────────────────────────────────────────────────
-- CROSS_PROTOCOL mat tables
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE cross_protocol.mat_xp_ts_1m SET (
    timescaledb.orderby = 'bucket_time DESC'
);
SELECT add_compression_policy('cross_protocol.mat_xp_ts_1m',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);
