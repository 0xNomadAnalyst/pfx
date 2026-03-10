-- ============================================================================
-- MIGRATION: Add Tiered Storage Policies to All Production Hypertables
-- ============================================================================
-- Moves chunks older than the specified interval from high-performance storage
-- to low-cost object storage (S3-backed). Data remains queryable but read-only.
--
-- PREREQUISITE: Tiered storage must be enabled in Tiger Console.
--   (Tiger Console > Service > Explorer > Storage configuration > Enable tiered storage)
--
-- IMPORTANT:
--   - Tiered data is READ-ONLY. Do not tier data that needs active modification.
--   - Tiering operates on whole chunks. Actual tiering happens once ALL data in a
--     chunk is older than move_after. Effective hot window ≈ chunk_interval + move_after.
--   - Policy runs on a schedule (default: every 12h for daily chunks).
--   - This script is idempotent (if_not_exists => true).
--
-- DOES NOT COVER (requires hypertable conversion first):
--   - dexes.src_acct_tickarray_tokendist  (regular table, FK to hypertable)
--   - kamino_lend.src_obligations         (regular table, FK to hypertable)
-- ============================================================================

-- ============================================================================
-- DEXES SCHEMA
-- ============================================================================

SELECT add_tiering_policy('dexes.src_acct_tickarray_queries', INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('dexes.src_acct_position',          INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('dexes.src_tx_events',              INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('dexes.src_transactions',           INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('dexes.src_acct_vaults',            INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('dexes.src_acct_pool',              INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('dexes.queue_health',               INTERVAL '1 day', if_not_exists => true);

-- ============================================================================
-- KAMINO_LEND SCHEMA
-- ============================================================================

SELECT add_tiering_policy('kamino_lend.src_obligations_agg',  INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('kamino_lend.src_lending_market',   INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('kamino_lend.src_txn_events',       INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('kamino_lend.src_txn',              INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('kamino_lend.src_reserves',         INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('kamino_lend.queue_health',         INTERVAL '1 day', if_not_exists => true);

-- ============================================================================
-- SOLSTICE_PROPRIETARY SCHEMA
-- ============================================================================

SELECT add_tiering_policy('solstice_proprietary.src_eusx_controller',       INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('solstice_proprietary.src_usx_tx_events',         INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('solstice_proprietary.src_usx_txns',              INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('solstice_proprietary.src_usx_stabledepository',  INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('solstice_proprietary.src_usx_controller',        INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('solstice_proprietary.src_eusx_yieldpool',        INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('solstice_proprietary.src_eusx_vestingschedule',  INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('solstice_proprietary.src_eusx_tx_events',        INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('solstice_proprietary.queue_health',              INTERVAL '1 day', if_not_exists => true);

-- ============================================================================
-- EXPONENT SCHEMA
-- ============================================================================

SELECT add_tiering_policy('exponent.src_vault_yt_escrow',      INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('exponent.src_vault_yield_position', INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('exponent.src_vaults',               INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('exponent.src_sy_meta_account',      INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('exponent.src_tx_events',            INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('exponent.src_base_token_escrow',    INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('exponent.src_market_twos',          INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('exponent.src_txns',                 INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('exponent.src_sy_token_account',     INTERVAL '1 day', if_not_exists => true);
SELECT add_tiering_policy('exponent.queue_health',             INTERVAL '1 day', if_not_exists => true);

-- ============================================================================
-- VERIFY: List all tiering policies
-- ============================================================================

SELECT
    j.hypertable_schema,
    j.hypertable_name,
    j.schedule_interval,
    config->>'move_after' AS move_after,
    j.next_start
FROM timescaledb_information.jobs j
WHERE j.proc_name = 'policy_tiering'
ORDER BY j.hypertable_schema, j.hypertable_name;

-- ============================================================================
-- MONITOR: Check what has been tiered so far
-- ============================================================================
-- Run after policies have had time to execute:
--   SELECT * FROM timescaledb_osm.tiered_chunks;
--
-- Check what's queued for tiering:
--   SELECT * FROM timescaledb_osm.chunks_queued_for_tiering;
--
-- Check storage breakdown per table:
--   SELECT
--       hypertable_schema || '.' || hypertable_name AS table_name,
--       pg_size_pretty(total_bytes) AS total_size,
--       pg_size_pretty(table_bytes) AS table_size,
--       pg_size_pretty(index_bytes) AS index_size
--   FROM hypertable_detailed_size('schema.table_name');
-- ============================================================================
