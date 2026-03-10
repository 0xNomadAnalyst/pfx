-- =============================================================================
-- mat_health_cagg_status
-- Pre-computes CAGG refresh health per CAGG/source pair. Replaces 15 pairs
-- of MAX() + COUNT(DISTINCT) queries (45 total) per request to
-- v_health_cagg_table with a single table read.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS health;

CREATE TABLE IF NOT EXISTS health.mat_health_cagg_status (
    view_schema       TEXT NOT NULL,
    view_name         TEXT NOT NULL,
    source_table      TEXT NOT NULL,
    cagg_latest       TIMESTAMPTZ,
    source_latest     TIMESTAMPTZ,
    cagg_age_mins     DOUBLE PRECISION,
    source_age_mins   DOUBLE PRECISION,
    refresh_lag_mins  DOUBLE PRECISION,
    expected_gap_mins DOUBLE PRECISION,
    refreshed_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (view_schema, view_name)
);

-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE health.refresh_mat_health_cagg_status()
LANGUAGE plpgsql AS $$
DECLARE
    _c   RECORD;
    _cl  TIMESTAMPTZ;
    _sl  TIMESTAMPTZ;
    _cam DOUBLE PRECISION;
    _sam DOUBLE PRECISION;
    _rlm DOUBLE PRECISION;
    _egm DOUBLE PRECISION;
    _bh  BIGINT;
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
        ) AS t(vs, vn, st, cc, sc, bc)
    LOOP
        BEGIN
            EXECUTE format($q$SELECT MAX(%I) FROM %I.%I$q$, _c.cc, _c.vs, _c.vn) INTO _cl;
            EXECUTE format($q$SELECT MAX(%I) FROM %I.%I$q$, _c.sc, _c.vs, _c.st) INTO _sl;
            EXECUTE format(
                $q$SELECT COUNT(DISTINCT time_bucket('1 hour', %I))
                   FROM %I.%I WHERE %I > NOW() - INTERVAL '7 days'$q$,
                _c.bc, _c.vs, _c.st, _c.bc
            ) INTO _bh;
        EXCEPTION WHEN undefined_table THEN
            CONTINUE;
        END;

        _cam := EXTRACT(EPOCH FROM (NOW() - _cl)) / 60.0;
        _sam := EXTRACT(EPOCH FROM (NOW() - _sl)) / 60.0;
        _rlm := EXTRACT(EPOCH FROM (_sl - _cl)) / 60.0;
        _egm := CASE WHEN COALESCE(_bh, 0) > 0
                      THEN (168.0 * 60.0) / _bh ELSE 120.0 END;

        INSERT INTO health.mat_health_cagg_status
            (view_schema, view_name, source_table,
             cagg_latest, source_latest, cagg_age_mins, source_age_mins,
             refresh_lag_mins, expected_gap_mins, refreshed_at)
        VALUES
            (_c.vs, _c.vn, _c.st,
             _cl, _sl, _cam, _sam, _rlm, _egm, NOW())
        ON CONFLICT (view_schema, view_name) DO UPDATE SET
            source_table      = EXCLUDED.source_table,
            cagg_latest       = EXCLUDED.cagg_latest,
            source_latest     = EXCLUDED.source_latest,
            cagg_age_mins     = EXCLUDED.cagg_age_mins,
            source_age_mins   = EXCLUDED.source_age_mins,
            refresh_lag_mins  = EXCLUDED.refresh_lag_mins,
            expected_gap_mins = EXCLUDED.expected_gap_mins,
            refreshed_at      = NOW();
    END LOOP;
END;
$$;
