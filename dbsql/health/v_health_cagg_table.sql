-- =============================================================================
-- health.v_health_cagg_table
-- CAGG refresh health -- compares CAGG bucket times to base table times
--
-- Implemented as a PL/pgSQL function (STABLE, RETURN NEXT) to avoid the planner
-- overhead of a multi-CAGG UNION ALL view.  Each CAGG+source pair is queried
-- independently inside a loop via EXECUTE format().
--
-- Missing CAGGs are skipped gracefully (EXCEPTION WHEN undefined_table).
--
-- A thin VIEW wraps the function so existing callers (including
-- v_health_master_table) keep working unchanged.
--
-- Status logic:
--   Refresh OK:      CAGG within 5 min of source
--   Refresh Delayed: 5-15 min lag
--   Source Stale:    Source exceeds 2x its frequency-based expected gap
--   Refresh Broken:  CAGG >15 min behind a fresh source (red status)
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

DROP VIEW IF EXISTS health.v_health_cagg_table CASCADE;
DROP FUNCTION IF EXISTS health._fn_cagg_table() CASCADE;
DROP FUNCTION IF EXISTS health._fn_source_benchmarks() CASCADE;

CREATE OR REPLACE FUNCTION health._fn_cagg_table()
RETURNS TABLE(
    view_schema       text,
    view_name         text,
    source_table      text,
    cagg_latest       timestamptz,
    source_latest     timestamptz,
    cagg_age_mins     double precision,
    source_age_mins   double precision,
    refresh_lag_mins  double precision,
    expected_gap_mins double precision,
    status            text,
    severity          integer,
    is_red            boolean
)
LANGUAGE plpgsql STABLE
AS $function$
DECLARE
    _c   RECORD;
    _cl  timestamptz;
    _sl  timestamptz;
    _cam double precision;
    _sam double precision;
    _rlm double precision;
    _egm double precision;
    _bh  bigint;
BEGIN
    FOR _c IN
        SELECT * FROM (VALUES
            ('dexes','cagg_events_5s','src_tx_events','bucket_time','time','time'),
            ('dexes','cagg_poolstate_5s','src_acct_pool','bucket_time','time','time'),
            ('dexes','cagg_vaults_5s','src_acct_vaults','bucket_time','time','time'),
            ('dexes','cagg_tickarrays_5s','src_acct_tickarray_queries','bucket','time','time'),
            ('kamino_lend','cagg_activities_5s','src_txn_events','bucket','meta_block_time','time'),
            ('kamino_lend','cagg_reserves_5s','src_reserves','bucket','time','time'),
            ('kamino_lend','cagg_obligations_agg_5s','src_obligations','bucket','block_time','block_time'),
            ('exponent','cagg_vaults_5s','src_vaults','bucket','block_time','time'),
            ('exponent','cagg_market_twos_5s','src_market_twos','bucket','block_time','time'),
            ('exponent','cagg_sy_meta_account_5s','src_sy_meta_account','bucket','time','time'),
            ('exponent','cagg_sy_token_account_5s','src_sy_token_account','bucket','time','time'),
            ('exponent','cagg_vault_yield_position_5s','src_vault_yield_position','bucket','time','time'),
            ('exponent','cagg_vault_yt_escrow_5s','src_vault_yt_escrow','bucket','time','time'),
            ('exponent','cagg_base_token_escrow_5s','src_base_token_escrow','bucket','time','time'),
            ('exponent','cagg_tx_events_5s','src_tx_events','bucket_time','time','time')
        ) AS t(vs,vn,st,cc,sc,bc)
    LOOP
        BEGIN
            EXECUTE format($q$SELECT MAX(%I) FROM %I.%I$q$, _c.cc, _c.vs, _c.vn) INTO _cl;
            EXECUTE format($q$SELECT MAX(%I) FROM %I.%I$q$, _c.sc, _c.vs, _c.st) INTO _sl;
            EXECUTE format(
                $q$SELECT COUNT(DISTINCT time_bucket('1 hour',%I)) FROM %I.%I WHERE %I > NOW()-INTERVAL '7 days'$q$,
                _c.bc, _c.vs, _c.st, _c.bc
            ) INTO _bh;
        EXCEPTION WHEN undefined_table THEN
            -- CAGG or source table does not exist yet — skip this entry
            CONTINUE;
        END;

        _cam := EXTRACT(EPOCH FROM (NOW() - _cl)) / 60.0;
        _sam := EXTRACT(EPOCH FROM (NOW() - _sl)) / 60.0;
        _rlm := EXTRACT(EPOCH FROM (_sl - _cl)) / 60.0;
        _egm := CASE WHEN COALESCE(_bh, 0) > 0 THEN (168.0 * 60.0) / _bh ELSE 120.0 END;

        view_schema       := _c.vs;
        view_name         := _c.vn;
        source_table      := _c.st;
        cagg_latest       := _cl;
        source_latest     := _sl;
        cagg_age_mins     := _cam;
        source_age_mins   := _sam;
        refresh_lag_mins  := _rlm;
        expected_gap_mins := _egm;

        status := CASE
            WHEN _cam IS NULL AND _sam IS NULL THEN 'No data'
            WHEN _sam IS NULL OR _sam > _egm * 2.0 THEN 'Source Stale'
            WHEN _rlm IS NOT NULL AND _rlm > 15 THEN 'Refresh Broken'
            WHEN _rlm IS NOT NULL AND _rlm > 5  THEN 'Refresh Delayed'
            ELSE 'Refresh OK'
        END;

        severity := CASE
            WHEN _cam IS NULL AND _sam IS NULL THEN -1
            WHEN _sam IS NULL OR _sam > _egm * 2.0 THEN 1
            WHEN _rlm IS NOT NULL AND _rlm > 15 THEN 3
            WHEN _rlm IS NOT NULL AND _rlm > 5  THEN 1
            ELSE 0
        END;

        is_red := (_sam IS NOT NULL AND _sam <= _egm * 2.0 AND _rlm IS NOT NULL AND _rlm > 15);

        RETURN NEXT;
    END LOOP;
END;
$function$;

-- Thin wrapper VIEW so callers and v_health_master_table work unchanged
CREATE OR REPLACE VIEW health.v_health_cagg_table AS
SELECT * FROM health._fn_cagg_table();
