-- =============================================================================
-- 05_retention_policies.sql
-- Automated data retention: drop chunks older than the retention window.
--
-- Retention tiers:
--   Source tables:    180 days  (raw ingestion data; oldest is tiered to S3)
--   CAGGs:           180 days  (aggregated data; oldest is tiered)
--   Mat tables:       90 days  (managed by onyc_refresh.sh DELETE, but add
--                               policy as safety net)
--   Queue health:     90 days  (operational monitoring data)
--
-- Note: src_obligations and src_acct_tickarray_tokendist use integer-based
-- partitioning (query_id), not time. They need integer-based retention or
-- manual cleanup — excluded from time-based policies here.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- SOURCE TABLES — 180 days
-- ─────────────────────────────────────────────────────────────────────────────

-- Dexes
SELECT add_retention_policy('dexes.src_acct_vaults',              drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('dexes.src_acct_pool',                drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('dexes.src_acct_position',            drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('dexes.src_acct_ammconfig',           drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('dexes.src_transactions',             drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('dexes.src_tx_events',                drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('dexes.src_acct_tickarray_queries',   drop_after => INTERVAL '180 days', if_not_exists => true);

-- Exponent
SELECT add_retention_policy('exponent.src_vaults',                drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('exponent.src_market_twos',           drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('exponent.src_base_token_escrow',     drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('exponent.src_sy_meta_account',       drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('exponent.src_sy_token_account',      drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('exponent.src_vault_yt_escrow',       drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('exponent.src_vault_yield_position',  drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('exponent.src_tx_events',             drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('exponent.src_txns',                  drop_after => INTERVAL '180 days', if_not_exists => true);

-- Kamino
SELECT add_retention_policy('kamino_lend.src_reserves',           drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('kamino_lend.src_obligations_agg',    drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('kamino_lend.src_txn',                drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('kamino_lend.src_txn_events',         drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('kamino_lend.src_lending_market',     drop_after => INTERVAL '180 days', if_not_exists => true);

-- ─────────────────────────────────────────────────────────────────────────────
-- CAGGs — 180 days
-- ─────────────────────────────────────────────────────────────────────────────

SELECT add_retention_policy('dexes.cagg_vaults_5s',               drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('dexes.cagg_events_5s',               drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('dexes.cagg_poolstate_5s',            drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('dexes.cagg_tickarrays_5s',           drop_after => INTERVAL '180 days', if_not_exists => true);

SELECT add_retention_policy('exponent.cagg_vaults_5s',              drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('exponent.cagg_market_twos_5s',         drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('exponent.cagg_tx_events_5s',           drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('exponent.cagg_sy_meta_account_5s',     drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('exponent.cagg_sy_token_account_5s',    drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('exponent.cagg_vault_yt_escrow_5s',     drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('exponent.cagg_vault_yield_position_5s', drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('exponent.cagg_base_token_escrow_5s',   drop_after => INTERVAL '180 days', if_not_exists => true);

SELECT add_retention_policy('kamino_lend.cagg_reserves_5s',         drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('kamino_lend.cagg_obligations_agg_5s',  drop_after => INTERVAL '180 days', if_not_exists => true);
SELECT add_retention_policy('kamino_lend.cagg_activities_5s',       drop_after => INTERVAL '180 days', if_not_exists => true);

-- ─────────────────────────────────────────────────────────────────────────────
-- QUEUE HEALTH — 90 days
-- ─────────────────────────────────────────────────────────────────────────────

SELECT add_retention_policy('dexes.queue_health',                 drop_after => INTERVAL '90 days', if_not_exists => true);
SELECT add_retention_policy('exponent.queue_health',              drop_after => INTERVAL '90 days', if_not_exists => true);
SELECT add_retention_policy('kamino_lend.queue_health',           drop_after => INTERVAL '90 days', if_not_exists => true);

-- ─────────────────────────────────────────────────────────────────────────────
-- MAT TABLES — 90 days (safety net; primary cleanup is in onyc_refresh.sh)
-- ─────────────────────────────────────────────────────────────────────────────

SELECT add_retention_policy('dexes.mat_dex_timeseries_1m',           drop_after => INTERVAL '90 days', if_not_exists => true);
SELECT add_retention_policy('dexes.mat_dex_ohlcv_1m',               drop_after => INTERVAL '90 days', if_not_exists => true);
SELECT add_retention_policy('kamino_lend.mat_klend_reserve_ts_1m',   drop_after => INTERVAL '90 days', if_not_exists => true);
SELECT add_retention_policy('kamino_lend.mat_klend_obligation_ts_1m', drop_after => INTERVAL '90 days', if_not_exists => true);
SELECT add_retention_policy('kamino_lend.mat_klend_activity_ts_1m',  drop_after => INTERVAL '90 days', if_not_exists => true);
SELECT add_retention_policy('exponent.mat_exp_timeseries_1m',        drop_after => INTERVAL '90 days', if_not_exists => true);
SELECT add_retention_policy('health.mat_health_base_hourly',         drop_after => INTERVAL '90 days', if_not_exists => true);
SELECT add_retention_policy('cross_protocol.mat_xp_ts_1m',          drop_after => INTERVAL '90 days', if_not_exists => true);
