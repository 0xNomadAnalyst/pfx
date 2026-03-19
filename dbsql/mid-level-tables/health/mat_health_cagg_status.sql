-- =============================================================================
-- mat_health_cagg_status
-- Pre-computes CAGG refresh health per CAGG/source pair.
--
-- Two procedures:
--   refresh_mat_health_cagg_status()       — fast path (~4s), every cycle
--     Bounded MAX queries (WHERE > NOW()-24h) leverage TimescaleDB chunk
--     exclusion.  Unbounded MAX on large hypertables with tiered storage
--     caused 27s+ per table.  expected_gap_mins is preserved from the mat
--     table (populated by the benchmark procedure below).
--
--   refresh_mat_health_cagg_benchmarks()   — slow path (~7s), periodic
--     Recomputes expected_gap_mins via 3-day COUNT(DISTINCT hourly buckets).
--     Called from check_health() in onyc_refresh.sh (every HEALTH_CHECK_MULT
--     cycles, ~30 min).
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
-- Fast path: bounded MAX queries, no COUNT recomputation
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE health.refresh_mat_health_cagg_status()
LANGUAGE plpgsql AS $$
DECLARE
    _c   RECORD;
    _cl  TIMESTAMPTZ;
    _sl  TIMESTAMPTZ;
BEGIN
    FOR _c IN
        SELECT * FROM (VALUES
            ('dexes','cagg_events_5s','src_tx_events','bucket_time','time'),
            ('dexes','cagg_poolstate_5s','src_acct_pool','bucket_time','time'),
            ('dexes','cagg_vaults_5s','src_acct_vaults','bucket_time','time'),
            ('dexes','cagg_tickarrays_5s','src_acct_tickarray_queries','bucket','time'),
            ('kamino_lend','cagg_activities_5s','src_txn_events','bucket','meta_block_time'),
            ('kamino_lend','cagg_reserves_5s','src_reserves','bucket','time'),
            ('kamino_lend','cagg_obligations_agg_5s','src_obligations','bucket','block_time'),
            ('exponent','cagg_vaults_5s','src_vaults','bucket','block_time'),
            ('exponent','cagg_market_twos_5s','src_market_twos','bucket','block_time'),
            ('exponent','cagg_sy_meta_account_5s','src_sy_meta_account','bucket','time'),
            ('exponent','cagg_sy_token_account_5s','src_sy_token_account','bucket','time'),
            ('exponent','cagg_vault_yield_position_5s','src_vault_yield_position','bucket','time'),
            ('exponent','cagg_vault_yt_escrow_5s','src_vault_yt_escrow','bucket','time'),
            ('exponent','cagg_base_token_escrow_5s','src_base_token_escrow','bucket','time'),
            ('exponent','cagg_tx_events_5s','src_tx_events','bucket_time','time')
        ) AS t(vs, vn, st, cc, sc)
    LOOP
        BEGIN
            EXECUTE format(
                $q$SELECT MAX(%I) FROM %I.%I WHERE %I > NOW() - INTERVAL '24 hours'$q$,
                _c.cc, _c.vs, _c.vn, _c.cc
            ) INTO _cl;
            EXECUTE format(
                $q$SELECT MAX(%I) FROM %I.%I WHERE %I > NOW() - INTERVAL '24 hours'$q$,
                _c.sc, _c.vs, _c.st, _c.sc
            ) INTO _sl;
        EXCEPTION WHEN undefined_table THEN
            CONTINUE;
        END;

        INSERT INTO health.mat_health_cagg_status
            (view_schema, view_name, source_table,
             cagg_latest, source_latest, cagg_age_mins, source_age_mins,
             refresh_lag_mins, expected_gap_mins, refreshed_at)
        VALUES
            (_c.vs, _c.vn, _c.st,
             _cl, _sl,
             EXTRACT(EPOCH FROM (NOW() - _cl)) / 60.0,
             EXTRACT(EPOCH FROM (NOW() - _sl)) / 60.0,
             EXTRACT(EPOCH FROM (_sl - _cl)) / 60.0,
             COALESCE(
                 (SELECT expected_gap_mins FROM health.mat_health_cagg_status
                  WHERE view_schema = _c.vs AND view_name = _c.vn),
                 120.0
             ),
             NOW())
        ON CONFLICT (view_schema, view_name) DO UPDATE SET
            source_table      = EXCLUDED.source_table,
            cagg_latest       = EXCLUDED.cagg_latest,
            source_latest     = EXCLUDED.source_latest,
            cagg_age_mins     = EXCLUDED.cagg_age_mins,
            source_age_mins   = EXCLUDED.source_age_mins,
            refresh_lag_mins  = EXCLUDED.refresh_lag_mins,
            refreshed_at      = NOW();
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Slow path: recomputes expected_gap_mins from 3-day write frequency.
-- One COUNT per unique source table, then fan-out UPDATE to all CAGG rows.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE health.refresh_mat_health_cagg_benchmarks()
LANGUAGE plpgsql AS $$
DECLARE
    _c   RECORD;
    _bh  BIGINT;
    _egm DOUBLE PRECISION;
BEGIN
    FOR _c IN
        SELECT DISTINCT ON (vs, st) * FROM (VALUES
            ('dexes','src_tx_events','time'),
            ('dexes','src_acct_pool','time'),
            ('dexes','src_acct_vaults','time'),
            ('dexes','src_acct_tickarray_queries','time'),
            ('kamino_lend','src_txn_events','time'),
            ('kamino_lend','src_reserves','time'),
            ('kamino_lend','src_obligations','block_time'),
            ('exponent','src_vaults','time'),
            ('exponent','src_market_twos','time'),
            ('exponent','src_sy_meta_account','time'),
            ('exponent','src_sy_token_account','time'),
            ('exponent','src_vault_yield_position','time'),
            ('exponent','src_vault_yt_escrow','time'),
            ('exponent','src_base_token_escrow','time'),
            ('exponent','src_tx_events','time')
        ) AS t(vs, st, bc)
    LOOP
        BEGIN
            EXECUTE format(
                $q$SELECT COUNT(*) FROM (
                    SELECT 1 FROM %I.%I
                    WHERE %I > NOW() - INTERVAL '3 days'
                    GROUP BY time_bucket('1 hour', %I)
                ) _t$q$,
                _c.vs, _c.st, _c.bc, _c.bc
            ) INTO _bh;
        EXCEPTION WHEN undefined_table THEN
            CONTINUE;
        END;

        _egm := CASE WHEN COALESCE(_bh, 0) > 0
                      THEN (72.0 * 60.0) / _bh ELSE 120.0 END;

        UPDATE health.mat_health_cagg_status
        SET expected_gap_mins = _egm
        WHERE view_schema = _c.vs AND source_table = _c.st;
    END LOOP;
END;
$$;
