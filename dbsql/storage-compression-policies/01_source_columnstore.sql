-- =============================================================================
-- 01_source_columnstore.sql
-- Enable columnstore (compression) on source hypertables that are missing it,
-- and add optimal segmentby/orderby settings for query performance.
--
-- Segmentby strategy: use the primary entity identifier (pool_address,
-- vault_address, market_address, etc.) — these have very low cardinality
-- in ONyc (2-5 distinct values) which gives excellent compression ratios
-- and enables segment-skip pruning on analytical queries.
--
-- Idempotent: uses IF NOT EXISTS where available; safe to re-run.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- DEXES
-- ─────────────────────────────────────────────────────────────────────────────

-- src_acct_vaults: 417 MB, 618 chunks, NO compression. Biggest single win.
ALTER TABLE dexes.src_acct_vaults SET (
    timescaledb.orderby = 'block_time DESC',
    timescaledb.segmentby = 'pool_address'
);
SELECT add_compression_policy('dexes.src_acct_vaults',
    compress_after => INTERVAL '12 hours',
    if_not_exists => true);

-- src_acct_position: 4 MB, no compression
ALTER TABLE dexes.src_acct_position SET (
    timescaledb.orderby = 'time DESC',
    timescaledb.segmentby = 'pool_address'
);
SELECT add_compression_policy('dexes.src_acct_position',
    compress_after => INTERVAL '12 hours',
    if_not_exists => true);

-- src_acct_ammconfig: 1 MB, no compression
ALTER TABLE dexes.src_acct_ammconfig SET (
    timescaledb.orderby = 'time DESC',
    timescaledb.segmentby = 'pool_address'
);
SELECT add_compression_policy('dexes.src_acct_ammconfig',
    compress_after => INTERVAL '12 hours',
    if_not_exists => true);

-- queue_health tables: small but should compress for consistency
ALTER TABLE dexes.queue_health SET (
    timescaledb.orderby = 'time DESC'
);
SELECT add_compression_policy('dexes.queue_health',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

-- ─────────────────────────────────────────────────────────────────────────────
-- EXPONENT
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE exponent.src_vaults SET (
    timescaledb.orderby = 'block_time DESC',
    timescaledb.segmentby = 'vault_address'
);
SELECT add_compression_policy('exponent.src_vaults',
    compress_after => INTERVAL '12 hours',
    if_not_exists => true);

ALTER TABLE exponent.src_market_twos SET (
    timescaledb.orderby = 'block_time DESC',
    timescaledb.segmentby = 'market_address'
);
SELECT add_compression_policy('exponent.src_market_twos',
    compress_after => INTERVAL '12 hours',
    if_not_exists => true);

ALTER TABLE exponent.src_base_token_escrow SET (
    timescaledb.orderby = 'time DESC'
);
SELECT add_compression_policy('exponent.src_base_token_escrow',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

ALTER TABLE exponent.src_sy_meta_account SET (
    timescaledb.orderby = 'time DESC',
    timescaledb.segmentby = 'mint_sy'
);
SELECT add_compression_policy('exponent.src_sy_meta_account',
    compress_after => INTERVAL '12 hours',
    if_not_exists => true);

ALTER TABLE exponent.src_sy_token_account SET (
    timescaledb.orderby = 'time DESC',
    timescaledb.segmentby = 'mint_sy'
);
SELECT add_compression_policy('exponent.src_sy_token_account',
    compress_after => INTERVAL '12 hours',
    if_not_exists => true);

ALTER TABLE exponent.src_vault_yt_escrow SET (
    timescaledb.orderby = 'time DESC',
    timescaledb.segmentby = 'vault'
);
SELECT add_compression_policy('exponent.src_vault_yt_escrow',
    compress_after => INTERVAL '12 hours',
    if_not_exists => true);

ALTER TABLE exponent.src_vault_yield_position SET (
    timescaledb.orderby = 'time DESC',
    timescaledb.segmentby = 'vault'
);
SELECT add_compression_policy('exponent.src_vault_yield_position',
    compress_after => INTERVAL '12 hours',
    if_not_exists => true);

ALTER TABLE exponent.queue_health SET (
    timescaledb.orderby = 'time DESC'
);
SELECT add_compression_policy('exponent.queue_health',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);

-- ─────────────────────────────────────────────────────────────────────────────
-- KAMINO_LEND
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE kamino_lend.src_lending_market SET (
    timescaledb.orderby = 'block_time DESC',
    timescaledb.segmentby = 'market_address'
);
SELECT add_compression_policy('kamino_lend.src_lending_market',
    compress_after => INTERVAL '12 hours',
    if_not_exists => true);

ALTER TABLE kamino_lend.queue_health SET (
    timescaledb.orderby = 'time DESC'
);
SELECT add_compression_policy('kamino_lend.queue_health',
    compress_after => INTERVAL '1 day',
    if_not_exists => true);
