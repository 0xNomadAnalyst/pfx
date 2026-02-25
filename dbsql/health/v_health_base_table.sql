-- =============================================================================
-- health.v_health_base_table
-- Base table activity with frequency-based staleness status
--
-- Implemented as a PL/pgSQL function (STABLE, RETURN NEXT) to avoid the planner
-- overhead of a 30-table UNION ALL view.  Each table is queried independently
-- inside a loop via EXECUTE format(), so PostgreSQL plans each small query on
-- its own and can leverage chunk exclusion.
--
-- A thin VIEW wraps the function so existing callers (including
-- v_health_master_table) keep working unchanged.
--
-- Status logic: expected_gap = (168h x 60min) / sample_count
--   Active  (NORMAL):   gap_ratio <= 2x
--   Check   (ELEVATED): gap_ratio 2-5x
--   Stale   (HIGH):     gap_ratio 5-10x
--   ANOMALY:            gap_ratio > 10x
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

DROP VIEW IF EXISTS health.v_health_base_table CASCADE;
DROP FUNCTION IF EXISTS health._fn_base_table() CASCADE;

CREATE OR REPLACE FUNCTION health._fn_base_table()
 RETURNS TABLE(schema_name text, table_name text, latest_time timestamp with time zone, minutes_since_latest double precision, rows_last_hour bigint, rows_last_24h bigint, avg_rows_per_hour double precision, sample_count bigint, p5_hourly_count double precision, p95_hourly_count double precision, expected_gap_mins double precision, gap_ratio double precision, severity integer, status text, is_red boolean)
 LANGUAGE plpgsql
 STABLE
AS $function$ DECLARE _tbl RECORD; _latest timestamptz; _c1h bigint; _c24h bigint; _c7d bigint; _msl double precision; _egm double precision; _gr double precision; BEGIN FOR _tbl IN SELECT * FROM (VALUES ('dexes','src_acct_pool','time'),('dexes','src_acct_vaults','time'),('dexes','src_tx_events','time'),('dexes','src_transactions','time'),('dexes','src_acct_tickarray_queries','time'),('dexes','src_acct_position','time'),('kamino_lend','src_reserves','time'),('kamino_lend','src_obligations','block_time'),('kamino_lend','src_obligations_agg','time'),('kamino_lend','src_lending_market','time'),('kamino_lend','src_txn','time'),('kamino_lend','src_txn_events','time'),('exponent','src_vaults','time'),('exponent','src_market_twos','time'),('exponent','src_sy_meta_account','time'),('exponent','src_sy_token_account','time'),('exponent','src_vault_yield_position','time'),('exponent','src_vault_yt_escrow','time'),('exponent','src_base_token_escrow','time'),('exponent','src_tx_events','time'),('exponent','src_txns','time')) AS t(s,tbl,tcol) LOOP EXECUTE format($q$SELECT (SELECT MAX(%I) FROM %I.%I),(SELECT COUNT(*) FROM %I.%I WHERE %I > NOW()-INTERVAL '1 hour'),(SELECT COUNT(*) FROM %I.%I WHERE %I > NOW()-INTERVAL '24 hours')$q$,_tbl.tcol,_tbl.s,_tbl.tbl,_tbl.s,_tbl.tbl,_tbl.tcol,_tbl.s,_tbl.tbl,_tbl.tcol) INTO _latest, _c1h, _c24h; IF _latest IS NULL THEN CONTINUE; END IF; EXECUTE format($q$SELECT COUNT(DISTINCT time_bucket('1 hour', %I)) FROM %I.%I WHERE %I > NOW()-INTERVAL '7 days'$q$,_tbl.tcol,_tbl.s,_tbl.tbl,_tbl.tcol) INTO _c7d; _msl := EXTRACT(EPOCH FROM (NOW()-_latest))/60.0; _egm := CASE WHEN COALESCE(_c7d,0)>0 THEN (168.0*60.0)/_c7d ELSE NULL END; _gr := CASE WHEN _egm IS NOT NULL AND _egm>0 THEN _msl/_egm ELSE NULL END; schema_name := _tbl.s; table_name := _tbl.tbl; latest_time := _latest; minutes_since_latest := _msl; rows_last_hour := _c1h; rows_last_24h := _c24h; avg_rows_per_hour := _c24h/24.0; sample_count := _c7d; p5_hourly_count := NULL; p95_hourly_count := NULL; expected_gap_mins := _egm; gap_ratio := _gr; severity := CASE WHEN _egm IS NOT NULL AND _egm>0 THEN CASE WHEN _msl/_egm<=2.0 THEN 0 WHEN _msl/_egm<=5.0 THEN 1 WHEN _msl/_egm<=10.0 THEN 2 ELSE 3 END WHEN _msl<=1440 THEN 0 WHEN _msl<=4320 THEN 1 WHEN _msl<=10080 THEN 2 ELSE 3 END; status := CASE WHEN _egm IS NOT NULL AND _egm>0 THEN CASE WHEN _msl/_egm<=2.0 THEN 'Active' WHEN _msl/_egm<=5.0 THEN 'Check' WHEN _msl/_egm<=10.0 THEN 'Stale' ELSE 'ANOMALY' END WHEN _msl<=1440 THEN 'Active' WHEN _msl<=4320 THEN 'Quiet' WHEN _msl<=10080 THEN 'Check' ELSE 'Stale' END; is_red := CASE WHEN _egm IS NOT NULL AND _egm>0 THEN _msl/_egm>5.0 ELSE _msl>10080 END; RETURN NEXT; END LOOP; END; $function$
;

-- Thin wrapper VIEW so callers and v_health_master_table work unchanged
CREATE OR REPLACE VIEW health.v_health_base_table AS
SELECT * FROM health._fn_base_table();
