-- =============================================================================
-- 04_tiered_storage.sql
-- Move older compressed chunks to object storage (S3-compatible tiered storage)
-- to reduce local disk costs while keeping data queryable.
--
-- Tiger Cloud tiering moves chunks from local SSD to object storage.
-- Tiered chunks are still transparently queryable via SQL but at higher
-- latency — appropriate for data outside the frontend's 90-day lookback.
--
-- Prerequisites: columnstore must be enabled on the table (chunks must be
-- compressed before they can be tiered).
--
-- Tiering schedule:
--   Source tables:    tier after 30 days  (ingestion data, rarely queried after)
--   CAGGs:           tier after 60 days  (beyond 30D frontend range)
--   Mat tables:      tier after 60 days  (beyond 30D frontend range)
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- SOURCE TABLES — tier after 30 days
-- High-volume source data cools fast; the mid-level mat tables serve frontend.
-- ─────────────────────────────────────────────────────────────────────────────

-- Dexes sources
SELECT add_tiering_policy('dexes.src_acct_vaults',      move_after => INTERVAL '30 days', if_not_exists => true);
SELECT add_tiering_policy('dexes.src_acct_pool',         move_after => INTERVAL '30 days', if_not_exists => true);
SELECT add_tiering_policy('dexes.src_acct_position',     move_after => INTERVAL '30 days', if_not_exists => true);
SELECT add_tiering_policy('dexes.src_acct_ammconfig',    move_after => INTERVAL '30 days', if_not_exists => true);
SELECT add_tiering_policy('dexes.src_transactions',      move_after => INTERVAL '30 days', if_not_exists => true);
SELECT add_tiering_policy('dexes.src_tx_events',         move_after => INTERVAL '30 days', if_not_exists => true);
SELECT add_tiering_policy('dexes.src_acct_tickarray_queries', move_after => INTERVAL '30 days', if_not_exists => true);

-- Exponent sources
SELECT add_tiering_policy('exponent.src_vaults',               move_after => INTERVAL '30 days', if_not_exists => true);
SELECT add_tiering_policy('exponent.src_market_twos',           move_after => INTERVAL '30 days', if_not_exists => true);
SELECT add_tiering_policy('exponent.src_base_token_escrow',     move_after => INTERVAL '30 days', if_not_exists => true);
SELECT add_tiering_policy('exponent.src_sy_meta_account',       move_after => INTERVAL '30 days', if_not_exists => true);
SELECT add_tiering_policy('exponent.src_sy_token_account',      move_after => INTERVAL '30 days', if_not_exists => true);
SELECT add_tiering_policy('exponent.src_vault_yt_escrow',       move_after => INTERVAL '30 days', if_not_exists => true);
SELECT add_tiering_policy('exponent.src_vault_yield_position',  move_after => INTERVAL '30 days', if_not_exists => true);
SELECT add_tiering_policy('exponent.src_tx_events',             move_after => INTERVAL '30 days', if_not_exists => true);
SELECT add_tiering_policy('exponent.src_txns',                  move_after => INTERVAL '30 days', if_not_exists => true);

-- Kamino sources
SELECT add_tiering_policy('kamino_lend.src_reserves',        move_after => INTERVAL '30 days', if_not_exists => true);
SELECT add_tiering_policy('kamino_lend.src_obligations_agg', move_after => INTERVAL '30 days', if_not_exists => true);
SELECT add_tiering_policy('kamino_lend.src_txn',             move_after => INTERVAL '30 days', if_not_exists => true);
SELECT add_tiering_policy('kamino_lend.src_txn_events',      move_after => INTERVAL '30 days', if_not_exists => true);
SELECT add_tiering_policy('kamino_lend.src_lending_market',  move_after => INTERVAL '30 days', if_not_exists => true);

-- ─────────────────────────────────────────────────────────────────────────────
-- CAGGs — tier after 60 days
-- Frontend's longest lookback is 90D but uses 1-day aggregation; the mat
-- tables serve this. CAGG raw data beyond 60 days is rarely accessed.
-- ─────────────────────────────────────────────────────────────────────────────

SELECT add_tiering_policy('dexes.cagg_vaults_5s',     move_after => INTERVAL '60 days', if_not_exists => true);
SELECT add_tiering_policy('dexes.cagg_events_5s',     move_after => INTERVAL '60 days', if_not_exists => true);
SELECT add_tiering_policy('dexes.cagg_poolstate_5s',  move_after => INTERVAL '60 days', if_not_exists => true);
SELECT add_tiering_policy('dexes.cagg_tickarrays_5s', move_after => INTERVAL '60 days', if_not_exists => true);

SELECT add_tiering_policy('exponent.cagg_vaults_5s',              move_after => INTERVAL '60 days', if_not_exists => true);
SELECT add_tiering_policy('exponent.cagg_market_twos_5s',         move_after => INTERVAL '60 days', if_not_exists => true);
SELECT add_tiering_policy('exponent.cagg_tx_events_5s',           move_after => INTERVAL '60 days', if_not_exists => true);
SELECT add_tiering_policy('exponent.cagg_sy_meta_account_5s',     move_after => INTERVAL '60 days', if_not_exists => true);
SELECT add_tiering_policy('exponent.cagg_sy_token_account_5s',    move_after => INTERVAL '60 days', if_not_exists => true);
SELECT add_tiering_policy('exponent.cagg_vault_yt_escrow_5s',     move_after => INTERVAL '60 days', if_not_exists => true);
SELECT add_tiering_policy('exponent.cagg_vault_yield_position_5s', move_after => INTERVAL '60 days', if_not_exists => true);
SELECT add_tiering_policy('exponent.cagg_base_token_escrow_5s',   move_after => INTERVAL '60 days', if_not_exists => true);

SELECT add_tiering_policy('kamino_lend.cagg_reserves_5s',         move_after => INTERVAL '60 days', if_not_exists => true);
SELECT add_tiering_policy('kamino_lend.cagg_obligations_agg_5s',  move_after => INTERVAL '60 days', if_not_exists => true);
SELECT add_tiering_policy('kamino_lend.cagg_activities_5s',       move_after => INTERVAL '60 days', if_not_exists => true);

-- ─────────────────────────────────────────────────────────────────────────────
-- MAT TABLES — tier after 60 days
-- Mat tables serve the 90D lookback via re-bucketing. After 60 days the data
-- is cold enough to tier; 90D queries touching tiered chunks will be slightly
-- slower but still functional.
-- ─────────────────────────────────────────────────────────────────────────────

SELECT add_tiering_policy('dexes.mat_dex_timeseries_1m',          move_after => INTERVAL '60 days', if_not_exists => true);
SELECT add_tiering_policy('dexes.mat_dex_ohlcv_1m',              move_after => INTERVAL '60 days', if_not_exists => true);
SELECT add_tiering_policy('kamino_lend.mat_klend_reserve_ts_1m',  move_after => INTERVAL '60 days', if_not_exists => true);
SELECT add_tiering_policy('kamino_lend.mat_klend_obligation_ts_1m', move_after => INTERVAL '60 days', if_not_exists => true);
SELECT add_tiering_policy('kamino_lend.mat_klend_activity_ts_1m', move_after => INTERVAL '60 days', if_not_exists => true);
SELECT add_tiering_policy('exponent.mat_exp_timeseries_1m',       move_after => INTERVAL '60 days', if_not_exists => true);
SELECT add_tiering_policy('health.mat_health_base_hourly',        move_after => INTERVAL '60 days', if_not_exists => true);
SELECT add_tiering_policy('cross_protocol.mat_xp_ts_1m',         move_after => INTERVAL '60 days', if_not_exists => true);
