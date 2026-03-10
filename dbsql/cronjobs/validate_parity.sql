-- =====================================================
-- ONyc Mid-Level ETL: Parity Validation Queries
-- =====================================================
-- Run these queries AFTER deploying all SQL objects and running
-- at least one full refresh cycle via onyc_refresh.sh.
--
-- Each section validates one migrated view function.
-- Pass criteria documented inline.
-- =====================================================

-- =====================================================
-- 1. SCHEMA PARITY: Column names/types match
-- =====================================================
-- Compare output schemas of new vs original view functions.
-- Run each pair and diff the column_name + data_type lists.

-- Dex timeseries: schema check
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'dexes'
  AND table_name = 'mat_dex_timeseries_1m'
ORDER BY ordinal_position;

-- Dex OHLCV: schema check
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'dexes'
  AND table_name = 'mat_dex_ohlcv_1m'
ORDER BY ordinal_position;

-- Dex last: schema check
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'dexes'
  AND table_name = 'mat_dex_last'
ORDER BY ordinal_position;

-- =====================================================
-- 2. BUCKET BOUNDARY PARITY (Dex Timeseries)
-- =====================================================
-- For each FE range, compare row count and boundary timestamps.
-- Tolerance: row count within +/- 1 (boundary rounding).

-- 2H / 2min
EXPLAIN ANALYZE
SELECT COUNT(*), MIN(bucket_time), MAX(bucket_time)
FROM dexes.get_view_dex_timeseries(
    'raydium_clmm', 'ONyc/USDC',
    '2 minutes', NOW() - INTERVAL '2 hours', NOW(), 60
);

-- 4H / 5min
EXPLAIN ANALYZE
SELECT COUNT(*), MIN(bucket_time), MAX(bucket_time)
FROM dexes.get_view_dex_timeseries(
    'raydium_clmm', 'ONyc/USDC',
    '5 minutes', NOW() - INTERVAL '4 hours', NOW(), 48
);

-- 1D / 30min
EXPLAIN ANALYZE
SELECT COUNT(*), MIN(bucket_time), MAX(bucket_time)
FROM dexes.get_view_dex_timeseries(
    'raydium_clmm', 'ONyc/USDC',
    '30 minutes', NOW() - INTERVAL '1 day', NOW(), 48
);

-- 7D / 3h
EXPLAIN ANALYZE
SELECT COUNT(*), MIN(bucket_time), MAX(bucket_time)
FROM dexes.get_view_dex_timeseries(
    'raydium_clmm', 'ONyc/USDC',
    '3 hours', NOW() - INTERVAL '7 days', NOW(), 56
);

-- 30D / 12h
EXPLAIN ANALYZE
SELECT COUNT(*), MIN(bucket_time), MAX(bucket_time)
FROM dexes.get_view_dex_timeseries(
    'raydium_clmm', 'ONyc/USDC',
    '12 hours', NOW() - INTERVAL '30 days', NOW(), 60
);

-- 90D / 1day
EXPLAIN ANALYZE
SELECT COUNT(*), MIN(bucket_time), MAX(bucket_time)
FROM dexes.get_view_dex_timeseries(
    'raydium_clmm', 'ONyc/USDC',
    '1 day', NOW() - INTERVAL '90 days', NOW(), 90
);

-- =====================================================
-- 3. BUCKET BOUNDARY PARITY (Kamino Timeseries)
-- =====================================================

-- 2H / 2min
EXPLAIN ANALYZE
SELECT COUNT(*), MIN(bucket_time), MAX(bucket_time)
FROM kamino_lend.get_view_klend_timeseries(
    '2 minutes', NOW() - INTERVAL '2 hours', NOW(), 60
);

-- 1D / 30min
EXPLAIN ANALYZE
SELECT COUNT(*), MIN(bucket_time), MAX(bucket_time)
FROM kamino_lend.get_view_klend_timeseries(
    '30 minutes', NOW() - INTERVAL '1 day', NOW(), 48
);

-- =====================================================
-- 4. BUCKET BOUNDARY PARITY (Exponent Timeseries)
-- =====================================================

-- 2H / 2min
EXPLAIN ANALYZE
SELECT COUNT(*), MIN(bucket_time), MAX(bucket_time)
FROM exponent.get_view_exponent_timeseries(
    'mkt2', '2 minutes', NOW() - INTERVAL '2 hours', NOW()
);

-- 1D / 30min
EXPLAIN ANALYZE
SELECT COUNT(*), MIN(bucket_time), MAX(bucket_time)
FROM exponent.get_view_exponent_timeseries(
    'mkt2', '30 minutes', NOW() - INTERVAL '1 day', NOW()
);

-- =====================================================
-- 5. LATENCY BENCHMARKS
-- =====================================================
-- Run each query 3x and record p95 execution time.
-- Target: >5x improvement over original on the reference DB.

-- Dex timeseries (heaviest: was 4-CAGG join + LOCF)
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM dexes.get_view_dex_timeseries(
    'raydium_clmm', 'ONyc/USDC',
    '2 minutes', NOW() - INTERVAL '2 hours', NOW(), 60
);

-- Dex last
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM dexes.get_view_dex_last('raydium_clmm', 'ONyc/USDC', INTERVAL '1 hour');

-- Dex OHLCV
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM dexes.get_view_dex_ohlcv(
    'raydium_clmm', 'ONyc/USDC',
    '30 minutes', NOW() - INTERVAL '7 days', NOW(), 336
);

-- Kamino timeseries
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM kamino_lend.get_view_klend_timeseries(
    '2 minutes', NOW() - INTERVAL '2 hours', NOW(), 60
);

-- Kamino last
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM kamino_lend.v_last;

