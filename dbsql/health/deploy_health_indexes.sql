-- =============================================================================
-- deploy_health_indexes.sql
-- Indexes that support the health monitoring views/functions.
--
-- All use IF NOT EXISTS so this script is safe to re-run.
-- Designed for TimescaleDB hypertables — each index is created per-chunk.
--
-- Run with:  psql -f deploy_health_indexes.sql
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. QUEUE HEALTH tables
--    Health queries do:
--      - PERCENTILE_CONT ... GROUP BY queue_name WHERE time > NOW() - '7 days'
--      - queue_health_current: DISTINCT ON (queue_name) ORDER BY time DESC
--    Needed: (queue_name, time DESC) on ALL schemas
-- ─────────────────────────────────────────────────────────────────────────────

-- dexes (already has idx_queue_health_queue_time — included for completeness)
CREATE INDEX IF NOT EXISTS idx_queue_health_queue_time
    ON dexes.queue_health (queue_name, time DESC);

-- exponent
CREATE INDEX IF NOT EXISTS idx_queue_health_queue_name_time
    ON exponent.queue_health (queue_name, time DESC);

-- kamino_lend
CREATE INDEX IF NOT EXISTS idx_queue_health_queue_name_time
    ON kamino_lend.queue_health (queue_name, time DESC);


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. TRIGGER TABLE support
--    Single-scan query filters: event_type = 'swap' AND time > ... with
--    additional FILTER on protocol = 'raydium'.
--    The existing (event_type, time DESC) index handles this well.
--    Add a composite for the protocol + event_type pattern.
-- ─────────────────────────────────────────────────────────────────────────────

-- Composite for trigger checks: WHERE event_type = 'swap' AND protocol = 'raydium'
CREATE INDEX IF NOT EXISTS idx_src_tx_events_swap_protocol
    ON dexes.src_tx_events (event_type, protocol, time DESC)
    WHERE event_type = 'swap';


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. BASE TABLE health queries
--    Pattern: WHERE time > NOW() - '7 days' (or '1 hour', '24 hours')
--    For tables where the hypertable dimension IS time: chunk exclusion
--    handles this automatically. For tables where dimension is block_time
--    but queries filter on time: need a (time DESC) index.
--
--    Most already exist — this section catches any gaps.
-- ─────────────────────────────────────────────────────────────────────────────

-- dexes: time is hypertable dimension for most; these already have time indexes
-- Just ensure src_transactions has a time index
CREATE INDEX IF NOT EXISTS idx_src_transactions_time
    ON dexes.src_transactions (time DESC);

-- exponent: src_vaults and src_market_twos have block_time as dimension
-- but health queries use 'time' — indexes already exist from DDL:
--   idx_vaults_time ON (time DESC)
--   idx_markets_time ON (time DESC)
-- Re-declare for safety (IF NOT EXISTS)
CREATE INDEX IF NOT EXISTS idx_vaults_time
    ON exponent.src_vaults (time DESC);
CREATE INDEX IF NOT EXISTS idx_markets_time
    ON exponent.src_market_twos (time DESC);

-- exponent txns
CREATE INDEX IF NOT EXISTS idx_exponent_txns_time
    ON exponent.src_txns (time DESC);

-- kamino_lend
CREATE INDEX IF NOT EXISTS idx_kamino_events_time
    ON kamino_lend.src_txn_events (time DESC);
CREATE INDEX IF NOT EXISTS idx_kamino_txn_time
    ON kamino_lend.src_txn (time DESC);
CREATE INDEX IF NOT EXISTS idx_src_reserves_time
    ON kamino_lend.src_reserves (time DESC);
CREATE INDEX IF NOT EXISTS idx_obligations_block_time
    ON kamino_lend.src_obligations (block_time DESC);
CREATE INDEX IF NOT EXISTS idx_obligations_agg_time
    ON kamino_lend.src_obligations_agg (time DESC);
CREATE INDEX IF NOT EXISTS idx_src_lending_market_time
    ON kamino_lend.src_lending_market (time DESC);


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. CAGG TABLE MAX() support
--    MAX(bucket) / MAX(bucket_time) on CAGG materialized views.
--    TimescaleDB CAGGs automatically have the bucket column as the
--    hypertable dimension, so MAX is fast via last-chunk lookup.
--    No additional indexes needed here.
-- ─────────────────────────────────────────────────────────────────────────────

-- (No action required — documented for completeness)


-- ─────────────────────────────────────────────────────────────────────────────
-- VERIFICATION: list all health-relevant indexes
-- Uncomment to run after deployment:
-- ─────────────────────────────────────────────────────────────────────────────
/*
SELECT
    schemaname,
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE (
    (schemaname = 'dexes'                AND tablename IN ('queue_health', 'src_tx_events', 'src_acct_pool', 'src_acct_vaults', 'src_acct_tickarray_queries', 'src_acct_position', 'src_transactions'))
    OR (schemaname = 'exponent'          AND tablename IN ('queue_health', 'src_tx_events', 'src_txns', 'src_vaults', 'src_market_twos', 'src_sy_meta_account', 'src_sy_token_account', 'src_vault_yield_position', 'src_vault_yt_escrow', 'src_base_token_escrow'))
    OR (schemaname = 'kamino_lend'       AND tablename IN ('queue_health', 'src_txn_events', 'src_txn', 'src_reserves', 'src_obligations', 'src_obligations_agg', 'src_lending_market'))
)
ORDER BY schemaname, tablename, indexname;
*/
