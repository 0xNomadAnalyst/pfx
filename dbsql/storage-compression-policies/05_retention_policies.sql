-- =============================================================================
-- 05_retention_policies.sql
-- Automated data retention: drop chunks older than the retention window.
--
-- Retention tiers:
--   Source tables:   NONE — deferred until a long-term warehousing solution
--                    is decided. Compression + tiered storage keeps disk
--                    manageable in the interim.
--   CAGGs:           90 days (matches the longest dashboard lookback)
--   Mat tables:      90 days (managed by onyc_refresh.sh DELETE, but add
--                             policy as safety net)
--   Queue health:    90 days (operational monitoring data)
--
-- Note: src_obligations and src_acct_tickarray_tokendist use integer-based
-- partitioning (query_id), not time. They need integer-based retention or
-- manual cleanup — excluded from time-based policies here.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- CAGGs — 90 days (longest dashboard view)
-- ─────────────────────────────────────────────────────────────────────────────

-- Dexes
SELECT add_retention_policy('dexes.cagg_vaults_5s',               drop_after => INTERVAL '90 days', if_not_exists => true);
SELECT add_retention_policy('dexes.cagg_events_5s',               drop_after => INTERVAL '90 days', if_not_exists => true);
SELECT add_retention_policy('dexes.cagg_poolstate_5s',            drop_after => INTERVAL '90 days', if_not_exists => true);
SELECT add_retention_policy('dexes.cagg_tickarrays_5s',           drop_after => INTERVAL '90 days', if_not_exists => true);

-- Exponent
SELECT add_retention_policy('exponent.cagg_vaults_5s',              drop_after => INTERVAL '90 days', if_not_exists => true);
SELECT add_retention_policy('exponent.cagg_market_twos_5s',         drop_after => INTERVAL '90 days', if_not_exists => true);
SELECT add_retention_policy('exponent.cagg_tx_events_5s',           drop_after => INTERVAL '90 days', if_not_exists => true);
SELECT add_retention_policy('exponent.cagg_sy_meta_account_5s',     drop_after => INTERVAL '90 days', if_not_exists => true);
SELECT add_retention_policy('exponent.cagg_sy_token_account_5s',    drop_after => INTERVAL '90 days', if_not_exists => true);
SELECT add_retention_policy('exponent.cagg_vault_yt_escrow_5s',     drop_after => INTERVAL '90 days', if_not_exists => true);
SELECT add_retention_policy('exponent.cagg_vault_yield_position_5s', drop_after => INTERVAL '90 days', if_not_exists => true);
SELECT add_retention_policy('exponent.cagg_base_token_escrow_5s',   drop_after => INTERVAL '90 days', if_not_exists => true);

-- Kamino
SELECT add_retention_policy('kamino_lend.cagg_reserves_5s',         drop_after => INTERVAL '90 days', if_not_exists => true);
SELECT add_retention_policy('kamino_lend.cagg_obligations_agg_5s',  drop_after => INTERVAL '90 days', if_not_exists => true);
SELECT add_retention_policy('kamino_lend.cagg_activities_5s',       drop_after => INTERVAL '90 days', if_not_exists => true);

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