-- Kamino config
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM kamino_lend.v_config;

-- Exponent timeseries
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM exponent.get_view_exponent_timeseries(
    'mkt2', '2 minutes', NOW() - INTERVAL '2 hours', NOW()
);

-- Exponent last
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM exponent.get_view_exponent_last();

-- =====================================================
-- 6. REFRESH RUNTIME CHECK
-- =====================================================
-- Each refresh procedure should complete in < 10s.

DO $$
DECLARE
    t_start TIMESTAMPTZ;
    t_end TIMESTAMPTZ;
BEGIN
    -- Dex timeseries
    t_start := clock_timestamp();
    CALL dexes.refresh_mat_dex_timeseries_1m();
    t_end := clock_timestamp();
    RAISE NOTICE 'refresh_mat_dex_timeseries_1m: %ms', EXTRACT(MILLISECOND FROM t_end - t_start)::INTEGER;

    -- Dex OHLCV
    t_start := clock_timestamp();
    CALL dexes.refresh_mat_dex_ohlcv_1m();
    t_end := clock_timestamp();
    RAISE NOTICE 'refresh_mat_dex_ohlcv_1m: %ms', EXTRACT(MILLISECOND FROM t_end - t_start)::INTEGER;

    -- Dex last
    t_start := clock_timestamp();
    CALL dexes.refresh_mat_dex_last();
    t_end := clock_timestamp();
    RAISE NOTICE 'refresh_mat_dex_last: %ms', EXTRACT(MILLISECOND FROM t_end - t_start)::INTEGER;

    -- Kamino timeseries
    t_start := clock_timestamp();
    CALL kamino_lend.refresh_mat_klend_timeseries_1m();
    t_end := clock_timestamp();
    RAISE NOTICE 'refresh_mat_klend_timeseries_1m: %ms', EXTRACT(MILLISECOND FROM t_end - t_start)::INTEGER;

    -- Kamino last
    t_start := clock_timestamp();
    CALL kamino_lend.refresh_mat_klend_last();
    t_end := clock_timestamp();
    RAISE NOTICE 'refresh_mat_klend_last: %ms', EXTRACT(MILLISECOND FROM t_end - t_start)::INTEGER;

    -- Kamino config
    t_start := clock_timestamp();
    CALL kamino_lend.refresh_mat_klend_config();
    t_end := clock_timestamp();
    RAISE NOTICE 'refresh_mat_klend_config: %ms', EXTRACT(MILLISECOND FROM t_end - t_start)::INTEGER;

    -- Exponent timeseries
    t_start := clock_timestamp();
    CALL exponent.refresh_mat_exp_timeseries_1m();
    t_end := clock_timestamp();
    RAISE NOTICE 'refresh_mat_exp_timeseries_1m: %ms', EXTRACT(MILLISECOND FROM t_end - t_start)::INTEGER;

    -- Exponent last
    t_start := clock_timestamp();
    CALL exponent.refresh_mat_exp_last();
    t_end := clock_timestamp();
    RAISE NOTICE 'refresh_mat_exp_last: %ms', EXTRACT(MILLISECOND FROM t_end - t_start)::INTEGER;
END $$;

-- =====================================================
-- 7. STALENESS CHECK
-- =====================================================
-- All refreshed_at values should be < 60s old after a full cycle.

SELECT
    'dex_ts_1m' AS table_name,
    MAX(refreshed_at) AS last_refresh,
    EXTRACT(EPOCH FROM NOW() - MAX(refreshed_at))::INTEGER AS staleness_s
FROM dexes.mat_dex_timeseries_1m
UNION ALL
SELECT 'dex_ohlcv_1m', MAX(refreshed_at), EXTRACT(EPOCH FROM NOW() - MAX(refreshed_at))::INTEGER
FROM dexes.mat_dex_ohlcv_1m
UNION ALL
SELECT 'dex_last', MAX(refreshed_at), EXTRACT(EPOCH FROM NOW() - MAX(refreshed_at))::INTEGER
FROM dexes.mat_dex_last
UNION ALL
SELECT 'klend_reserve_1m', MAX(refreshed_at), EXTRACT(EPOCH FROM NOW() - MAX(refreshed_at))::INTEGER
FROM kamino_lend.mat_klend_reserve_ts_1m
UNION ALL
SELECT 'klend_obligation_1m', MAX(refreshed_at), EXTRACT(EPOCH FROM NOW() - MAX(refreshed_at))::INTEGER
FROM kamino_lend.mat_klend_obligation_ts_1m
UNION ALL
SELECT 'klend_activity_1m', MAX(refreshed_at), EXTRACT(EPOCH FROM NOW() - MAX(refreshed_at))::INTEGER
FROM kamino_lend.mat_klend_activity_ts_1m
UNION ALL
SELECT 'klend_last_reserves', MAX(refreshed_at), EXTRACT(EPOCH FROM NOW() - MAX(refreshed_at))::INTEGER
FROM kamino_lend.mat_klend_last_reserves
UNION ALL
SELECT 'klend_config', MAX(refreshed_at), EXTRACT(EPOCH FROM NOW() - MAX(refreshed_at))::INTEGER
FROM kamino_lend.mat_klend_config
UNION ALL
SELECT 'exp_ts_1m', MAX(refreshed_at), EXTRACT(EPOCH FROM NOW() - MAX(refreshed_at))::INTEGER
FROM exponent.mat_exp_timeseries_1m
UNION ALL
SELECT 'exp_last', MAX(refreshed_at), EXTRACT(EPOCH FROM NOW() - MAX(refreshed_at))::INTEGER
FROM exponent.mat_exp_last
ORDER BY table_name;
