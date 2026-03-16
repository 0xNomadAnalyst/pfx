-- ONyc DBSQL performance baseline + cost gates
-- Run with representative protocol/pair values in each pipeline DB.
-- This script does not mutate data; it emits baseline measurements and gate targets.

SET search_path = dexes, public;

-- ---------------------------------------
-- Gate targets (adjust as needed per env)
-- ---------------------------------------
SELECT
    'gate_target' AS metric_type,
    'p95_widget_ms' AS metric_name,
    1200::NUMERIC AS target_value
UNION ALL SELECT 'gate_target', 'refresh_mat_dex_last_ms', 180000
UNION ALL SELECT 'gate_target', 'refresh_mat_dex_timeseries_1m_ms', 120000
UNION ALL SELECT 'gate_target', 'distribution_fn_single_call_ms', 500
UNION ALL SELECT 'gate_target', 'db_cpu_io_delta_pct_max', 5;

-- ---------------------------------------
-- Index audit (quick wins first)
-- ---------------------------------------
SELECT
    'index_check' AS metric_type,
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE schemaname = 'dexes'
  AND (
      tablename IN (
          'cagg_events_5s',
          'cagg_vaults_5s',
          'src_tx_events',
          'src_acct_tickarray_queries',
          'src_acct_tickarray_tokendist',
          'src_acct_tickarray_tokendist_latest',
          'mat_dex_last',
          'mat_dex_timeseries_1m'
      )
      OR indexdef ILIKE '%lower(token_pair)%'
  )
ORDER BY tablename, indexname;

-- ---------------------------------------
-- EXPLAIN ANALYZE candidates
-- ---------------------------------------
-- Use these in psql manually so actual plans are visible:
-- EXPLAIN (ANALYZE, BUFFERS, VERBOSE) SELECT * FROM dexes.get_view_dex_table_ranked_events('raydium','USX-USDC','swap','t0','out',10,'24h',FALSE);
-- EXPLAIN (ANALYZE, BUFFERS, VERBOSE) SELECT * FROM dexes.get_view_sell_swaps_distribution('raydium','USX-USDC','t0','24h',10,FALSE);
-- EXPLAIN (ANALYZE, BUFFERS, VERBOSE) SELECT * FROM dexes.get_view_sell_pressure_t0_distribution('raydium','USX-USDC','1 hour','24h',10,'sell_only',FALSE);
-- EXPLAIN (ANALYZE, BUFFERS, VERBOSE) SELECT * FROM dexes.get_view_tick_dist_simple('raydium','USX-USDC',INTERVAL '24 hours',FALSE);
-- EXPLAIN (ANALYZE, BUFFERS, VERBOSE) SELECT * FROM dexes.get_view_dex_timeseries('raydium','USX-USDC','24h',1,FALSE);

-- ---------------------------------------
-- Baseline timings (coarse; client-side stopwatch)
-- ---------------------------------------
CREATE TEMP TABLE _validation_sample_pair AS
SELECT protocol, token_pair
FROM dexes.pool_tokens_reference
WHERE protocol IS NOT NULL
  AND token_pair IS NOT NULL
ORDER BY
  CASE WHEN token_pair ILIKE '%ONyc%' THEN 0 ELSE 1 END,
  protocol,
  token_pair
LIMIT 1;

-- For deeper timing, wrap in your own timing harness.
SELECT 'baseline_probe' AS metric_type, 'get_view_dex_table_ranked_events' AS metric_name, NOW() AS measured_at;
SELECT COUNT(*) FROM _validation_sample_pair s,
LATERAL dexes.get_view_dex_table_ranked_events(s.protocol, s.token_pair, 'swap', 't0', 'out', 10, '24h', FALSE);

SELECT 'baseline_probe', 'get_view_sell_swaps_distribution', NOW();
SELECT COUNT(*) FROM _validation_sample_pair s,
LATERAL dexes.get_view_sell_swaps_distribution(s.protocol, s.token_pair, 't0', '24h', 10, FALSE);

SELECT 'baseline_probe', 'get_view_sell_pressure_t0_distribution', NOW();
SELECT COUNT(*) FROM _validation_sample_pair s,
LATERAL dexes.get_view_sell_pressure_t0_distribution(s.protocol, s.token_pair, '1 hour', '24h', 10, 'sell_only', FALSE);

SELECT 'baseline_probe', 'get_view_tick_dist_simple', NOW();
SELECT COUNT(*) FROM _validation_sample_pair s,
LATERAL dexes.get_view_tick_dist_simple(s.protocol, s.token_pair, INTERVAL '24 hours', FALSE);

SELECT 'baseline_probe', 'get_view_dex_timeseries', NOW();
SELECT COUNT(*) FROM _validation_sample_pair s,
LATERAL dexes.get_view_dex_timeseries(s.protocol, s.token_pair, '24h', 1, FALSE);

-- Distribution impact skip-gate probe (actual API uses 10 buckets)
SELECT 'baseline_probe', 'distribution_impact_skip_gate_candidate', NOW();
SELECT COUNT(*) FROM _validation_sample_pair s,
LATERAL dexes.get_view_sell_swaps_distribution(s.protocol, s.token_pair, 't0', '24h', 10, FALSE);
SELECT COUNT(*) FROM _validation_sample_pair s,
LATERAL dexes.get_view_sell_pressure_t0_distribution(s.protocol, s.token_pair, '1 hour', '24h', 10, 'sell_only', FALSE);

SELECT 'perf_baseline_and_gates: complete' AS status;
