-- Optional index quick wins for ONyc DBSQL hot paths.
-- Safe to run multiple times.

SET search_path = dexes, public;

CREATE INDEX IF NOT EXISTS idx_cagg_events_5s_proto_pair_cat_time
ON dexes.cagg_events_5s (protocol, token_pair, activity_category, bucket_time DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_events_5s_pool_time
ON dexes.cagg_events_5s (pool_address, bucket_time DESC);

CREATE INDEX IF NOT EXISTS idx_cagg_vaults_5s_pool_time
ON dexes.cagg_vaults_5s (pool_address, bucket_time DESC);

CREATE INDEX IF NOT EXISTS idx_src_tx_events_proto_pair_event_time
ON dexes.src_tx_events (protocol, token_pair, event_type, time DESC);

CREATE INDEX IF NOT EXISTS idx_src_tickarray_queries_pool_time
ON dexes.src_acct_tickarray_queries (pool_address, time DESC);

CREATE INDEX IF NOT EXISTS idx_src_tickarray_tokendist_latest_pool_query
ON dexes.src_acct_tickarray_tokendist_latest (pool_address, query_id DESC);

CREATE INDEX IF NOT EXISTS idx_src_tickarray_tokendist_query_tick
ON dexes.src_acct_tickarray_tokendist (query_id, tick_lower);

CREATE INDEX IF NOT EXISTS idx_src_acct_vaults_pool_time
ON dexes.src_acct_vaults (pool_address, "time" DESC);

CREATE INDEX IF NOT EXISTS idx_src_tx_events_pool_swap_time
ON dexes.src_tx_events (pool_address, "time" DESC)
WHERE event_type = 'swap';

SELECT 'index_quickwins: complete' AS status;
