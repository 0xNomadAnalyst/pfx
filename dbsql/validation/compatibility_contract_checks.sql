-- ONyc/Solstice compatibility contract checks
-- Run in each target database before deploy:
--   psql -v ON_ERROR_STOP=1 -f pfx/dbsql/validation/compatibility_contract_checks.sql

SET search_path = dexes, public;

DO $$
DECLARE
    missing_functions TEXT[] := ARRAY[]::TEXT[];
    missing_columns TEXT[] := ARRAY[]::TEXT[];
BEGIN
    -- Function signature checks (name + arg count)
    IF to_regprocedure('dexes.get_view_dex_last(text,text,interval,boolean)') IS NULL THEN
        missing_functions := array_append(missing_functions, 'dexes.get_view_dex_last(text,text,interval,boolean)');
    END IF;
    IF to_regprocedure('dexes.get_view_dex_timeseries(text,text,text,integer,boolean)') IS NULL THEN
        missing_functions := array_append(missing_functions, 'dexes.get_view_dex_timeseries(text,text,text,integer,boolean)');
    END IF;
    IF to_regprocedure('dexes.get_view_tick_dist_simple(text,text,interval,boolean)') IS NULL THEN
        missing_functions := array_append(missing_functions, 'dexes.get_view_tick_dist_simple(text,text,interval,boolean)');
    END IF;
    IF to_regprocedure('dexes.get_view_dex_ohlcv(text,text,text,integer,boolean)') IS NULL THEN
        missing_functions := array_append(missing_functions, 'dexes.get_view_dex_ohlcv(text,text,text,integer,boolean)');
    END IF;
    IF to_regprocedure('dexes.get_view_liquidity_depth_table(text,text,boolean)') IS NULL THEN
        missing_functions := array_append(missing_functions, 'dexes.get_view_liquidity_depth_table(text,text,boolean)');
    END IF;
    IF to_regprocedure('dexes.get_view_dex_table_ranked_events(text,text,text,text,text,integer,text,boolean)') IS NULL THEN
        missing_functions := array_append(missing_functions, 'dexes.get_view_dex_table_ranked_events(text,text,text,text,text,integer,text,boolean)');
    END IF;
    IF to_regprocedure('dexes.get_view_sell_swaps_distribution(text,text,text,text,integer,boolean)') IS NULL THEN
        missing_functions := array_append(missing_functions, 'dexes.get_view_sell_swaps_distribution(text,text,text,text,integer,boolean)');
    END IF;
    IF to_regprocedure('dexes.get_view_sell_pressure_t0_distribution(text,text,text,text,integer,text,boolean)') IS NULL THEN
        missing_functions := array_append(missing_functions, 'dexes.get_view_sell_pressure_t0_distribution(text,text,text,text,integer,text,boolean)');
    END IF;

    -- Core reference table columns required by risk + dex pages
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'dexes' AND table_name = 'pool_tokens_reference' AND column_name = 'protocol'
    ) THEN
        missing_columns := array_append(missing_columns, 'dexes.pool_tokens_reference.protocol');
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'dexes' AND table_name = 'pool_tokens_reference' AND column_name = 'token_pair'
    ) THEN
        missing_columns := array_append(missing_columns, 'dexes.pool_tokens_reference.token_pair');
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'dexes' AND table_name = 'pool_tokens_reference' AND column_name = 'token0_symbol'
    ) THEN
        missing_columns := array_append(missing_columns, 'dexes.pool_tokens_reference.token0_symbol');
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'dexes' AND table_name = 'pool_tokens_reference' AND column_name = 'token1_symbol'
    ) THEN
        missing_columns := array_append(missing_columns, 'dexes.pool_tokens_reference.token1_symbol');
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'dexes' AND table_name = 'pool_tokens_reference' AND column_name = 'pool_address'
    ) THEN
        missing_columns := array_append(missing_columns, 'dexes.pool_tokens_reference.pool_address');
    END IF;

    IF array_length(missing_functions, 1) IS NOT NULL THEN
        RAISE EXCEPTION 'Compatibility check failed: missing function signatures: %', missing_functions;
    END IF;
    IF array_length(missing_columns, 1) IS NOT NULL THEN
        RAISE EXCEPTION 'Compatibility check failed: missing required columns: %', missing_columns;
    END IF;
END $$;

-- Smoke-call shape checks (LIMIT 1; should compile/execute)
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

SELECT * FROM _validation_sample_pair s,
LATERAL dexes.get_view_dex_last(s.protocol, s.token_pair, INTERVAL '1 hour', FALSE) LIMIT 1;
SELECT * FROM _validation_sample_pair s,
LATERAL dexes.get_view_dex_timeseries(s.protocol, s.token_pair, '24h', 1, FALSE) LIMIT 1;
SELECT * FROM _validation_sample_pair s,
LATERAL dexes.get_view_tick_dist_simple(s.protocol, s.token_pair, INTERVAL '24 hours', FALSE) LIMIT 1;
SELECT * FROM _validation_sample_pair s,
LATERAL dexes.get_view_dex_ohlcv(s.protocol, s.token_pair, '15 minutes', 120, FALSE) LIMIT 1;
SELECT * FROM _validation_sample_pair s,
LATERAL dexes.get_view_liquidity_depth_table(s.protocol, s.token_pair, FALSE) LIMIT 1;
SELECT * FROM _validation_sample_pair s,
LATERAL dexes.get_view_dex_table_ranked_events(s.protocol, s.token_pair, 'swap', 't0', 'out', 5, '24h', FALSE) LIMIT 1;
SELECT * FROM _validation_sample_pair s,
LATERAL dexes.get_view_sell_swaps_distribution(s.protocol, s.token_pair, 't0', '24h', 10, FALSE) LIMIT 1;
SELECT * FROM _validation_sample_pair s,
LATERAL dexes.get_view_sell_pressure_t0_distribution(s.protocol, s.token_pair, '1 hour', '24h', 10, 'sell_only', FALSE) LIMIT 1;

SELECT 'compatibility_contract_checks: OK' AS status;
