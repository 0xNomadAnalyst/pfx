-- =============================================================================
-- 04_tiered_storage.sql
-- Move older compressed chunks to object storage (S3-compatible tiered storage)
-- to reduce local disk costs while keeping data queryable.
--
-- Tiger Cloud tiering moves chunks from local SSD to object storage.
-- Tiered chunks are still transparently queryable via SQL but at higher
-- latency — appropriate for data outside the frontend's 90-day lookback.
--
-- IMPORTANT: tiered reads must be enabled at the database level:
--   ALTER DATABASE tsdb SET timescaledb.enable_tiered_reads = true;
-- Without this, queries against tiered (S3) chunks silently return no rows.
--
-- Prerequisites: columnstore must be enabled on the table (chunks must be
-- compressed before they can be tiered).
--
-- Tiering schedule:
--   Source tables:    tier after 30 days  (ingestion data, rarely queried after)
--   CAGGs:           tier after 60 days  (beyond 30D frontend range)
--   Mat tables:      tier after 60 days  (beyond 30D frontend range)
--
-- Integer-partitioned tables (see end of file):
--   src_acct_tickarray_tokendist uses custom policy_movechunk_to_s3 jobs
--   with integer-based move_after thresholds — not add_tiering_policy.
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

-- ─────────────────────────────────────────────────────────────────────────────
-- INTEGER-PARTITIONED TABLES — custom policy_movechunk_to_s3 jobs
--
-- These tables use query_id (integer) as their partition dimension, so
-- add_tiering_policy() (which expects INTERVAL) cannot be used.
-- Instead, tiering is managed via custom policy_movechunk_to_s3 jobs
-- created with alter_job / add_job directly.
--
-- src_acct_tickarray_tokendist:
--   Hypertable ID 41, integer dimension (query_id).
--   move_after = 25000 query_ids (~8 days at current ingestion rate of
--   ~2800 query_ids/day across 2 pools). The heatmap "Liquidity Change"
--   widget requires prior tick distribution snapshots for delta comparisons
--   up to 7 days, so local retention must exceed that window.
--
--   To view/update:
--     SELECT * FROM timescaledb_information.jobs WHERE hypertable_name = 'src_acct_tickarray_tokendist';
--     SELECT alter_job(<job_id>, config => '{"move_after": 25000, "hypertable_id": 41}'::jsonb);
--
-- src_acct_tickarray_queries:
--   Hypertable ID 6, time dimension (time column).
--   Standard add_tiering_policy above sets 30 days. A pre-existing custom
--   policy_movechunk_to_s3 job may be more aggressive — verify with:
--     SELECT * FROM timescaledb_information.jobs WHERE hypertable_name = 'src_acct_tickarray_queries';
--   If the custom job move_after is < 8 days, update it to at least 8 days
--   so the tick dist function can find prior snapshots for 7D lookbacks
--   without hitting S3.
-- ─────────────────────────────────────────────────────────────────────────────
